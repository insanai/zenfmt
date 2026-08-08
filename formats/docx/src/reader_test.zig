//! Facet-attachment tests for the DOCX reader (ZDS 0013), split out of
//! `reader.zig` (file-size rule). Each test builds a minimal stored
//! archive in memory and drives the public `read` through a bare
//! `ReadContext`, then asserts on the facet tables and the resource store.

const std = @import("std");
const core = @import("zenfmt_core");
const ooxml = @import("zenfmt_ooxml");
const read = @import("package.zig").read;

const testing = std.testing;
const zip = ooxml.zip;

const Converted = struct {
    doc: core.ast.Document,
    reports: []const core.Report,
};

fn convertDocx(arena: std.mem.Allocator, archive_bytes: []const u8) !Converted {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = archive_bytes },
        .input_name = "test.docx",
        .reports = reports,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return .{ .doc = doc, .reports = try reports.finalize() };
}

const document_prefix =
    \\<w:document
    \\  xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    \\  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    \\  xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    \\  xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><w:body>
;

test "styles, revisions, and page geometry become facets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const archive_bytes = try zip.buildStoredArchive(arena, &.{
        .{ .name = "word/document.xml", .data = document_prefix ++
            \\<w:p><w:pPr><w:pStyle w:val="BodyQuote"/></w:pPr>
            \\<w:r><w:t>styled</w:t></w:r>
            \\<w:ins w:author="ada" w:date="2026-01-02T03:04:05Z">
            \\<w:r><w:t> inserted</w:t></w:r></w:ins>
            \\<w:del w:author="grace"><w:r><w:delText>gone</w:delText></w:r></w:del>
            \\</w:p>
            \\<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>
            \\</w:body></w:document>
        },
    });
    const converted = try convertDocx(arena, archive_bytes);
    const doc = converted.doc;
    const store = doc.store;

    // One styled paragraph.
    try testing.expectEqual(@as(usize, 1), store.style_facets.items.len);
    const style = store.style_facets.items[0];
    try testing.expectEqualStrings("BodyQuote", store.textSlice(style.name));

    // The insertion and the deletion both survive as revision rows on the
    // same paragraph entity, in attach order.
    try testing.expectEqual(@as(usize, 2), store.revision_facets.items.len);
    const insertion = store.revision_facets.items[0];
    try testing.expectEqual(core.facets.RevisionKind.insertion, insertion.kind);
    try testing.expectEqualStrings("ada", store.textSlice(insertion.author));
    try testing.expectEqualStrings("2026-01-02T03:04:05Z", store.textSlice(insertion.timestamp));
    const deletion = store.revision_facets.items[1];
    try testing.expectEqual(core.facets.RevisionKind.deletion, deletion.kind);
    try testing.expectEqualStrings("grace", store.textSlice(deletion.author));
    try testing.expectEqual(insertion.entity, deletion.entity);

    // Page size in twips became one page layout facet in EMU.
    try testing.expectEqual(@as(usize, 1), store.layout_facets.items.len);
    const layout = store.layout_facets.items[0];
    try testing.expectEqual(core.facets.Surface.page, layout.surface);
    try testing.expectEqual(@as(i32, 12240 * 635), layout.width);
    try testing.expectEqual(@as(i32, 15840 * 635), layout.height);

    // The facets bind to the paragraph's entity, resolvable via the doc.
    const entity = doc.blockEntity(@enumFromInt(doc.body.startRaw())).?;
    try testing.expectEqualStrings("BodyQuote", store.textSlice(doc.styleOf(entity).?.name));
    try testing.expectEqual(@as(usize, 2), doc.revisionsOf(entity).len);
}

test "embedded image bytes register with the resource store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const png = "\x89PNG\r\n\x1a\nminimal";
    const archive_bytes = try zip.buildStoredArchive(arena, &.{
        .{ .name = "word/document.xml", .data = document_prefix ++
            \\<w:p><w:r><w:drawing>
            \\<wp:inline><a:blip r:embed="rId7"/>
            \\<wp:docPr descr="a chart"/></wp:inline>
            \\</w:drawing></w:r></w:p>
            \\</w:body></w:document>
        },
        .{
            .name = "word/_rels/document.xml.rels",
            .data =
            \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            \\<Relationship Id="rId7"
            \\ Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
            \\ Target="media/image1.png"/>
            \\</Relationships>
            ,
        },
        .{ .name = "word/media/image1.png", .data = png },
    });
    const converted = try convertDocx(arena, archive_bytes);
    const store = converted.doc.store;

    try testing.expectEqual(@as(usize, 1), store.resources.items.len);
    const resource = store.resources.items[0];
    try testing.expectEqualStrings("word/media/image1.png", store.textSlice(resource.source));
    try testing.expectEqualStrings("image/png", store.textSlice(resource.mime));
    const bytes = store.resource_bytes.items[resource.bytes.start..][0..resource.bytes.len];
    try testing.expectEqualStrings(png, bytes);
}
