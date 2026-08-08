//! Bounded discovery of note-body forests reachable from block content.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const bits = @import("lowering_cost.zig");

pub const Ranges = struct {
    marks: []u64,
    order: []u32,
    len: u32 = 0,

    pub fn init(
        arena: std.mem.Allocator,
        count: usize,
    ) error{OutOfMemory}!Ranges {
        const marks = try arena.alloc(u64, bits.bitWordCount(count));
        @memset(marks, 0);
        return .{
            .marks = marks,
            .order = try arena.alloc(u32, count),
        };
    }

    pub fn reset(ranges: *Ranges) void {
        @memset(ranges.marks, 0);
        ranges.len = 0;
    }

    pub fn add(ranges: *Ranges, index: u32) void {
        assert(index < ranges.order.len);
        if (bits.bitIsSet(ranges.marks, index)) return;
        bits.bitSet(ranges.marks, index);
        ranges.order[ranges.len] = index;
        ranges.len += 1;
    }

    pub fn items(ranges: *const Ranges) []const u32 {
        return ranges.order[0..ranges.len];
    }
};

pub fn discover(
    arena: std.mem.Allocator,
    doc: *const ast.Document,
) error{OutOfMemory}!Ranges {
    const count = doc.store.block_ranges.items.len;
    var ranges = try Ranges.init(arena, count);
    if (count == 0) return ranges;
    discoverInRange(doc, doc.body, &ranges);
    var cursor: u32 = 0;
    while (cursor < ranges.len) : (cursor += 1) {
        const range = doc.store.block_ranges.items[ranges.order[cursor]];
        discoverInRange(doc, range, &ranges);
    }
    assert(ranges.len <= count);
    return ranges;
}

pub fn discoverInRange(
    doc: *const ast.Document,
    blocks: ast.BlockRange,
    ranges: *Ranges,
) void {
    const store = doc.store;
    var block = blocks.startRaw();
    while (block < blocks.endRaw()) : (block += 1) {
        const inlines = store.blocks.items(.inlines)[block];
        const end = inlines.endRaw();
        var cursor = inlines.startRaw();
        while (cursor < end) : (cursor += 1) {
            if (store.inlines.items(.tag)[cursor] != .note) continue;
            ranges.add(store.inlines.items(.payload)[cursor]);
        }
    }
    assert(block == blocks.endRaw());
}
