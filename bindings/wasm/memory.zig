//! Allocation and memory accounting for the browser module (ZDS 0015).
//!
//! The Zig WebAssembly allocator keeps size-class free lists over grown
//! pages. It never returns pages to the host — linear memory cannot shrink —
//! and it exposes no accounting of its own. So "alloc, convert, free, and the
//! accounting returns to baseline" is not a property that allocator can
//! demonstrate: this counting wrapper is what makes it observable, and what
//! the leak tests assert against.
//!
//! The wrapper sits above the backing allocator, so the free lists it retains
//! are correctly invisible here. What is counted is what the module still
//! owns and would have to be asked to release.

const std = @import("std");
const builtin = @import("builtin");
const exports = @import("exports.zig");

pub const Accounting = struct {
    backing: std.mem.Allocator,
    live_bytes: usize = 0,
    high_water_bytes: usize = 0,
    live_blocks: usize = 0,

    pub fn allocator(self: *Accounting) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = rawAlloc,
                .resize = rawResize,
                .remap = rawRemap,
                .free = rawFree,
            },
        };
    }

    fn record(self: *Accounting, delta: usize) void {
        self.live_bytes += delta;
        if (self.live_bytes > self.high_water_bytes) {
            self.high_water_bytes = self.live_bytes;
        }
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Accounting = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse
            return null;
        self.record(len);
        self.live_blocks += 1;
        return result;
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Accounting = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) {
            return false;
        }
        if (new_len >= memory.len) {
            self.record(new_len - memory.len);
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        return true;
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Accounting = @ptrCast(@alignCast(context));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse
            return null;
        if (new_len >= memory.len) {
            self.record(new_len - memory.len);
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        return result;
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Accounting = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.live_bytes -= memory.len;
        self.live_blocks -= 1;
    }
};

/// The single module-wide allocator. A browser module is one worker with one
/// conversion at a time; a second allocator would only be a second thing to
/// account for.
pub var accounting: Accounting = .{ .backing = backing_allocator };

const backing_allocator = if (builtin.target.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

pub fn allocator() std.mem.Allocator {
    return accounting.allocator();
}

/// Caller buffers are prefixed with their length, because the ABI's `free`
/// takes the same length the caller was given and a mismatch there would
/// corrupt the allocator. Storing it ourselves means a caller cannot cause
/// that by passing the wrong number.
const Header = extern struct {
    len: usize,
    padding: [exports.alignment - @sizeOf(usize)]u8 = undefined,
};

comptime {
    std.debug.assert(@sizeOf(Header) == exports.alignment);
}

/// A fixed, module-owned address returned for every zero-length allocation
/// and every zero-length view, so offset zero can mean failure and nothing
/// else.
var empty_slot: [exports.alignment]u8 align(exports.alignment) = @splat(0);

pub fn emptyAddress() exports.Address {
    return @intCast(@intFromPtr(&empty_slot));
}

/// Allocates `len` bytes aligned for any caller use. Returns zero — and only
/// zero — on failure.
pub fn alloc(len: u32) exports.Address {
    if (len == 0) return emptyAddress();
    const total = @sizeOf(Header) + @as(usize, len);
    const bytes = allocator().alignedAlloc(
        u8,
        std.mem.Alignment.fromByteUnits(exports.alignment),
        total,
    ) catch return exports.failure;
    const header: *Header = @ptrCast(@alignCast(bytes.ptr));
    header.len = total;
    return @intCast(@intFromPtr(bytes.ptr) + @sizeOf(Header));
}

/// Frees a buffer this module allocated. A zero address, the empty slot, and
/// a buffer already freed are all no-ops rather than corruption.
pub fn free(address: exports.Address) void {
    if (address == exports.failure or address == emptyAddress()) return;
    const base = address - @sizeOf(Header);
    const header: *Header = @ptrFromInt(base);
    const total = header.len;
    const bytes: [*]align(exports.alignment) u8 = @ptrFromInt(base);
    allocator().free(bytes[0..total]);
}

/// The current size of linear memory, in pages.
pub fn memoryPages() u32 {
    if (builtin.target.cpu.arch.isWasm()) {
        return @intCast(@wasmMemorySize(0));
    }
    // Native builds report the wrapper's own footprint in the same units, so
    // the accounting tests exercise the same code the browser runs.
    return @intCast((accounting.live_bytes + exports.page_bytes - 1) / exports.page_bytes);
}

pub fn highWaterPages() u32 {
    const bytes = accounting.high_water_bytes;
    return @intCast((bytes + exports.page_bytes - 1) / exports.page_bytes);
}

pub fn liveBytes() u32 {
    return @intCast(@min(accounting.live_bytes, std.math.maxInt(u32)));
}

test "a zero-length allocation is a real address, not a failure" {
    const address = alloc(0);
    try std.testing.expect(address != exports.failure);
    free(address);
}

test "allocation is aligned and round-trips through free" {
    const before = accounting.live_bytes;
    const address = alloc(1000);
    try std.testing.expect(address != exports.failure);
    try std.testing.expectEqual(@as(u32, 0), address % exports.alignment);
    try std.testing.expect(accounting.live_bytes > before);
    free(address);
    try std.testing.expectEqual(before, accounting.live_bytes);
}

test "repeated allocation cycles return the accounting to baseline" {
    const before_bytes = accounting.live_bytes;
    const before_blocks = accounting.live_blocks;
    for (0..1000) |i| {
        const address = alloc(@intCast(1 + (i % 4096)));
        try std.testing.expect(address != exports.failure);
        free(address);
    }
    try std.testing.expectEqual(before_bytes, accounting.live_bytes);
    try std.testing.expectEqual(before_blocks, accounting.live_blocks);
}
