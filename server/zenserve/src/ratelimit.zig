//! Rate limiting (ZDS 0016, Authentication core).
//!
//! Fixed-size token buckets keyed by a 64-bit hash of the principal or
//! peer address; the caller does the hashing. Storage is a static
//! direct-mapped array with a bounded linear probe and LRU eviction
//! inside the probe window, so admission control allocates nothing and
//! degrades by forgetting the least recently used key rather than by
//! growing. Tokens are fixed-point (thousandths), which makes refill
//! smooth at one-second granularity policies.
//!
//! Under the eviction policy a forgotten key returns as a fresh, full
//! bucket. That errs toward admitting traffic when the table is under
//! pressure, which is the right failure mode for a limiter guarding
//! bounded work.

const std = @import("std");
const assert = std.debug.assert;

/// Probe window length: how many consecutive slots one key may occupy or
/// displace. A miss evicts the least recently used slot in this window.
pub const probe_limit = 8;

/// Fixed-point scale: stored token thousandths per whole token.
const tokens_per_unit = 1000;

/// One bucket policy. Both members must be positive: a zero-capacity or
/// zero-refill policy is a block, not a rate, and belongs elsewhere.
pub const Policy = struct {
    capacity: u32,
    refill_per_second: u32,
};

/// The verdict for one request. `retry_after_seconds` is zero when
/// allowed, else the ceiling of the wait until one whole token exists,
/// never below one second.
pub const Decision = struct {
    allowed: bool,
    retry_after_seconds: u32,
};

/// Returns a bucket table with `slot_count` slots (a power of two). The
/// whole table is guarded by one `std.Io.Mutex`, so `allow` is safe from
/// any number of concurrent tasks.
pub fn Buckets(comptime slot_count: usize) type {
    comptime assert(slot_count > 0);
    comptime assert(std.math.isPowerOfTwo(slot_count));

    return struct {
        mutex: std.Io.Mutex,
        slots: [slot_count]Slot,

        const Self = @This();

        const Slot = struct {
            occupied: bool,
            key: u64,
            tokens_milli: u64,
            last_refill_ms: i64,
            last_use_ms: i64,
        };

        const empty_slot: Slot = .{
            .occupied = false,
            .key = 0,
            .tokens_milli = 0,
            .last_refill_ms = 0,
            .last_use_ms = 0,
        };

        pub const init: Self = .{
            .mutex = .init,
            .slots = @splat(empty_slot),
        };

        /// Decides one request for `key` under `policy` at wall time
        /// `now_ms`. A key unseen (or evicted) starts with a full bucket
        /// and spends one token. If acquiring the lock is canceled, the
        /// request is denied with a one-second retry: a canceled task
        /// must not slip past admission control.
        pub fn allow(
            self: *Self,
            io: std.Io,
            key: u64,
            policy: Policy,
            now_ms: i64,
        ) Decision {
            assert(policy.capacity > 0);
            assert(policy.refill_per_second > 0);
            self.mutex.lock(io) catch {
                return .{ .allowed = false, .retry_after_seconds = 1 };
            };
            defer self.mutex.unlock(io);

            const probe_count = @min(probe_limit, slot_count);
            const mask = slot_count - 1;
            const home: usize = @intCast(key & mask);
            var victim: usize = home;
            var i: usize = 0;
            while (i < probe_count) : (i += 1) {
                const s = (home + i) & mask;
                const slot = &self.slots[s];
                if (slot.occupied and slot.key == key) {
                    return self.takeLocked(s, policy, now_ms);
                }
                if (betterVictim(slot, &self.slots[victim])) victim = s;
            }
            self.slots[victim] = .{
                .occupied = true,
                .key = key,
                .tokens_milli = capacityMilli(policy) - tokens_per_unit,
                .last_refill_ms = now_ms,
                .last_use_ms = now_ms,
            };
            return .{ .allowed = true, .retry_after_seconds = 0 };
        }

        /// Refills slot `s` for elapsed time and spends one token, or
        /// denies with the retry hint. Caller holds the mutex.
        fn takeLocked(
            self: *Self,
            s: usize,
            policy: Policy,
            now_ms: i64,
        ) Decision {
            const slot = &self.slots[s];
            assert(slot.occupied);
            const cap_milli = capacityMilli(policy);
            assert(slot.tokens_milli <= cap_milli);

            // One millisecond refills `refill_per_second` thousandths.
            const elapsed_ms: u64 = @intCast(@max(0, now_ms - slot.last_refill_ms));
            const refilled: u128 = @as(u128, slot.tokens_milli) +
                @as(u128, elapsed_ms) * policy.refill_per_second;
            slot.tokens_milli = @intCast(@min(refilled, cap_milli));
            slot.last_refill_ms = now_ms;
            slot.last_use_ms = now_ms;

            if (slot.tokens_milli >= tokens_per_unit) {
                slot.tokens_milli -= tokens_per_unit;
                return .{ .allowed = true, .retry_after_seconds = 0 };
            }
            const deficit_milli = tokens_per_unit - slot.tokens_milli;
            const wait_ms = std.math.divCeil(
                u64,
                deficit_milli,
                policy.refill_per_second,
            ) catch unreachable;
            const wait_s = std.math.divCeil(u64, wait_ms, 1000) catch unreachable;
            assert(wait_s <= 1000);
            return .{
                .allowed = false,
                .retry_after_seconds = @intCast(@max(1, wait_s)),
            };
        }

        /// Orders eviction candidates: an empty slot always wins, then
        /// the older `last_use_ms` wins.
        fn betterVictim(candidate: *const Slot, current: *const Slot) bool {
            if (!current.occupied) return false;
            if (!candidate.occupied) return true;
            return candidate.last_use_ms < current.last_use_ms;
        }
    };
}

