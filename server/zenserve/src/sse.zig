//! Server-sent-events plumbing (ZDS 0016, Streaming semantics).
//!
//! One global bounded ring holds the most recent events; each subscriber
//! holds only a cursor into it. Publishing never blocks and never grows
//! memory: oldest ring entries are overwritten, and a slow consumer sees a
//! `dropped` count when its cursor has been overrun, in the manner the
//! record requires. `std.Io.Queue` blocks producers when full, so the ring
//! lives under an `Io.Mutex` and subscribers park on per-slot `Io.Event`
//! flags with a timed wait that doubles as the heartbeat clock.

const std = @import("std");
const assert = std.debug.assert;

/// The serialized data budget of one event; longer payloads are truncated.
pub const max_event_bytes = 1024;

/// How many events the ring retains for replay (ZDS 0016: default 256).
pub const ring_capacity = 256;

/// The most concurrent SSE subscribers; one admin channel needs few.
pub const max_subscribers = 16;

/// The index of a registered subscriber slot.
pub const SubscriberId = u8;

/// One published event. Ids ascend from 1 and never repeat; the name and
/// data are fixed-capacity copies of what the publisher passed.
pub const Event = struct {
    id: u64,
    name_buf: [32]u8,
    name_len: u8,
    data_buf: [max_event_bytes]u8,
    data_len: u16,

    /// Returns the event name, for the `event:` line.
    pub fn name(event: *const Event) []const u8 {
        assert(event.name_len <= event.name_buf.len);
        return event.name_buf[0..event.name_len];
    }

    /// Returns the serialized data, for the `data:` line.
    pub fn data(event: *const Event) []const u8 {
        assert(event.data_len <= event.data_buf.len);
        return event.data_buf[0..event.data_len];
    }
};

