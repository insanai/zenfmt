//! `zenfmt_ooxml`: the Open Packaging Conventions shared by DOCX, XLSX,
//! and PPTX (ZDS 0002, The container) — the ZIP layer plus package
//! relationships.

const std = @import("std");
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");

pub const zip = @import("zip.zig");

pub const relationships_ns = "http://schemas.openxmlformats.org/package/2006/relationships";
pub const office_document_type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument";

pub const Relationship = struct {
    id: []const u8,
    type: []const u8,
    target: []const u8,
    external: bool,
};

pub const Relationships = struct {
    entries: []const Relationship,

    pub fn byId(rels: *const Relationships, id: []const u8) ?*const Relationship {
        for (rels.entries) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }

    pub fn byType(rels: *const Relationships, type_uri: []const u8) ?*const Relationship {
        for (rels.entries) |*entry| {
            if (std.mem.eql(u8, entry.type, type_uri)) return entry;
        }
        return null;
    }

    pub const empty: Relationships = .{ .entries = &.{} };
};

/// Parses one `.rels` part. Attribute values are copied into the arena
/// because the pull parser reuses its attribute buffer.
pub fn parseRelationships(
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: core.Limits,
) (xml.Error || error{OutOfMemory})!Relationships {
    var entries: std.ArrayList(Relationship) = .empty;
    var parser = xml.Parser.init(arena, bytes, limits.max_xml_depth);
    defer parser.deinit();

    while (true) {
        switch (try parser.next()) {
            .done => break,
            .element_start => |element| {
                if (!element.name.is(relationships_ns, "Relationship")) continue;
                var relationship: Relationship = .{
                    .id = "",
                    .type = "",
                    .target = "",
                    .external = false,
                };
                for (element.attributes) |attribute| {
                    if (std.mem.eql(u8, attribute.name.local, "Id")) {
                        relationship.id = try arena.dupe(u8, attribute.value);
                    } else if (std.mem.eql(u8, attribute.name.local, "Type")) {
                        relationship.type = try arena.dupe(u8, attribute.value);
                    } else if (std.mem.eql(u8, attribute.name.local, "Target")) {
                        relationship.target = try arena.dupe(u8, attribute.value);
                    } else if (std.mem.eql(u8, attribute.name.local, "TargetMode")) {
                        relationship.external = std.mem.eql(u8, attribute.value, "External");
                    }
                }
                try entries.append(arena, relationship);
            },
            else => {},
        }
    }
    return .{ .entries = entries.items };
}

/// Resolves a relationship target against the directory of the part that
/// owns the `.rels` file: `word/_rels/document.xml.rels` + `media/x.png`
/// gives `word/media/x.png`.
pub fn resolveTarget(
    arena: std.mem.Allocator,
    base_dir: []const u8,
    target: []const u8,
) error{OutOfMemory}![]const u8 {
    if (target.len > 0 and target[0] == '/') return arena.dupe(u8, target[1..]);
    if (base_dir.len == 0) return arena.dupe(u8, target);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base_dir, target });
}

test {
    _ = zip;
}

const testing = std.testing;

test "relationships parse and resolve" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rels =
        \\<?xml version="1.0"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        \\  <Relationship Id="rId7" Type="http://x/hyperlink" Target="https://ziglang.org/" TargetMode="External"/>
        \\</Relationships>
    ;
    const parsed = try parseRelationships(arena, rels, .{});
    try testing.expectEqual(@as(usize, 2), parsed.entries.len);
    const office = parsed.byType(office_document_type).?;
    try testing.expectEqualStrings("word/document.xml", office.target);
    const link = parsed.byId("rId7").?;
    try testing.expect(link.external);

    const resolved = try resolveTarget(arena, "word", "media/image1.png");
    try testing.expectEqualStrings("word/media/image1.png", resolved);
}
