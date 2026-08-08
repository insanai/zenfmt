//! Checked lexicographic loss arithmetic and graded strict predicates.

const std = @import("std");
const assert = std.debug.assert;

pub const LossCost = [6]u64;
pub const zero: LossCost = .{ 0, 0, 0, 0, 0, 0 };
pub const Error = error{CostOverflow};

pub fn add(a: LossCost, b: LossCost) Error!LossCost {
    var sum: LossCost = undefined;
    for (&sum, a, b) |*out, x, y| {
        out.* = std.math.add(u64, x, y) catch return error.CostOverflow;
    }
    return sum;
}

pub fn scale(value: LossCost, count: u32) Error!LossCost {
    var scaled: LossCost = undefined;
    for (&scaled, value) |*out, component| {
        out.* = std.math.mul(u64, component, count) catch return error.CostOverflow;
    }
    return scaled;
}

pub fn lessThan(a: LossCost, b: LossCost) bool {
    for (a, b) |x, y| {
        if (x < y) return true;
        if (x > y) return false;
    }
    return false;
}

pub fn bitWordCount(count: usize) usize {
    return (count + 63) / 64;
}

pub fn bitIsSet(bits: []const u64, index: u32) bool {
    assert(index / 64 < bits.len);
    return bits[index / 64] & (@as(u64, 1) << @intCast(index % 64)) != 0;
}

pub fn bitSet(bits: []u64, index: u32) void {
    assert(index / 64 < bits.len);
    assert(!bitIsSet(bits, index));
    bits[index / 64] |= @as(u64, 1) << @intCast(index % 64);
}

pub const Strictness = enum(u8) {
    off,
    content,
    structure,
    exact,

    pub fn refuses(grade: Strictness, loss: LossCost) bool {
        assert(loss.len == 6);
        return switch (grade) {
            .off => false,
            .content => loss[0] > 0,
            .structure => loss[0] > 0 or loss[1] > 0,
            .exact => loss[0] > 0 or loss[1] > 0 or loss[2] > 0,
        };
    }

    pub fn parse(value: []const u8) ?Strictness {
        if (std.mem.eql(u8, value, "content")) return .content;
        if (std.mem.eql(u8, value, "structure")) return .structure;
        if (std.mem.eql(u8, value, "exact")) return .exact;
        return null;
    }
};

test "loss arithmetic refuses overflow instead of saturating" {
    const testing = std.testing;
    const maximum: LossCost = .{ std.math.maxInt(u64), 0, 0, 0, 0, 0 };
    try testing.expectError(
        error.CostOverflow,
        add(maximum, .{ 1, 0, 0, 0, 0, 0 }),
    );
    try testing.expectError(
        error.CostOverflow,
        scale(.{ std.math.maxInt(u64), 0, 0, 0, 0, 0 }, 2),
    );
}

test "lexicographic cost honors the declared loss priority" {
    const testing = std.testing;
    try testing.expect(lessThan(
        .{ 0, std.math.maxInt(u64), 0, 0, 0, 0 },
        .{ 1, 0, 0, 0, 0, 0 },
    ));
    try testing.expect(!lessThan(zero, zero));
}
