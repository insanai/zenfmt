//! Small DOCX lexical helpers, shared across the reader's files.

const std = @import("std");
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const reader_mod = @import("reader.zig");

pub const RunProps = reader_mod.RunProps;

pub fn runStyleTags(props: RunProps, out: *[8]core.InlineTag) u8 {
    var count: u8 = 0;
    const order = [_]struct { on: bool, tag: core.InlineTag }{
        .{ .on = props.strong, .tag = .strong },
        .{ .on = props.emphasis, .tag = .emphasis },
        .{ .on = props.strike, .tag = .strikethrough },
        .{ .on = props.superscript, .tag = .superscript },
        .{ .on = props.subscript, .tag = .subscript },
        .{ .on = props.small_caps, .tag = .small_caps },
        .{ .on = props.underline, .tag = .underline },
    };
    for (order) |entry| {
        if (!entry.on) continue;
        out[count] = entry.tag;
        count += 1;
    }
    return count;
}

pub fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

pub fn stringAttribute(attributes: []const xml.Attribute, local: []const u8) ?[]const u8 {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name.local, local)) return attribute.value;
    }
    return null;
}

/// A run-property toggle: present means on, unless `w:val` clears it.
pub fn toggleValue(attributes: []const xml.Attribute) bool {
    const value = stringAttribute(attributes, "val") orelse return true;
    return !(std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "none"));
}

pub fn isMonospaceFont(font: []const u8) bool {
    const known = [_][]const u8{
        "Consolas",        "Courier New",      "Courier",        "Menlo",
        "Monaco",          "SF Mono",          "Cascadia Code",  "Cascadia Mono",
        "Fira Code",       "Fira Mono",        "JetBrains Mono", "Source Code Pro",
        "Liberation Mono", "DejaVu Sans Mono",
    };
    for (known) |candidate| {
        if (std.ascii.eqlIgnoreCase(font, candidate)) return true;
    }
    return false;
}

/// `HYPERLINK "https://..."` or `HYPERLINK https://...`, with options
/// ignored.
pub fn parseHyperlinkInstruction(
    arena: std.mem.Allocator,
    instruction: []const u8,
) error{ OutOfMemory, NoMatch }![]const u8 {
    const trimmed = std.mem.trim(u8, instruction, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "HYPERLINK")) return error.NoMatch;
    var rest = std.mem.trimStart(u8, trimmed["HYPERLINK".len..], " \t");
    if (rest.len == 0) return error.NoMatch;
    if (rest[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.NoMatch;
        return arena.dupe(u8, rest[1..close]);
    }
    const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    return arena.dupe(u8, rest[0..end]);
}
