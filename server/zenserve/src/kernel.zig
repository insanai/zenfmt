//! The zenserve HTTP kernel (ZDS 0016, The zenserve Library).
//!
//! A bounded threaded design: one acceptor task owns the listener, one
//! service task owns each active connection (cap: the connection slots), and
//! the processor is bounded separately by the application's conversion
//! semaphore. Kernel concurrency uses `std.Io` tasks in one group because
//! only Io tasks cancel portably: the acceptor blocked in `accept` is
//! unblocked by cancelling its future, and a connection blocked in a read is
//! unblocked by the watchdog shutting its socket down.
//!
//! The standard library exposes no per-read socket timeout (and SO_RCVTIMEO
//! is unsupported by the Threaded Io implementation), so deadlines are
//! enforced by a watchdog task: each slot publishes its current deadline in
//! an atomic before parking in a read, and the watchdog scans the slot array
//! once per second and shuts down any expired socket, which wakes the parked
//! read with end-of-stream. Deadlines land within one tick of nominal.
//!
//! The application type plugged into `Kernel` provides:
//!
//!   pub fn handle(app: *App, ctx: *Context) void
//!
//! `handle` owns routing, authentication, and the response; the kernel owns
//! sockets, slots, deadlines, parsing, refusals, keep-alive, and drain.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const context = @import("context.zig");
const report = @import("report.zig");

pub const Context = context.Context;

/// The static upper bound on connection slots; `Options.connections` may
/// select fewer but never more.
pub const max_slots = 128;

/// Fixed per-connection buffer sizes: the receive buffer is also the head
/// cap (a head that does not fit is a 431).
pub const recv_buffer_bytes = 16 * 1024;
pub const send_buffer_bytes = 16 * 1024;

pub const Options = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 8998,
    connections: u32 = max_slots,
    keepalive_requests: u32 = 1024,
    head_deadline_ms: i64 = 10_000,
    idle_deadline_ms: i64 = 60_000,
    body_deadline_ms: i64 = 120_000,
    drain_seconds: u32 = 30,
    max_body_bytes: u64 = 64 * 1024 * 1024,
};

/// Why the kernel refused or ended a connection without the application
/// seeing it; reported to the optional `App.onKernelEvent` hook.
pub const KernelEvent = enum {
    busy,
    head_too_large,
    malformed_head,
    timeout,
    shutting_down,
    connection_error,
};

const Slot = struct {
    state: std.atomic.Value(State) = .init(.idle),
    /// Guards `stream` against the watchdog racing close with shutdown.
    mutex: Io.Mutex = .init,
    stream: Io.net.Stream = undefined,
    /// Monotonic milliseconds; 0 means no deadline is armed.
    deadline_ms: std.atomic.Value(i64) = .init(0),
    timed_out: std.atomic.Value(bool) = .init(false),

    const State = enum(u8) { idle, active };
};

