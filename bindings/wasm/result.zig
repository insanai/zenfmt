//! Result ownership for the browser ABI (ZDS 0015, Low-level ABI).
//!
//! A result is reached through a handle, not a pointer. The handle packs a
//! slot index with a generation counter, and the generation advances on every
//! free, so a stale handle names a slot whose generation no longer matches
//! and is answered with the invalid-handle status. That is the difference
//! between "double free is undefined behaviour we ask callers to avoid" and
//! "double free is a status code with a test".
//!
//! Handing raw pointers to page script would make that impossible: any 32-bit
//! number is a plausible pointer, and a freed one is indistinguishable from a
//! live one.

const std = @import("std");
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");
const exports = @import("exports.zig");
const memory = @import("memory.zig");
const request_mod = @import("request.zig");
const reports_mod = @import("reports.zig");

/// One worker converts one document at a time; the extra slots exist so a
/// page can hold a previous result while starting the next conversion, not so
/// it can accumulate them.
pub const slot_count = 16;

const slot_bits = 4;
comptime {
    std.debug.assert(1 << slot_bits == slot_count);
}

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    conversion: ?core.Conversion,
    status: u32,
    exit_class: u32,
    /// Canonical report array JSON including `exit_class` per report,
    /// arena-owned.
    reports_json: []const u8,

    pub fn ensemble(result: *const Result) ?core.MemoryEnsemble {
        if (result.conversion) |*conversion| return conversion.ensemble;
        return null;
    }
};

const Slot = struct {
    /// Advances on every release. Starting at 1 keeps handle zero — which is
    /// also the allocation-failure value — from ever naming a live result.
    generation: u28 = 1,
    result: ?Result = null,
};

var slots: [slot_count]Slot = @splat(.{});

fn handleFor(index: usize, generation: u28) u32 {
    return (@as(u32, generation) << slot_bits) | @as(u32, @intCast(index));
}

/// The live result a handle names, or null if it names none. A handle from a
/// previous generation, an out-of-range slot, and a fabricated number are all
/// simply "none".
pub fn lookup(handle: u32) ?*Result {
    if (handle == exports.failure) return null;
    const index: usize = handle & (slot_count - 1);
    const generation: u28 = @intCast(handle >> slot_bits);
    const slot = &slots[index];
    if (slot.generation != generation) return null;
    if (slot.result) |*result| return result;
    return null;
}

fn claim() ?struct { index: usize, generation: u28 } {
    for (&slots, 0..) |*slot, index| {
        if (slot.result == null) {
            return .{ .index = index, .generation = slot.generation };
        }
    }
    return null;
}

pub fn liveCount() u32 {
    var live: u32 = 0;
    for (&slots) |*slot| {
        if (slot.result != null) live += 1;
    }
    return live;
}

/// Converts and stores the result, returning its handle. Zero means only that
/// no result could be constructed — no free slot, or the arena itself could
/// not be created. A conversion that fails is a real handle carrying the
/// reports that explain why.
pub fn convert(request_bytes: []const u8, input: []const u8) u32 {
    const claimed = claim() orelse return exports.failure;
    const slot = &slots[claimed.index];

    slot.result = .{
        .arena = std.heap.ArenaAllocator.init(memory.allocator()),
        .conversion = null,
        .status = exports.status_invalid_request,
        .exit_class = @intFromEnum(core.report.ExitClass.usage),
        .reports_json = "[]",
    };
    const result = &slot.result.?;

    fill(result, request_bytes, input) catch {
        // Only an allocation failure reaches here; a refused request is a
        // filled result with a report.
        release(claimed.index);
        return exports.failure;
    };
    return handleFor(claimed.index, claimed.generation);
}

fn fill(
    result: *Result,
    request_bytes: []const u8,
    input: []const u8,
) error{OutOfMemory}!void {
    const arena = result.arena.allocator();
    var rejection: request_mod.Rejection = .malformed;
    const decoded = request_mod.decode(
        arena,
        request_bytes,
        input,
        &rejection,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRequest => {
            result.status = exports.status_invalid_request;
            result.exit_class = @intFromEnum(core.report.ExitClass.usage);
            result.reports_json = try reports_mod.serialize(
                arena,
                &.{reports_mod.rejection(rejection)},
            );
            return;
        },
    };

    // The browser bundle takes no host value: it is the same engine with the
    // filesystem compiled out, so there is nothing to hand it.
    const conversion = zenfmt.Browser.convert(memory.allocator(), .{}, decoded.options);
    result.conversion = conversion;
    result.status = switch (conversion.status) {
        .success => exports.status_success,
        .failed => exports.status_failed,
    };
    result.exit_class = @intFromEnum(conversion.exit_class);
    result.reports_json = try reports_mod.serialize(arena, conversion.reports);
}

