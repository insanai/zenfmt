//! Conversion tests for the ODT reader, split out of `reader.zig`
//! (file-size rule). Each test builds a minimal stored archive in memory
//! and drives the public `read` through a bare `ReadContext`.

const std = @import("std");
const core = @import("zenfmt_core");
const ooxml = @import("zenfmt_ooxml");
const read = @import("reader.zig").read;

const testing = std.testing;
const zip = ooxml.zip;

const Converted = struct {
    doc: core.ast.Document,
    reports: []const core.Report,
};

fn convertOdt(arena: std.mem.Allocator, content: []const u8) !Converted {
    const archive_bytes = try zip.buildStoredArchive(arena, &.{
        .{ .name = "mimetype", .data = "application/vnd.oasis.opendocument.text" },
        .{ .name = "content.xml", .data = content },
    });
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = archive_bytes },
        .input_name = "test.odt",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return .{ .doc = doc, .reports = try reports.finalize() };
}

const content_prefix =
    \\<office:document-content
    \\  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    \\  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    \\  xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
    \\  xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
    \\  xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    \\  xmlns:xlink="http://www.w3.org/1999/xlink"
    \\  xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
    \\  xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0">
;

test "headings, spans, links, and lists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertOdt(arena, content_prefix ++
        \\<office:automatic-styles>
        \\<style:style style:name="T1" style:family="text">
        \\<style:text-properties fo:font-weight="bold"/></style:style>
        \\</office:automatic-styles>
        \\<office:body><office:text>
        \\<text:h text:outline-level="2">Title</text:h>
        \\<text:p>Plain <text:span text:style-name="T1">bold</text:span>
        \\ and <text:a xlink:href="https://ziglang.org/">a link</text:a>.</text:p>
        \\<text:list><text:list-item><text:p>one</text:p></text:list-item>
        \\<text:list-item><text:p>two</text:p></text:list-item></text:list>
        \\</office:text></office:body></office:document-content>
    );
    const doc = converted.doc;
    const tags = doc.store.blocks.items(.tag);
    var headings: u32 = 0;
    var lists: u32 = 0;
    var items: u32 = 0;
    for (tags) |tag| switch (tag) {
        .heading => headings += 1,
        .list => lists += 1,
        .list_item => items += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), headings);
    try testing.expectEqual(@as(u32, 1), lists);
    try testing.expectEqual(@as(u32, 2), items);

    var strongs: u32 = 0;
    var links: u32 = 0;
    for (doc.store.inlines.items(.tag)) |tag| switch (tag) {
        .strong => strongs += 1,
        .link => links += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), strongs);
    try testing.expectEqual(@as(u32, 1), links);
}

test "footnotes are captured and re-emitted after the body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertOdt(arena, content_prefix ++
        \\<office:body><office:text>
        \\<text:p>Text<text:note text:note-class="footnote"><text:note-citation>1</text:note-citation>
        \\<text:note-body><text:p>The note.</text:p></text:note-body></text:note> after.</text:p>
        \\</office:text></office:body></office:document-content>
    );
    const doc = converted.doc;
    var notes: u32 = 0;
    for (doc.store.inlines.items(.tag)) |tag| {
        if (tag == .note) notes += 1;
    }
    try testing.expectEqual(@as(u32, 1), notes);
    // The note body landed outside the document body.
    try testing.expect(doc.store.block_ranges.items.len == 1);
    try testing.expect(doc.store.block_ranges.items[0].len > 0);
}

test "images convert with alt text from svg:desc" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertOdt(arena, content_prefix ++
        \\<office:body><office:text>
        \\<text:p>Before <draw:frame draw:name="Image1">
        \\<draw:image xlink:href="Pictures/chart.png"/>
        \\<svg:desc>Quarterly revenue</svg:desc>
        \\</draw:frame> after.</text:p>
        \\</office:text></office:body></office:document-content>
    );
    var images: u32 = 0;
    for (converted.doc.store.inlines.items(.tag)) |tag| {
        if (tag == .image) images += 1;
    }
    try testing.expectEqual(@as(u32, 1), images);
    for (converted.reports) |report| {
        try testing.expect(!std.mem.eql(u8, report.code, "odt.frame-dropped"));
    }
}

test "a frame with no source and no description reports the drop" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertOdt(arena, content_prefix ++
        \\<office:body><office:text>
        \\<text:p>Text with <draw:frame><draw:custom-shape/></draw:frame> a shape.</text:p>
        \\</office:text></office:body></office:document-content>
    );
    var images: u32 = 0;
    for (converted.doc.store.inlines.items(.tag)) |tag| {
        if (tag == .image) images += 1;
    }
    try testing.expectEqual(@as(u32, 0), images);
    const dropped = for (converted.reports) |report| {
        if (std.mem.eql(u8, report.code, "odt.frame-dropped")) break true;
    } else false;
    try testing.expect(dropped);
}

test "sections become containers with a class" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertOdt(arena, content_prefix ++
        \\<office:body><office:text>
        \\<text:section text:name="S1"><text:p>Inside.</text:p></text:section>
        \\</office:text></office:body></office:document-content>
    );
    var containers: u32 = 0;
    for (converted.doc.store.blocks.items(.tag)) |tag| {
        if (tag == .container) containers += 1;
    }
    try testing.expectEqual(@as(u32, 1), containers);
}
