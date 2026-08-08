//! Monotonic and random lookup over sorted lowering decisions.

const std = @import("std");
const assert = std.debug.assert;

pub fn Cursor(comptime Decision: type) type {
    return struct {
        decisions: []const Decision,
        index: usize = 0,
        previous: ?u32 = null,

        const Self = @This();

        pub fn at(cursor: *Self, node: u32) ?*const Decision {
            if (cursor.previous) |previous| {
                assert(previous < node);
            } else {
                cursor.index = lowerBound(Decision, cursor.decisions, node);
            }
            cursor.previous = node;
            while (cursor.index < cursor.decisions.len and
                cursor.decisions[cursor.index].node < node)
            {
                cursor.index += 1;
            }
            if (cursor.index == cursor.decisions.len or
                cursor.decisions[cursor.index].node != node)
            {
                return null;
            }
            const selected = &cursor.decisions[cursor.index];
            cursor.index += 1;
            return selected;
        }
    };
}

pub fn find(
    comptime Decision: type,
    decisions: []const Decision,
    node: u32,
) ?*const Decision {
    const index = lowerBound(Decision, decisions, node);
    if (index == decisions.len or decisions[index].node != node) return null;
    return &decisions[index];
}

fn lowerBound(
    comptime Decision: type,
    decisions: []const Decision,
    node: u32,
) usize {
    var low: usize = 0;
    var high = decisions.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (decisions[middle].node < node) low = middle + 1 else high = middle;
    }
    return low;
}