fn release(index: usize) void {
    const slot = &slots[index];
    if (slot.result) |*result| {
        if (result.conversion) |*conversion| conversion.deinit(memory.allocator());
        result.arena.deinit();
    }
    slot.result = null;
    // Wrapping is deliberate and harmless: a handle only collides with a
    // later one after the same slot has been reused 2^28 times, and a page
    // holding a handle that long has already lost track of it.
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
}

/// Frees the result a handle names. Returns 0 on success and 1 if the handle
/// named nothing — a double free is a reported error, not corruption.
pub fn free(handle: u32) u32 {
    if (handle == exports.failure) return 1;
    const index: usize = handle & (slot_count - 1);
    const generation: u28 = @intCast(handle >> slot_bits);
    const slot = &slots[index];
    if (slot.generation != generation or slot.result == null) return 1;
    release(index);
    return 0;
}

/// Releases every live result. For tests and for a host that is tearing the
/// module down deliberately.
pub fn freeAll() void {
    for (0..slot_count) |index| {
        if (slots[index].result != null) release(index);
    }
}

const testing = std.testing;

test "a handle round-trips and a freed handle is refused" {
    defer freeAll();
    const handle = convert(
        \\{"schema":1,"name":"note.md"}
    , "# Title\n");
    try testing.expect(handle != exports.failure);
    try testing.expect(lookup(handle) != null);
    try testing.expectEqual(@as(u32, 0), free(handle));
    try testing.expect(lookup(handle) == null);
    try testing.expectEqual(@as(u32, 1), free(handle));
}

test "a fabricated handle names nothing" {
    defer freeAll();
    try testing.expect(lookup(0) == null);
    try testing.expect(lookup(0xdead_beef) == null);
    try testing.expect(lookup(std.math.maxInt(u32)) == null);
}

test "a slot reused after a free does not answer the old handle" {
    defer freeAll();
    const first = convert(
        \\{"schema":1,"name":"a.md"}
    , "# A\n");
    try testing.expectEqual(@as(u32, 0), free(first));
    const second = convert(
        \\{"schema":1,"name":"b.md"}
    , "# B\n");
    try testing.expect(second != first);
    try testing.expect(lookup(first) == null);
    try testing.expect(lookup(second) != null);
}

test "conversions return the accounting to baseline, success or failure" {
    defer freeAll();
    const before = memory.accounting.live_bytes;
    for (0..64) |_| {
        const ok = convert(
            \\{"schema":1,"name":"note.md"}
        , "# Title\n\nBody.\n");
        try testing.expectEqual(exports.status_success, lookup(ok).?.status);
        try testing.expectEqual(@as(u32, 0), free(ok));

        const refused = convert(
            \\{"schema":1,"name":"bad/name.md"}
        , "");
        try testing.expectEqual(
            exports.status_invalid_request,
            lookup(refused).?.status,
        );
        try testing.expectEqual(@as(u32, 0), free(refused));
    }
    try testing.expectEqual(before, memory.accounting.live_bytes);
    try testing.expectEqual(@as(u32, 0), liveCount());
}

test "the slot table is bounded and refuses an over-allocation" {
    defer freeAll();
    var handles: [slot_count]u32 = undefined;
    for (&handles) |*handle| {
        handle.* = convert(
            \\{"schema":1,"name":"note.md"}
        , "# T\n");
        try testing.expect(handle.* != exports.failure);
    }
    try testing.expectEqual(@as(u32, slot_count), liveCount());
    // One more than the table holds is refused rather than growing it.
    try testing.expectEqual(exports.failure, convert(
        \\{"schema":1,"name":"note.md"}
    , "# T\n"));
    for (handles) |handle| try testing.expectEqual(@as(u32, 0), free(handle));
}