/// The event hub: bounded ring, publisher side that never blocks, and
/// cursor-based subscribers. All storage is static; `init` is a constant.
pub const Hub = struct {
    mutex: std.Io.Mutex,
    /// Guarded by `mutex`. The id of the next event to publish; event ids
    /// start at 1, so id 0 means "nothing seen yet".
    next_id: u64,
    /// Guarded by `mutex`. Event with id `n` lives at `(n - 1) % capacity`
    /// while `n` is within `ring_capacity` of the newest id.
    ring: [ring_capacity]Event,
    subscribers: [max_subscribers]Subscriber,
    shutting_down: std.atomic.Value(bool),

    const Subscriber = struct {
        active: std.atomic.Value(bool),
        /// The next event id to deliver. Written only by the owning
        /// consumer thread (under `mutex`) after registration.
        cursor: u64,
        /// Set by publishers and shutdown, awaited by the consumer.
        wakeup: std.Io.Event,
    };

    pub const init: Hub = .{
        .mutex = .init,
        .next_id = 1,
        .ring = undefined,
        .subscribers = @splat(.{
            .active = .init(false),
            .cursor = 0,
            .wakeup = .unset,
        }),
        .shutting_down = .init(false),
    };

    /// What a blocking `next` call resolved to.
    pub const Next = union(enum) {
        /// The next event for this subscriber, copied out of the ring.
        event: Event,
        /// The ring overwrote this many events past the cursor; the cursor
        /// now points at the oldest retained event.
        dropped: u64,
        /// No event arrived within the heartbeat interval.
        heartbeat,
        /// The hub is shutting down; the subscriber should unsubscribe.
        shutdown,
    };

    /// Publishes one event (name plus data already serialized by the
    /// caller). Never blocks and never fails: the oldest ring entry is
    /// overwritten and oversized name or data is truncated to capacity.
    pub fn publish(hub: *Hub, io: std.Io, name: []const u8, data: []const u8) void {
        hub.mutex.lockUncancelable(io);
        const id = hub.next_id;
        hub.next_id = id + 1;
        const entry = &hub.ring[@intCast((id - 1) % ring_capacity)];
        entry.id = id;
        entry.name_len = @intCast(@min(name.len, entry.name_buf.len));
        @memcpy(entry.name_buf[0..entry.name_len], name[0..entry.name_len]);
        entry.data_len = @intCast(@min(data.len, entry.data_buf.len));
        @memcpy(entry.data_buf[0..entry.data_len], data[0..entry.data_len]);
        hub.mutex.unlock(io);
        for (&hub.subscribers) |*subscriber| {
            if (subscriber.active.load(.acquire)) subscriber.wakeup.set(io);
        }
    }

    /// Registers a subscriber whose first delivered event is the one after
    /// id `last_seen` (0 replays whatever the ring still holds). Returns
    /// null when all `max_subscribers` slots are taken. The claim loop is
    /// bounded by the slot count.
    pub fn subscribe(hub: *Hub, last_seen: u64) ?SubscriberId {
        for (&hub.subscribers, 0..) |*subscriber, index| {
            if (subscriber.active.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                subscriber.cursor = last_seen + 1;
                subscriber.wakeup.reset();
                return @intCast(index);
            }
        }
        return null;
    }

    /// Releases a subscriber slot.
    pub fn unsubscribe(hub: *Hub, id: SubscriberId) void {
        const subscriber = &hub.subscribers[id];
        const was_active = subscriber.active.swap(false, .release);
        assert(was_active);
    }

    /// Blocks until an event past the cursor is available, the heartbeat
    /// interval elapses, or shutdown, and copies the next event out. When
    /// the ring has overwritten past the cursor, reports the gap once as
    /// `.dropped` and resumes from the oldest retained event. The loop runs
    /// at most twice: a round either returns or arms the wakeup flag and
    /// waits, and a second empty round only follows a spurious wake.
    pub fn next(hub: *Hub, io: std.Io, id: SubscriberId, heartbeat_ms: u64) Next {
        const subscriber = &hub.subscribers[id];
        assert(subscriber.active.load(.monotonic));
        for (0..2) |_| {
            if (hub.shutting_down.load(.acquire)) return .shutdown;
            hub.mutex.lockUncancelable(io);
            const next_id = hub.next_id;
            const oldest = if (next_id > ring_capacity + 1) next_id - ring_capacity else 1;
            if (subscriber.cursor < oldest) {
                const gap = oldest - subscriber.cursor;
                subscriber.cursor = oldest;
                hub.mutex.unlock(io);
                return .{ .dropped = gap };
            }
            if (subscriber.cursor < next_id) {
                const event = hub.ring[@intCast((subscriber.cursor - 1) % ring_capacity)];
                assert(event.id == subscriber.cursor);
                subscriber.cursor += 1;
                hub.mutex.unlock(io);
                return .{ .event = event };
            }
            // Arm the flag before unlocking: a publisher sets it only
            // after releasing the mutex, so no wakeup can be lost.
            subscriber.wakeup.reset();
            hub.mutex.unlock(io);
            if (hub.shutting_down.load(.acquire)) return .shutdown;
            subscriber.wakeup.waitTimeout(io, .{ .duration = .{
                .raw = .fromMilliseconds(@intCast(heartbeat_ms)),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => return .heartbeat,
                error.Canceled => return .shutdown,
            };
        }
        return .heartbeat;
    }

    /// Begins shutdown: every current and future `next` call resolves to
    /// `.shutdown` and all parked subscribers are woken.
    pub fn shutdown(hub: *Hub, io: std.Io) void {
        hub.shutting_down.store(true, .release);
        for (&hub.subscribers) |*subscriber| subscriber.wakeup.set(io);
    }
};

// Tests.

test "publish then replay from cursor zero" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var hub: Hub = .init;
    hub.publish(io, "request", "{\"n\":1}");
    hub.publish(io, "auth", "{\"n\":2}");

    const id = hub.subscribe(0) orelse return error.TestUnexpectedResult;
    defer hub.unsubscribe(id);

    const first = hub.next(io, id, 1000);
    try std.testing.expectEqual(@as(u64, 1), first.event.id);
    try std.testing.expectEqualStrings("request", first.event.name());
    try std.testing.expectEqualStrings("{\"n\":1}", first.event.data());
    const second = hub.next(io, id, 1000);
    try std.testing.expectEqual(@as(u64, 2), second.event.id);
    try std.testing.expectEqualStrings("auth", second.event.name());
}

test "overrun cursor reports the gap once, then continues" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var hub: Hub = .init;
    const extra = 10;
    for (0..ring_capacity + extra) |index| {
        var data_buf: [16]u8 = undefined;
        const data = std.fmt.bufPrint(&data_buf, "{d}", .{index + 1}) catch unreachable;
        hub.publish(io, "e", data);
    }

    const id = hub.subscribe(0) orelse return error.TestUnexpectedResult;
    defer hub.unsubscribe(id);

    const gap = hub.next(io, id, 1000);
    try std.testing.expectEqual(@as(u64, extra), gap.dropped);
    const oldest = hub.next(io, id, 1000);
    try std.testing.expectEqual(@as(u64, extra + 1), oldest.event.id);
    // The remaining ring drains in order and ends with a heartbeat.
    var expected: u64 = extra + 2;
    for (0..ring_capacity - 1) |_| {
        const following = hub.next(io, id, 1);
        try std.testing.expectEqual(expected, following.event.id);
        expected += 1;
    }
    try std.testing.expectEqual(Hub.Next.heartbeat, hub.next(io, id, 1));
}