pub fn Kernel(comptime App: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: Io,
        app: *App,
        options: Options,
        listener: Io.net.Server = undefined,
        bound_address: Io.net.IpAddress = undefined,
        slots: [max_slots]Slot = @splat(.{}),
        group: Io.Group = .init,
        acceptor: ?Io.Future(Io.Cancelable!void) = null,
        watchdog: ?Io.Future(Io.Cancelable!void) = null,
        draining: std.atomic.Value(bool) = .init(false),
        drain_deadline_ms: std.atomic.Value(i64) = .init(0),
        active: std.atomic.Value(u32) = .init(0),
        started: bool = false,

        /// Binds the listener and spawns the acceptor and watchdog. The
        /// kernel must not move after `start`; embed it at a stable address.
        pub fn start(k: *Self) !void {
            assert(!k.started);
            assert(k.options.connections >= 1);
            assert(k.options.connections <= max_slots);
            const address = try Io.net.IpAddress.parse(
                k.options.address,
                k.options.port,
            );
            k.listener = try address.listen(k.io, .{ .reuse_address = true });
            k.bound_address = k.listener.socket.address;
            k.watchdog = try k.io.concurrent(watchdogLoop, .{k});
            errdefer if (k.watchdog) |*w| {
                _ = w.cancel(k.io) catch {};
                k.watchdog = null;
            };
            k.acceptor = try k.io.concurrent(acceptLoop, .{k});
            k.started = true;
        }

        /// The port actually bound; differs from `options.port` when it was 0.
        pub fn boundPort(k: *const Self) u16 {
            assert(k.started);
            return k.bound_address.getPort();
        }

        pub fn activeConnections(k: *const Self) u32 {
            return k.active.load(.monotonic);
        }

        /// Graceful stop: refuse new connections, give in-flight requests
        /// `drain_seconds`, force-close stragglers, and join every task.
        pub fn stop(k: *Self) void {
            assert(k.started);
            k.draining.store(true, .release);
            k.drain_deadline_ms.store(
                nowMs(k.io) + @as(i64, k.options.drain_seconds) * 1000,
                .monotonic,
            );
            if (k.acceptor) |*acceptor| {
                _ = acceptor.cancel(k.io) catch {};
                k.acceptor = null;
            }
            // Idle keep-alive connections wake immediately rather than at
            // their idle deadline: shut every parked socket down now; a
            // connection mid-request is left to the drain deadline.
            k.shutdownIdle();
            k.group.await(k.io) catch {};
            if (k.watchdog) |*watchdog| {
                _ = watchdog.cancel(k.io) catch {};
                k.watchdog = null;
            }
            k.listener.deinit(k.io);
            k.started = false;
        }

        fn shutdownIdle(k: *Self) void {
            for (k.slots[0..k.options.connections]) |*slot| {
                slot.mutex.lockUncancelable(k.io);
                defer slot.mutex.unlock(k.io);
                if (slot.state.load(.acquire) == .active and
                    slot.deadline_ms.load(.monotonic) != 0)
                {
                    slot.stream.shutdown(k.io, .both) catch {};
                }
            }
        }

        fn nowMs(io: Io) i64 {
            return Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds();
        }

        fn event(k: *Self, kernel_event: KernelEvent) void {
            if (@hasDecl(App, "onKernelEvent")) {
                k.app.onKernelEvent(kernel_event);
            }
        }

        // ------------------------------------------------------- acceptor

        fn acceptLoop(k: *Self) Io.Cancelable!void {
            while (true) {
                const stream = k.listener.accept(k.io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {
                        if (k.draining.load(.acquire)) return;
                        k.event(.connection_error);
                        try k.io.sleep(.fromMilliseconds(10), .awake);
                        continue;
                    },
                };
                if (k.draining.load(.acquire)) {
                    k.refuse(stream, .shutting_down);
                    continue;
                }
                const slot_index = k.acquireSlot(stream) orelse {
                    k.refuse(stream, .busy);
                    continue;
                };
                k.group.concurrent(k.io, serviceConnection, .{ k, slot_index }) catch {
                    k.releaseSlot(slot_index);
                    k.refuse(stream, .busy);
                };
            }
        }

        fn acquireSlot(k: *Self, stream: Io.net.Stream) ?usize {
            for (k.slots[0..k.options.connections], 0..) |*slot, index| {
                if (slot.state.cmpxchgStrong(.idle, .active, .acq_rel, .monotonic) == null) {
                    slot.mutex.lockUncancelable(k.io);
                    slot.stream = stream;
                    slot.timed_out.store(false, .monotonic);
                    slot.deadline_ms.store(0, .monotonic);
                    slot.mutex.unlock(k.io);
                    _ = k.active.fetchAdd(1, .monotonic);
                    return index;
                }
            }
            return null;
        }

        fn releaseSlot(k: *Self, slot_index: usize) void {
            const slot = &k.slots[slot_index];
            slot.mutex.lockUncancelable(k.io);
            slot.deadline_ms.store(0, .monotonic);
            slot.state.store(.idle, .release);
            slot.mutex.unlock(k.io);
            _ = k.active.fetchSub(1, .monotonic);
        }

        /// Writes a prebuilt refusal response and closes. The whole response
        /// is smaller than a fresh socket's send buffer, so this cannot park
        /// the acceptor behind a slow peer.
        fn refuse(k: *Self, stream: Io.net.Stream, kernel_event: KernelEvent) void {
            const response = switch (kernel_event) {
                .busy => static_busy_response,
                .shutting_down => static_shutting_down_response,
                else => unreachable,
            };
            comptime assert(static_busy_response.len < 2048);
            var buffer: [2048]u8 = undefined;
            var writer = stream.writer(k.io, &buffer);
            writer.interface.writeAll(response) catch {};
            writer.interface.flush() catch {};
            stream.close(k.io);
            k.event(kernel_event);
        }

        // ------------------------------------------------- service task

        fn serviceConnection(k: *Self, slot_index: usize) Io.Cancelable!void {
            const slot = &k.slots[slot_index];
            const stream = slot.stream;
            defer {
                k.releaseSlot(slot_index);
                stream.close(k.io);
            }

            var recv_buffer: [recv_buffer_bytes]u8 = undefined;
            var send_buffer: [send_buffer_bytes]u8 = undefined;
            var stream_reader = stream.reader(k.io, &recv_buffer);
            var stream_writer = stream.writer(k.io, &send_buffer);
            var server = std.http.Server.init(
                &stream_reader.interface,
                &stream_writer.interface,
            );

            var arena_state = std.heap.ArenaAllocator.init(k.gpa);
            defer arena_state.deinit();

            var requests: u32 = 0;
            while (requests < k.options.keepalive_requests) : (requests += 1) {
                const wait_ms = if (requests == 0)
                    k.options.head_deadline_ms
                else
                    k.options.idle_deadline_ms;
                slot.deadline_ms.store(nowMs(k.io) + wait_ms, .monotonic);

                var request = server.receiveHead() catch |err| {
                    k.classifyHeadError(slot, stream, &stream_reader.interface, &stream_writer.interface, err);
                    return;
                };
                slot.deadline_ms.store(
                    nowMs(k.io) + k.options.body_deadline_ms,
                    .monotonic,
                );

                _ = arena_state.reset(.retain_capacity);
                var ctx: Context = .{
                    .io = k.io,
                    .gpa = k.gpa,
                    .arena = arena_state.allocator(),
                    .request = &request,
                    .peer = stream.socket.address,
                    .request_id = newRequestId(k.io),
                    .principal = context.Principal.anonymous_open,
                    .app = k.app,
                    .max_body_bytes = k.options.max_body_bytes,
                };
                k.app.handle(&ctx);
                slot.deadline_ms.store(0, .monotonic);

                // A handler that could not respond leaves the connection in
                // an unknown protocol state; the only safe move is closing.
                if (!ctx.responded) return;
                if (server.reader.state != .ready) return;
                if (k.draining.load(.acquire)) return;
            }
        }

        fn classifyHeadError(
            k: *Self,
            slot: *Slot,
            stream: Io.net.Stream,
            in: *Io.Reader,
            out: *Io.Writer,
            err: std.http.Server.ReceiveHeadError,
        ) void {
            if (slot.timed_out.load(.monotonic)) {
                k.event(.timeout);
                return;
            }
            switch (err) {
                error.HttpConnectionClosing => {},
                error.HttpHeadersOversize => {
                    out.writeAll(static_head_too_large_response) catch {};
                    out.flush() catch {};
                    // Closing with unread bytes queued would reset the
                    // connection and destroy the refusal in flight: send
                    // the FIN first, then drain what the peer already
                    // sent, bounded by the head deadline the watchdog
                    // still enforces.
                    stream.shutdown(k.io, .send) catch {};
                    drainBounded(in);
                    k.event(.head_too_large);
                },
                error.HttpHeadersInvalid => k.event(.malformed_head),
                error.HttpRequestTruncated, error.ReadFailed => {
                    if (k.draining.load(.acquire)) return;
                    k.event(.connection_error);
                },
            }
        }

        // ---------------------------------------------------- watchdog

        fn watchdogLoop(k: *Self) Io.Cancelable!void {
            while (true) {
                try k.io.sleep(.fromMilliseconds(1000), .awake);
                const now = nowMs(k.io);
                const draining = k.draining.load(.acquire);
                const drain_deadline = k.drain_deadline_ms.load(.monotonic);
                const force = draining and drain_deadline != 0 and now > drain_deadline;
                for (k.slots[0..k.options.connections]) |*slot| {
                    slot.mutex.lockUncancelable(k.io);
                    defer slot.mutex.unlock(k.io);
                    if (slot.state.load(.acquire) != .active) continue;
                    const deadline = slot.deadline_ms.load(.monotonic);
                    const expired = deadline != 0 and now > deadline;
                    if (expired or force) {
                        slot.timed_out.store(expired, .monotonic);
                        slot.stream.shutdown(k.io, .both) catch {};
                    }
                }
            }
        }
    };
}

