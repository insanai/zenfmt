//! Health checks (ZDS 0016, Observability core).
//!
//! A static registry of readiness checks behind `/readyz`. Liveness is
//! answering at all; readiness is every registered check reporting true.
//! Registration happens once at startup and hands back an atomic flag
//! that the owning subsystem flips as its state changes, so the serving
//! path takes no lock and allocates nothing. The readiness body exposes
//! check names and nothing else.

const std = @import("std");
const assert = std.debug.assert;

/// Bound on registered checks. ZDS 0016 names two (the kernel task group
/// and, in secure mode, the store ping); the bound leaves headroom
/// without inviting sprawl.
pub const max_checks = 8;

/// One named readiness flag. A check starts not ready and is flipped by
/// the subsystem that registered it.
pub const Check = struct {
    name: []const u8,
    ready: std.atomic.Value(bool),
};

/// The check registry. Register every check during startup, before the
/// address of the registry can move: `register` returns pointers into
/// the static array.
pub const Health = struct {
    checks: [max_checks]Check,
    count: usize,

    pub const init: Health = .{
        .checks = @splat(.{ .name = "", .ready = .init(false) }),
        .count = 0,
    };

    /// Registers a named check and returns its flag, initially not
    /// ready. The name must be a nonempty, unique identifier; the
    /// registry asserts the `max_checks` bound rather than growing.
    pub fn register(h: *Health, name: []const u8) *std.atomic.Value(bool) {
        assert(name.len > 0);
        assert(h.count < max_checks);
        for (h.checks[0..h.count]) |check| {
            assert(!std.mem.eql(u8, check.name, name));
        }
        h.checks[h.count] = .{ .name = name, .ready = .init(false) };
        const flag = &h.checks[h.count].ready;
        h.count += 1;
        return flag;
    }

    /// Returns true when every registered check reports ready. A
    /// registry with no checks is ready: liveness alone suffices then.
    pub fn allReady(h: *const Health) bool {
        assert(h.count <= max_checks);
        for (h.checks[0..h.count]) |*check| {
            if (!check.ready.load(.acquire)) return false;
        }
        return true;
    }

    /// Writes the plain-text readiness body: `ok` when every check is
    /// ready, else one `not-ready: <name>` line per failing check.
    /// Returns the readiness verdict for the same pass, so the status
    /// code and the body cannot disagree.
    pub fn writeReadiness(
        h: *const Health,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!bool {
        assert(h.count <= max_checks);
        var ready = true;
        for (h.checks[0..h.count]) |*check| {
            if (check.ready.load(.acquire)) continue;
            ready = false;
            try writer.print("not-ready: {s}\n", .{check.name});
        }
        if (ready) try writer.writeAll("ok\n");
        return ready;
    }
};

// ---- tests

const testing = std.testing;

test "register, flip, and allReady" {
    var health: Health = .init;
    try testing.expect(health.allReady());

    const kernel = health.register("kernel");
    const store = health.register("store");
    try testing.expectEqual(@as(usize, 2), health.count);
    try testing.expect(!health.allReady());

    kernel.store(true, .release);
    try testing.expect(!health.allReady());
    store.store(true, .release);
    try testing.expect(health.allReady());

    store.store(false, .release);
    try testing.expect(!health.allReady());
}

test "readiness body when ready" {
    var health: Health = .init;
    const kernel = health.register("kernel");
    kernel.store(true, .release);

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const ready = try health.writeReadiness(&writer);
    try testing.expect(ready);
    try testing.expectEqualStrings("ok\n", writer.buffered());
}

test "readiness body names each failing check" {
    var health: Health = .init;
    const kernel = health.register("kernel");
    _ = health.register("store");
    _ = health.register("index");
    kernel.store(true, .release);

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const ready = try health.writeReadiness(&writer);
    try testing.expect(!ready);
    try testing.expectEqualStrings(
        "not-ready: store\nnot-ready: index\n",
        writer.buffered(),
    );
}

test "registration up to the max_checks bound" {
    var health: Health = .init;
    const names = [max_checks][]const u8{
        "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7",
    };
    var flags: [max_checks]*std.atomic.Value(bool) = undefined;
    for (names, 0..) |name, i| flags[i] = health.register(name);
    try testing.expectEqual(@as(usize, max_checks), health.count);
    try testing.expect(!health.allReady());
    for (flags) |flag| flag.store(true, .release);
    try testing.expect(health.allReady());
}
