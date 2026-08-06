//! `styles.xml` resolution (ZDS 0002, DOCX): which paragraph styles are
//! headings. The built-in `Heading1`..`Heading9` count, and so does any
//! style whose `w:basedOn` chain reaches one.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");

pub const wordprocessing_ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

pub const Styles = struct {
    /// Paragraph style id to heading level, chains resolved, unclamped.
    heading_levels: std.StringHashMapUnmanaged(u8) = .empty,

    pub fn headingLevel(styles: *const Styles, style_id: []const u8) ?u8 {
        return styles.heading_levels.get(style_id);
    }

    pub const empty: Styles = .{};
};

const RawStyle = struct {
    id: []const u8,
    based_on: []const u8,
    direct_level: ?u8,
};

pub fn parse(
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: core.Limits,
) (xml.Error || error{OutOfMemory})!Styles {
    var raw: std.ArrayList(RawStyle) = .empty;
    defer raw.deinit(arena);

    var parser = xml.Parser.init(arena, bytes, limits.max_xml_depth);
    defer parser.deinit();

    var current: ?RawStyle = null;
    var is_paragraph_style = false;
    while (true) {
        switch (try parser.next()) {
            .done => break,
            .element_start => |element| {
                if (element.name.is(wordprocessing_ns, "style")) {
                    var id: []const u8 = "";
                    is_paragraph_style = false;
                    for (element.attributes) |attribute| {
                        if (std.mem.eql(u8, attribute.name.local, "styleId")) {
                            id = try arena.dupe(u8, attribute.value);
                        } else if (std.mem.eql(u8, attribute.name.local, "type")) {
                            is_paragraph_style = std.mem.eql(u8, attribute.value, "paragraph");
                        }
                    }
                    if (current) |style| try raw.append(arena, style);
                    current = if (is_paragraph_style) .{
                        .id = id,
                        .based_on = "",
                        .direct_level = levelFromStyleId(id),
                    } else null;
                    if (element.self_closing) {
                        if (current) |style| try raw.append(arena, style);
                        current = null;
                    }
                } else if (element.name.is(wordprocessing_ns, "basedOn")) {
                    if (current) |*style| {
                        for (element.attributes) |attribute| {
                            if (std.mem.eql(u8, attribute.name.local, "val")) {
                                style.based_on = try arena.dupe(u8, attribute.value);
                            }
                        }
                    }
                } else if (element.name.is(wordprocessing_ns, "name")) {
                    if (current) |*style| {
                        if (style.direct_level == null) {
                            for (element.attributes) |attribute| {
                                if (std.mem.eql(u8, attribute.name.local, "val")) {
                                    style.direct_level = levelFromStyleName(attribute.value);
                                }
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
    if (current) |style| try raw.append(arena, style);

    // Resolve basedOn chains, bounded: a cycle or a chain past sixteen
    // hops resolves to "not a heading".
    var styles: Styles = .{};
    for (raw.items) |style| {
        var level = style.direct_level;
        var walk = style.based_on;
        var hops: u32 = 0;
        while (level == null and walk.len > 0 and hops < 16) : (hops += 1) {
            const parent = findRaw(raw.items, walk) orelse break;
            level = parent.direct_level;
            walk = parent.based_on;
        }
        if (level) |value| {
            try styles.heading_levels.put(arena, style.id, value);
        }
    }
    return styles;
}

fn findRaw(styles: []const RawStyle, id: []const u8) ?*const RawStyle {
    for (styles) |*style| {
        if (std.mem.eql(u8, style.id, id)) return style;
    }
    return null;
}

fn levelFromStyleId(id: []const u8) ?u8 {
    if (!std.ascii.startsWithIgnoreCase(id, "Heading")) return null;
    const digits = id["Heading".len..];
    if (digits.len != 1) return null;
    const level = std.fmt.parseInt(u8, digits, 10) catch return null;
    if (level < 1 or level > 9) return null;
    return level;
}

fn levelFromStyleName(name: []const u8) ?u8 {
    if (!std.ascii.startsWithIgnoreCase(name, "heading ")) return null;
    const digits = name["heading ".len..];
    const level = std.fmt.parseInt(u8, digits, 10) catch return null;
    if (level < 1 or level > 9) return null;
    return level;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "built-in headings and basedOn chains resolve" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \\  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>
        \\  <w:style w:type="paragraph" w:styleId="Chapter"><w:basedOn w:val="Heading1"/></w:style>
        \\  <w:style w:type="paragraph" w:styleId="Body"><w:name w:val="Body Text"/></w:style>
        \\  <w:style w:type="character" w:styleId="Heading2"><w:name w:val="heading 2"/></w:style>
        \\</w:styles>
    ;
    var styles = try parse(arena, source, .{});
    try testing.expectEqual(@as(?u8, 1), styles.headingLevel("Heading1"));
    try testing.expectEqual(@as(?u8, 1), styles.headingLevel("Chapter"));
    try testing.expectEqual(@as(?u8, null), styles.headingLevel("Body"));
    // Character styles never make headings.
    try testing.expectEqual(@as(?u8, null), styles.headingLevel("Heading2"));
}
