//! Name validation shared by every binding.
//!
//! Both the Python bridge and the browser ABI accept a display name for a
//! byte input. The engine uses that name for format detection fallback,
//! reports, manifest provenance, and resource directory naming, so a name
//! containing path syntax would let an in-memory caller steer where things
//! appear to come from. One implementation, so the two boundaries cannot
//! drift into disagreeing about what a name may contain.

const std = @import("std");

pub const max_display_name_bytes = 1024;

/// A display basename: non-empty, bounded, and free of directory separators
/// and control characters.
pub fn validDisplayName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_display_name_bytes) return false;
    for (name) |byte| switch (byte) {
        0...0x1f, 0x7f, '/', '\\' => return false,
        else => {},
    };
    return true;
}

test "display names refuse separators and control bytes" {
    try std.testing.expect(validDisplayName("report.docx"));
    try std.testing.expect(validDisplayName("übersicht.md"));
    try std.testing.expect(!validDisplayName(""));
    try std.testing.expect(!validDisplayName("a/b.md"));
    try std.testing.expect(!validDisplayName("a\\b.md"));
    try std.testing.expect(!validDisplayName("a\x00b"));
    try std.testing.expect(!validDisplayName("a\nb"));
}

test "a name at the bound is accepted and one past it is not" {
    const at_bound = "x" ** max_display_name_bytes;
    const past_bound = "x" ** (max_display_name_bytes + 1);
    try std.testing.expect(validDisplayName(at_bound));
    try std.testing.expect(!validDisplayName(past_bound));
}