fn capacityMilli(policy: Policy) u64 {
    return @as(u64, policy.capacity) * tokens_per_unit;
}

// ---- tests

const testing = std.testing;

test "burst up to capacity, then deny" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buckets: Buckets(16) = .init;
    const policy: Policy = .{ .capacity = 5, .refill_per_second = 1 };
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const decision = buckets.allow(io, 0x1234, policy, 0);
        try testing.expect(decision.allowed);
        try testing.expectEqual(@as(u32, 0), decision.retry_after_seconds);
    }
    const denied = buckets.allow(io, 0x1234, policy, 0);
    try testing.expect(!denied.allowed);
    try testing.expectEqual(@as(u32, 1), denied.retry_after_seconds);
}

test "refill over simulated time" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buckets: Buckets(16) = .init;
    const policy: Policy = .{ .capacity = 3, .refill_per_second = 1 };
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        try testing.expect(buckets.allow(io, 7, policy, 0).allowed);
    }
    try testing.expect(!buckets.allow(io, 7, policy, 0).allowed);
    // Half a token after 500 ms: still denied.
    try testing.expect(!buckets.allow(io, 7, policy, 500).allowed);
    // A whole token after a full second (from the last refill).
    try testing.expect(buckets.allow(io, 7, policy, 1500).allowed);
    try testing.expect(!buckets.allow(io, 7, policy, 1500).allowed);
    // Long idle refills to capacity, no further.
    i = 0;
    while (i < 3) : (i += 1) {
        try testing.expect(buckets.allow(io, 7, policy, 60_000).allowed);
    }
    try testing.expect(!buckets.allow(io, 7, policy, 60_000).allowed);
}

test "retry-after is the ceiling of the wait, minimum one" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buckets: Buckets(16) = .init;
    const policy: Policy = .{ .capacity = 1, .refill_per_second = 1 };
    try testing.expect(buckets.allow(io, 9, policy, 0).allowed);
    // Empty bucket, one token per second: exactly one second away.
    try testing.expectEqual(
        @as(u32, 1),
        buckets.allow(io, 9, policy, 0).retry_after_seconds,
    );
    // 900 ms later the deficit is 100 ms; the ceiling stays one second.
    try testing.expectEqual(
        @as(u32, 1),
        buckets.allow(io, 9, policy, 900).retry_after_seconds,
    );
}

test "eviction forgets the least recently used key in the window" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Every key hashes to home slot 0, so all traffic shares one
    // eight-slot probe window.
    var buckets: Buckets(8) = .init;
    const policy: Policy = .{ .capacity = 1, .refill_per_second = 1 };

    // Key 0 spends its only token; its bucket is empty but resident.
    try testing.expect(buckets.allow(io, 0 * 8, policy, 0).allowed);
    try testing.expect(!buckets.allow(io, 0 * 8, policy, 0).allowed);

    // Seven more keys fill the window: empty slots are taken first, so
    // key 0 stays resident.
    var k: u64 = 1;
    while (k < 8) : (k += 1) {
        try testing.expect(buckets.allow(io, k * 8, policy, @intCast(k)).allowed);
    }

    // An eighth new key must evict; key 0 is the least recently used.
    try testing.expect(buckets.allow(io, 8 * 8, policy, 8).allowed);

    // Key 0 returns as a fresh, full bucket: allowed again despite no
    // refill time having passed since its denial.
    try testing.expect(buckets.allow(io, 0 * 8, policy, 8).allowed);

    // Key 2 was not evicted: its bucket still remembers being spent.
    try testing.expect(!buckets.allow(io, 2 * 8, policy, 8).allowed);
}

test "probe window bounds the search" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Sixteen slots, so the window covers half the table. Nine same-home
    // keys force one eviction even though free slots exist beyond the
    // window: the ninth key must land inside slots home..home+7.
    var buckets: Buckets(16) = .init;
    const policy: Policy = .{ .capacity = 2, .refill_per_second = 1 };
    var k: u64 = 0;
    while (k < 9) : (k += 1) {
        try testing.expect(buckets.allow(io, k * 16, policy, @intCast(k)).allowed);
    }
    var occupied: usize = 0;
    for (buckets.slots) |slot| {
        if (slot.occupied) occupied += 1;
    }
    try testing.expectEqual(@as(usize, probe_limit), occupied);
    for (buckets.slots[probe_limit..]) |slot| {
        try testing.expect(!slot.occupied);
    }
}

test "a found key deeper in the window keeps its state" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buckets: Buckets(8) = .init;
    const policy: Policy = .{ .capacity = 2, .refill_per_second = 1 };
    // Three same-home keys: the third lives at slot 2.
    try testing.expect(buckets.allow(io, 0, policy, 0).allowed);
    try testing.expect(buckets.allow(io, 8, policy, 0).allowed);
    try testing.expect(buckets.allow(io, 16, policy, 0).allowed);
    // The third key is found again, not restarted: one token left.
    try testing.expect(buckets.allow(io, 16, policy, 0).allowed);
    try testing.expect(!buckets.allow(io, 16, policy, 0).allowed);
}