test "subscribing after the newest id sees only new events" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var hub: Hub = .init;
    hub.publish(io, "old", "1");
    const id = hub.subscribe(1) orelse return error.TestUnexpectedResult;
    defer hub.unsubscribe(id);
    try std.testing.expectEqual(Hub.Next.heartbeat, hub.next(io, id, 1));
    hub.publish(io, "new", "2");
    const fresh = hub.next(io, id, 1000);
    try std.testing.expectEqual(@as(u64, 2), fresh.event.id);
    try std.testing.expectEqualStrings("new", fresh.event.name());
}

test "heartbeat on timeout" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var hub: Hub = .init;
    const id = hub.subscribe(0) orelse return error.TestUnexpectedResult;
    defer hub.unsubscribe(id);
    try std.testing.expectEqual(Hub.Next.heartbeat, hub.next(io, id, 1));
}

test "subscriber cap and slot reuse" {
    var hub: Hub = .init;
    var ids: [max_subscribers]SubscriberId = undefined;
    for (&ids) |*id| {
        id.* = hub.subscribe(0) orelse return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(?SubscriberId, null), hub.subscribe(0));
    hub.unsubscribe(ids[3]);
    const reused = hub.subscribe(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ids[3], reused);
    hub.unsubscribe(reused);
    for (ids, 0..) |id, index| {
        if (index != 3) hub.unsubscribe(id);
    }
}

test "shutdown resolves next immediately and wakes a parked subscriber" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var hub: Hub = .init;
    const id = hub.subscribe(0) orelse return error.TestUnexpectedResult;
    defer hub.unsubscribe(id);

    const Parked = struct {
        fn run(hub_ptr: *Hub, run_io: std.Io, run_id: SubscriberId, out: *Hub.Next) void {
            // A parked wait far longer than the test's patience; shutdown
            // must cut it short.
            out.* = hub_ptr.next(run_io, run_id, 60_000);
        }
    };
    var outcome: Hub.Next = .heartbeat;
    const thread = try std.Thread.spawn(.{}, Parked.run, .{ &hub, io, id, &outcome });
    // Give the subscriber a moment to park, then shut down.
    try io.sleep(.fromMilliseconds(20), .awake);
    hub.shutdown(io);
    thread.join();
    try std.testing.expectEqual(Hub.Next.shutdown, outcome);
    // After shutdown every further call resolves immediately.
    try std.testing.expectEqual(Hub.Next.shutdown, hub.next(io, id, 60_000));
}

test "oversized name and data are truncated to capacity" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var hub: Hub = .init;
    const long_name = "n" ** 100;
    const long_data = "d" ** (max_event_bytes + 100);
    hub.publish(io, long_name, long_data);

    const id = hub.subscribe(0) orelse return error.TestUnexpectedResult;
    defer hub.unsubscribe(id);
    const received = hub.next(io, id, 1000);
    try std.testing.expectEqual(@as(usize, 32), received.event.name().len);
    try std.testing.expectEqual(@as(usize, max_event_bytes), received.event.data().len);
    try std.testing.expectEqualStrings("n" ** 32, received.event.name());
}
