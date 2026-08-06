//! `numbering.xml` (ZDS 0002, Numbering, the hard case): `numId` points
//! through a concrete `w:num` to an abstract definition saying whether each
//! level is a bullet or a number and where it starts. The paragraph carries
//! only the pointer; the truth lives here.

const std = @import("std");
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");

const wordprocessing_ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

pub const Level = struct {
    ordered: bool,
    start: i64,

    pub const bullet: Level = .{ .ordered = false, .start = 1 };
};

pub const Numbering = struct {
    /// abstract id and level to definition.
    abstract: std.AutoHashMapUnmanaged(u64, Level) = .empty,
    /// concrete numId to abstract id.
    concrete: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    pub const empty: Numbering = .{};

    /// The definition for a paragraph's `numId`/`ilvl` pair; a bullet when
    /// the pointer dangles, which real documents do produce.
    pub fn level(numbering: *const Numbering, num_id: u32, ilvl: u8) Level {
        const abstract_id = numbering.concrete.get(num_id) orelse return .bullet;
        return numbering.abstract.get(key(abstract_id, ilvl)) orelse .bullet;
    }
};

fn key(abstract_id: u32, ilvl: u8) u64 {
    return (@as(u64, abstract_id) << 8) | ilvl;
}

pub fn parse(
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: core.Limits,
) (xml.Error || error{OutOfMemory})!Numbering {
    var numbering: Numbering = .{};
    var parser = xml.Parser.init(arena, bytes, limits.max_xml_depth);
    defer parser.deinit();

    var abstract_id: ?u32 = null;
    var concrete_id: ?u32 = null;
    var ilvl: ?u8 = null;
    var current: Level = .bullet;

    while (true) {
        switch (try parser.next()) {
            .done => break,
            .element_start => |element| {
                if (element.name.is(wordprocessing_ns, "abstractNum")) {
                    concrete_id = null;
                    abstract_id = intAttribute(u32, element.attributes, "abstractNumId");
                } else if (element.name.is(wordprocessing_ns, "num")) {
                    abstract_id = null;
                    concrete_id = intAttribute(u32, element.attributes, "numId");
                } else if (element.name.is(wordprocessing_ns, "abstractNumId")) {
                    if (concrete_id) |num_id| {
                        if (intAttribute(u32, element.attributes, "val")) |value| {
                            try numbering.concrete.put(arena, num_id, value);
                        }
                    }
                } else if (element.name.is(wordprocessing_ns, "lvl")) {
                    ilvl = intAttribute(u8, element.attributes, "ilvl");
                    current = .bullet;
                } else if (element.name.is(wordprocessing_ns, "numFmt")) {
                    if (stringAttribute(element.attributes, "val")) |value| {
                        current.ordered = !std.mem.eql(u8, value, "bullet") and
                            !std.mem.eql(u8, value, "none");
                    }
                } else if (element.name.is(wordprocessing_ns, "start")) {
                    if (intAttribute(i64, element.attributes, "val")) |value| {
                        current.start = value;
                    }
                }
            },
            .element_end => |name| {
                if (std.mem.eql(u8, name.local, "lvl")) {
                    if (abstract_id != null and ilvl != null) {
                        try numbering.abstract.put(arena, key(abstract_id.?, ilvl.?), current);
                    }
                    ilvl = null;
                }
            },
            else => {},
        }
    }
    return numbering;
}

fn intAttribute(comptime T: type, attributes: []const xml.Attribute, local: []const u8) ?T {
    const value = stringAttribute(attributes, local) orelse return null;
    return std.fmt.parseInt(T, value, 10) catch null;
}

fn stringAttribute(attributes: []const xml.Attribute, local: []const u8) ?[]const u8 {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name.local, local)) return attribute.value;
    }
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "abstract definitions resolve through concrete pointers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \\  <w:abstractNum w:abstractNumId="0">
        \\    <w:lvl w:ilvl="0"><w:start w:val="3"/><w:numFmt w:val="decimal"/></w:lvl>
        \\    <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
        \\  </w:abstractNum>
        \\  <w:num w:numId="7"><w:abstractNumId w:val="0"/></w:num>
        \\</w:numbering>
    ;
    const numbering = try parse(arena, source, .{});
    const top = numbering.level(7, 0);
    try testing.expect(top.ordered);
    try testing.expectEqual(@as(i64, 3), top.start);
    try testing.expect(!numbering.level(7, 1).ordered);
    // A dangling pointer degrades to a bullet rather than failing.
    try testing.expect(!numbering.level(99, 0).ordered);
}