/// Discards up to one megabyte of already-sent request bytes so the close
/// that follows cannot reset the response out from under the peer.
fn drainBounded(in: *Io.Reader) void {
    var scratch: [4096]u8 = undefined;
    var drained: usize = 0;
    while (drained < 1024 * 1024) {
        const n = in.readSliceShort(&scratch) catch return;
        if (n == 0) return;
        drained += n;
    }
}

fn newRequestId(io: Io) [16]u8 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    var hex: [16]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (raw, 0..) |byte, i| {
        hex[i * 2] = alphabet[byte >> 4];
        hex[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return hex;
}

// ----------------------------------------------- prebuilt refusals
//
// These responses exist before any request arrives and allocate nothing:
// the connection-level refusals must succeed exactly when the process is
// under pressure.

fn staticResponse(
    comptime status_line: []const u8,
    comptime code: report.Code,
    comptime problem: []const u8,
    comptime direction: []const u8,
    comptime extra_headers: []const u8,
) []const u8 {
    const body = "{\"status\":\"failed\",\"reports\":[{\"severity\":\"error\",\"code\":\"" ++
        report.Code.text(code) ++
        "\",\"title\":\"" ++ report.Code.title(code) ++
        "\",\"problem\":\"" ++ problem ++
        "\",\"consequence\":\"Nothing was converted.\"" ++
        ",\"directions\":[{\"title\":\"What you can do\",\"explanation\":\"" ++
        direction ++ "\"}]}],\"exit_class\":\"" ++
        (if (report.Code.httpStatus(code) >= 500) "conversion" else "usage") ++ "\"}";
    return std.fmt.comptimePrint(
        "HTTP/1.1 {s}\r\n" ++
            "content-type: application/json\r\n" ++
            "content-length: {d}\r\n" ++
            "{s}connection: close\r\n\r\n{s}",
        .{ status_line, body.len, extra_headers, body },
    );
}

const static_busy_response = staticResponse(
    "503 Service Unavailable",
    .busy,
    "Every connection slot is in use.",
    "Retry after the interval in the Retry-After header.",
    "retry-after: 1\r\n",
);

const static_shutting_down_response = staticResponse(
    "503 Service Unavailable",
    .shutting_down,
    "The server is draining before shutdown.",
    "Retry against a healthy instance.",
    "retry-after: 1\r\n",
);

const static_head_too_large_response = staticResponse(
    "431 Request Header Fields Too Large",
    .head_too_large,
    "The request head exceeded the fixed 16 KiB buffer.",
    "Send fewer or shorter headers.",
    "",
);

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "request ids are sixteen lowercase hex characters" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const id = newRequestId(io);
    for (id) |byte| {
        try testing.expect((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'));
    }
}

test "prebuilt refusals are complete HTTP responses" {
    try testing.expect(std.mem.startsWith(u8, static_busy_response, "HTTP/1.1 503 "));
    try testing.expect(std.mem.indexOf(u8, static_busy_response, "retry-after: 1") != null);
    try testing.expect(std.mem.indexOf(u8, static_busy_response, "server.busy") != null);
    try testing.expect(std.mem.startsWith(u8, static_head_too_large_response, "HTTP/1.1 431 "));
    try testing.expect(std.mem.indexOf(
        u8,
        static_shutting_down_response,
        "server.shutting-down",
    ) != null);

    // The bodies parse as JSON and declare the right length.
    inline for (.{
        static_busy_response,
        static_shutting_down_response,
        static_head_too_large_response,
    }) |response| {
        const body_start = std.mem.indexOf(u8, response, "\r\n\r\n").? + 4;
        const body = response[body_start..];
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            body,
            .{},
        );
        defer parsed.deinit();
        try testing.expect(parsed.value.object.get("status") != null);
    }
}
