//! Bounded spelling suggestions for format names.

const std = @import("std");

/// Bounded Levenshtein distance for did-you-mean suggestions. Format names
/// longer than the cap are deliberately treated as unrelated.
pub fn editDistance(a: []const u8, b: []const u8) usize {
    const cap = 32;
    if (a.len > cap or b.len > cap) return cap;
    var previous: [cap + 1]usize = undefined;
    var current: [cap + 1]usize = undefined;
    for (0..b.len + 1) |index| previous[index] = index;
    for (a, 0..) |a_byte, a_index| {
        current[0] = a_index + 1;
        for (b, 0..) |b_byte, b_index| {
            const substitution = previous[b_index] +
                @intFromBool(a_byte != b_byte);
            current[b_index + 1] = @min(
                @min(current[b_index] + 1, previous[b_index + 1] + 1),
                substitution,
            );
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

pub fn closest(name: []const u8, known: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (known) |candidate| {
        const distance = editDistance(name, candidate);
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    return best;
}

test "edit distance suggests only a nearby format" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("docs", "docx"));
    const known = [_][]const u8{ "docx", "markdown", "text" };
    try std.testing.expectEqualStrings("docx", closest("docs", &known).?);
    try std.testing.expectEqual(@as(?[]const u8, null), closest("zzzzz", &known));
}
