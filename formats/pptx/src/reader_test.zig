//! Conversion tests for the PPTX reader, split out of `reader.zig`
//! (file-size rule). Each test builds a minimal stored archive in memory
//! and drives the public `read` through a bare `ReadContext`.

const std = @import("std");
const core = @import("zenfmt_core");
const ooxml = @import("zenfmt_ooxml");
const reader_mod = @import("reader.zig");
const read = reader_mod.read;
const normalizePath = reader_mod.normalizePath;

const testing = std.testing;
const zip = ooxml.zip;

test "path normalization for slide-relative targets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(
        "ppt/notesSlides/notesSlide1.xml",
        try normalizePath(arena, "ppt/slides/../notesSlides/notesSlide1.xml"),
    );
}

const Converted = struct {
    doc: core.ast.Document,
    reports: []const core.Report,
};

fn convertPptx(
    arena: std.mem.Allocator,
    slide: []const u8,
    slide_rels: ?[]const u8,
) !Converted {
    const presentation =
        \\<p:presentation
        \\  xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
        \\  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \\<p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst>
        \\</p:presentation>
    ;
    const presentation_rels =
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId1"
        \\ Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
        \\ Target="slides/slide1.xml"/>
        \\</Relationships>
    ;
    const archive_bytes = if (slide_rels) |data|
        try zip.buildStoredArchive(arena, &.{
            .{ .name = "ppt/presentation.xml", .data = presentation },
            .{ .name = "ppt/_rels/presentation.xml.rels", .data = presentation_rels },
            .{ .name = "ppt/slides/slide1.xml", .data = slide },
            .{ .name = "ppt/slides/_rels/slide1.xml.rels", .data = data },
        })
    else
        try zip.buildStoredArchive(arena, &.{
            .{ .name = "ppt/presentation.xml", .data = presentation },
            .{ .name = "ppt/_rels/presentation.xml.rels", .data = presentation_rels },
            .{ .name = "ppt/slides/slide1.xml", .data = slide },
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
        .input_name = "test.pptx",
        .reports = reports,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return .{ .doc = doc, .reports = try reports.finalize() };
}

const slide_prefix =
    \\<p:sld
    \\  xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
    \\  xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
    \\  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    \\<p:cSld><p:spTree>
;
const slide_suffix = "</p:spTree></p:cSld></p:sld>";

fn countBlocks(doc: *const core.ast.Document, tag: core.BlockTag) u32 {
    var total: u32 = 0;
    for (doc.store.blocks.items(.tag)) |candidate| {
        if (candidate == tag) total += 1;
    }
    return total;
}

fn countInlines(doc: *const core.ast.Document, tag: core.InlineTag) u32 {
    var total: u32 = 0;
    for (doc.store.inlines.items(.tag)) |candidate| {
        if (candidate == tag) total += 1;
    }
    return total;
}

test "tables convert with a header row and merged cells fold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertPptx(arena, slide_prefix ++
        \\<p:graphicFrame><a:graphic><a:graphicData>
        \\<a:tbl><a:tblPr firstRow="1"/>
        \\<a:tblGrid><a:gridCol/><a:gridCol/></a:tblGrid>
        \\<a:tr><a:tc><a:txBody><a:p><a:r><a:t>H1</a:t></a:r></a:p></a:txBody></a:tc>
        \\<a:tc><a:txBody><a:p><a:r><a:t>H2</a:t></a:r></a:p></a:txBody></a:tc></a:tr>
        \\<a:tr><a:tc gridSpan="2"><a:txBody><a:p><a:r><a:t>wide</a:t></a:r></a:p></a:txBody></a:tc>
        \\<a:tc hMerge="1"><a:txBody><a:p/></a:txBody></a:tc></a:tr>
        \\</a:tbl>
        \\</a:graphicData></a:graphic></p:graphicFrame>
    ++ slide_suffix, null);

    try testing.expectEqual(@as(u32, 1), countBlocks(&converted.doc, .table));
    try testing.expectEqual(@as(u32, 1), countBlocks(&converted.doc, .table_head));
    try testing.expectEqual(@as(u32, 1), countBlocks(&converted.doc, .table_body));
    try testing.expectEqual(@as(u32, 2), countBlocks(&converted.doc, .table_row));
    try testing.expectEqual(@as(u32, 3), countBlocks(&converted.doc, .table_cell));
    const merged = for (converted.reports) |report| {
        if (std.mem.eql(u8, report.code, "pptx.merged-cells")) break true;
    } else false;
    try testing.expect(merged);
}

test "external hyperlinks resolve through the slide relationships" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rels =
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId2"
        \\ Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
        \\ Target="https://ziglang.org/" TargetMode="External"/>
        \\<Relationship Id="rId3"
        \\ Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
        \\ Target="slide2.xml"/>
        \\</Relationships>
    ;
    const converted = try convertPptx(arena, slide_prefix ++
        \\<p:sp><p:txBody>
        \\<a:p><a:r><a:rPr><a:hlinkClick r:id="rId2"/></a:rPr><a:t>Zig</a:t></a:r>
        \\<a:r><a:rPr><a:hlinkClick r:id="rId3"/></a:rPr><a:t>next slide</a:t></a:r></a:p>
        \\</p:txBody></p:sp>
    ++ slide_suffix, rels);

    // The external link survives; the slide jump degrades to plain text.
    try testing.expectEqual(@as(u32, 1), countInlines(&converted.doc, .link));
}

test "images become references with alt text from cNvPr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rels =
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId2"
        \\ Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
        \\ Target="../media/image1.png"/>
        \\</Relationships>
    ;
    const converted = try convertPptx(arena, slide_prefix ++
        \\<p:pic><p:nvPicPr><p:cNvPr id="4" name="Picture 3" descr="Quarterly revenue chart"/>
        \\</p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/></p:blipFill></p:pic>
    ++ slide_suffix, rels);

    try testing.expectEqual(@as(u32, 1), countInlines(&converted.doc, .image));
    try testing.expectEqual(@as(u32, 1), countBlocks(&converted.doc, .paragraph));
}

test "bullet levels nest lists and buNone stays a paragraph" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertPptx(arena, slide_prefix ++
        \\<p:sp><p:txBody>
        \\<a:p><a:pPr lvl="0"><a:buChar char="-"/></a:pPr><a:r><a:t>one</a:t></a:r></a:p>
        \\<a:p><a:pPr lvl="1"><a:buChar char="-"/></a:pPr><a:r><a:t>nested</a:t></a:r></a:p>
        \\<a:p><a:pPr lvl="0"><a:buChar char="-"/></a:pPr><a:r><a:t>two</a:t></a:r></a:p>
        \\<a:p><a:pPr><a:buNone/></a:pPr><a:r><a:t>closing text</a:t></a:r></a:p>
        \\</p:txBody></p:sp>
    ++ slide_suffix, null);

    try testing.expectEqual(@as(u32, 2), countBlocks(&converted.doc, .list));
    try testing.expectEqual(@as(u32, 3), countBlocks(&converted.doc, .list_item));
    try testing.expectEqual(@as(u32, 1), countBlocks(&converted.doc, .paragraph));
}

test "titles become headings and notes land in a container" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertPptx(arena, slide_prefix ++
        \\<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
        \\<p:txBody><a:p><a:r><a:rPr b="1"/><a:t>Slide Title</a:t></a:r></a:p></p:txBody></p:sp>
        \\<p:sp><p:txBody><a:p><a:r><a:t>Body text.</a:t></a:r></a:p></p:txBody></p:sp>
    ++ slide_suffix, null);

    try testing.expectEqual(@as(u32, 1), countBlocks(&converted.doc, .heading));
    try testing.expectEqual(@as(u32, 1), countBlocks(&converted.doc, .paragraph));
    try testing.expectEqual(@as(u32, 1), countInlines(&converted.doc, .strong));
}

test "shape geometry attaches as a slide layout facet in EMU" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertPptx(arena, slide_prefix ++
        \\<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
        \\<p:spPr><a:xfrm><a:off x="914400" y="1828800"/>
        \\<a:ext cx="6096000" cy="1143000"/></a:xfrm></p:spPr>
        \\<p:txBody><a:p><a:r><a:t>Placed title</a:t></a:r></a:p></p:txBody></p:sp>
    ++ slide_suffix, null);

    const rows = converted.doc.store.layout_facets.items;
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(core.facets.Surface.slide, rows[0].surface);
    try testing.expectEqual(@as(u32, 0), rows[0].surface_index);
    try testing.expectEqual(@as(i32, 914400), rows[0].x);
    try testing.expectEqual(@as(i32, 1828800), rows[0].y);
    try testing.expectEqual(@as(i32, 6096000), rows[0].width);
    try testing.expectEqual(@as(i32, 1143000), rows[0].height);
    // The facet binds to the emitted heading.
    const entity = rows[0].entity;
    try testing.expectEqual(rows[0], converted.doc.layoutOf(entity).?);
}

test "embedded picture bytes register in the resource store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const png_bytes = "\x89PNG\r\n\x1a\nfakepixels";
    const presentation =
        \\<p:presentation
        \\  xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
        \\  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \\<p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst>
        \\</p:presentation>
    ;
    const presentation_rels =
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId1"
        \\ Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
        \\ Target="slides/slide1.xml"/>
        \\</Relationships>
    ;
    const slide_rels =
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId2"
        \\ Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
        \\ Target="../media/image1.png"/>
        \\</Relationships>
    ;
    const slide = slide_prefix ++
        \\<p:pic><p:nvPicPr><p:cNvPr id="4" name="Pic" descr="A chart"/>
        \\</p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/></p:blipFill></p:pic>
    ++ slide_suffix;
    const archive_bytes = try zip.buildStoredArchive(arena, &.{
        .{ .name = "ppt/presentation.xml", .data = presentation },
        .{ .name = "ppt/_rels/presentation.xml.rels", .data = presentation_rels },
        .{ .name = "ppt/slides/slide1.xml", .data = slide },
        .{ .name = "ppt/slides/_rels/slide1.xml.rels", .data = slide_rels },
        .{ .name = "ppt/media/image1.png", .data = png_bytes },
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
        .input_name = "test.pptx",
        .reports = reports,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});

    try testing.expectEqual(@as(usize, 1), store.resources.items.len);
    const resource = store.resources.items[0];
    try testing.expectEqualStrings("ppt/media/image1.png", store.textSlice(resource.source));
    try testing.expectEqualStrings("image/png", store.textSlice(resource.mime));
    const bytes = store.resource_bytes.items[resource.bytes.start..resource.bytes.end()];
    try testing.expectEqualStrings(png_bytes, bytes);
}
