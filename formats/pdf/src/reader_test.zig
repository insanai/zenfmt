//! End-to-end PDF reader tests (ZDS: pdf-reader): built PDFs in, AST out,
//! every refusal asserted by its report code.

const std = @import("std");
const testing = std.testing;
const core = @import("zenfmt_core");
const testpdf = @import("testpdf.zig");
const reader_mod = @import("reader.zig");

const Converted = struct {
    doc: core.ast.Document,
    reports: *core.Reports,
};

fn convertPdf(arena: std.mem.Allocator, bytes: []const u8) !Converted {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "test.pdf",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try reader_mod.reader.read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return .{ .doc = doc, .reports = reports };
}

fn expectReport(reports: *core.Reports, code: []const u8) !void {
    const list = try reports.finalize();
    for (list) |report| {
        if (std.mem.eql(u8, report.code, code)) return;
    }
    std.debug.print("missing report {s}; got:\n", .{code});
    for (list) |report| std.debug.print("  {s}\n", .{report.code});
    return error.TestExpectedReport;
}

fn documentText(doc: core.ast.Document) []const u8 {
    return doc.store.text.items;
}

fn countBlocks(doc: core.ast.Document, tag: core.BlockTag) u32 {
    var count: u32 = 0;
    for (doc.store.blocks.items(.tag)) |candidate| {
        if (candidate == tag) count += 1;
    }
    return count;
}

test "single page text extracts into a paragraph" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try testpdf.singlePage(
        arena,
        "BT /F1 12 Tf 72 720 Td (Hello PDF world.) Tj ET",
        "",
    );
    const result = try convertPdf(arena, bytes);
    try testing.expectEqual(@as(u32, 1), countBlocks(result.doc, .paragraph));
    try testing.expect(std.mem.indexOf(u8, documentText(result.doc), "world.") != null);
}

test "font size tiers become headings; gaps split paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const content =
        "BT /F1 24 Tf 72 720 Td (Big Title) Tj ET " ++
        "BT /F1 12 Tf 72 690 Td (First paragraph line one.) Tj " ++
        "0 -14 Td (Line two of the same paragraph.) Tj " ++
        "0 -40 Td (Second paragraph after a gap.) Tj ET";
    const bytes = try testpdf.singlePage(arena, content, "");
    const result = try convertPdf(arena, bytes);
    try testing.expectEqual(@as(u32, 1), countBlocks(result.doc, .heading));
    try testing.expectEqual(@as(u32, 2), countBlocks(result.doc, .paragraph));
    const text = documentText(result.doc);
    try testing.expect(std.mem.indexOf(u8, text, "Title") != null);
}

test "flate-compressed content streams decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = "BT /F1 12 Tf 72 720 Td (Compressed content survives.) Tj ET";
    const compressed_buffer = try arena.alloc(u8, 4096);
    var fixed = std.Io.Writer.fixed(compressed_buffer);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var compress = try std.compress.flate.Compress.init(
        &fixed,
        window,
        .zlib,
        std.compress.flate.Compress.Options.best,
    );
    try compress.writer.writeAll(plain);
    try compress.finish();

    var b = testpdf.Builder.init(arena);
    _ = try b.add("<< /Type /Catalog /Pages 2 0 R >>");
    _ = try b.add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
    _ = try b.add("<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>");
    _ = try b.addStream("/Filter /FlateDecode", fixed.buffered());
    const bytes = try b.finish(1);

    const result = try convertPdf(arena, bytes);
    try testing.expect(std.mem.indexOf(
        u8,
        documentText(result.doc),
        "survives.",
    ) != null);
}

test "encrypted pdf refuses with its code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = testpdf.Builder.init(arena);
    _ = try b.add("<< /Type /Catalog /Pages 2 0 R >>");
    _ = try b.add("<< /Type /Pages /Kids [] /Count 0 >>");
    _ = try b.add("<< /Filter /Standard /V 1 /R 2 >>");
    b.extra_trailer = "/Encrypt 3 0 R";
    const bytes = try b.finish(1);

    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var builder = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &builder },
        .input = .{ .bytes = bytes },
        .input_name = "secret.pdf",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try testing.expectError(error.Malformed, reader_mod.reader.read(&ctx));
    try expectReport(reports, "pdf.encryption-refused");
}

test "not a pdf refuses with its code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var builder = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &builder },
        .input = .{ .bytes = "not a pdf at all" },
        .input_name = "nope.pdf",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try testing.expectError(error.Malformed, reader_mod.reader.read(&ctx));
    try expectReport(reports, "pdf.not-pdf");
}

test "a jpeg xobject extracts as-is into the media table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = testpdf.Builder.init(arena);
    _ = try b.add("<< /Type /Catalog /Pages 2 0 R >>");
    _ = try b.add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
    _ = try b.add("<< /Type /Page /Parent 2 0 R /Contents 4 0 R " ++
        "/Resources << /XObject << /Im1 5 0 R >> >> >>");
    // The image is drawn twice; it registers once.
    _ = try b.addStream("", "BT /F1 12 Tf 72 720 Td (text) Tj ET /Im1 Do /Im1 Do");
    _ = try b.addStream("/Subtype /Image /Filter /DCTDecode /Width 1 /Height 1", "\xff\xd8");
    const bytes = try b.finish(1);

    const result = try convertPdf(arena, bytes);
    const store = result.doc.store;
    try testing.expectEqual(@as(usize, 1), store.resources.items.len);
    const entry = store.resources.items[0];
    try testing.expectEqualStrings("pdf-image-1", store.textSlice(entry.source));
    try testing.expectEqualStrings("image/jpeg", store.textSlice(entry.mime));
    try testing.expectEqualStrings(
        "\xff\xd8",
        store.resource_bytes.items[entry.bytes.start..][0..entry.bytes.len],
    );
    // Both drawings appear in the flow.
    var image_inlines: u32 = 0;
    for (store.inlines.items(.tag)) |tag| {
        if (tag == .image) image_inlines += 1;
    }
    try testing.expectEqual(@as(u32, 2), image_inlines);
}

test "an image encoding zenfmt does not decode stays omitted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = testpdf.Builder.init(arena);
    _ = try b.add("<< /Type /Catalog /Pages 2 0 R >>");
    _ = try b.add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
    _ = try b.add("<< /Type /Page /Parent 2 0 R /Contents 4 0 R " ++
        "/Resources << /XObject << /Im1 5 0 R >> >> >>");
    _ = try b.addStream("", "BT /F1 12 Tf 72 720 Td (text) Tj ET /Im1 Do");
    _ = try b.addStream(
        "/Subtype /Image /Filter /CCITTFaxDecode /Width 1 /Height 1",
        "\x00",
    );
    const bytes = try b.finish(1);

    const result = try convertPdf(arena, bytes);
    try testing.expectEqual(@as(usize, 0), result.doc.store.resources.items.len);
    try expectReport(result.reports, "pdf.images-omitted");
}

test "a painted lattice reconstructs as a table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const content =
        "100 700 m 300 700 l S 100 650 m 300 650 l S 100 600 m 300 600 l S " ++
        "100 700 m 100 600 l S 200 700 m 200 600 l S 300 700 m 300 600 l S " ++
        "BT /F1 10 Tf 72 750 Td (Intro line) Tj ET " ++
        "BT /F1 10 Tf 110 660 Td (A) Tj 100 0 Td (B) Tj " ++
        "-100 -50 Td (C) Tj 100 0 Td (D) Tj ET";
    const bytes = try testpdf.singlePage(arena, content, "");

    const result = try convertPdf(arena, bytes);
    try testing.expectEqual(@as(u32, 1), countBlocks(result.doc, .table));
    try testing.expectEqual(@as(u32, 2), countBlocks(result.doc, .table_row));
    try testing.expectEqual(@as(u32, 4), countBlocks(result.doc, .table_cell));
    // The intro paragraph precedes the table in the flow.
    const tags = result.doc.store.blocks.items(.tag);
    const paragraph_at = std.mem.indexOfScalar(core.BlockTag, tags, .paragraph).?;
    const table_at = std.mem.indexOfScalar(core.BlockTag, tags, .table).?;
    try testing.expect(paragraph_at < table_at);
    try testing.expect(std.mem.indexOf(u8, documentText(result.doc), "A") != null);
    try testing.expect(std.mem.indexOf(u8, documentText(result.doc), "D") != null);
}

/// Page resources with a widths-carrying `/F1`, so pen gaps split
/// fragments the way real produced PDFs do.
const mono_font_page =
    "/Resources << /Font << /F1 << /Type /Font /Subtype /Type1 " ++
    "/BaseFont /Courier /FirstChar 32 /Widths [" ++ ("500 " ** 96) ++ "] >> >> >>";

test "aligned whitespace columns over three rows become a table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const content =
        "BT /F1 10 Tf 72 700 Td (Name) Tj 128 0 Td (Qty) Tj " ++
        "-128 -15 Td (Apples) Tj 128 0 Td (12) Tj " ++
        "-128 -15 Td (Pears) Tj 128 0 Td (7) Tj ET";
    const bytes = try testpdf.singlePage(arena, content, mono_font_page);

    const result = try convertPdf(arena, bytes);
    try testing.expectEqual(@as(u32, 1), countBlocks(result.doc, .table));
    try testing.expectEqual(@as(u32, 3), countBlocks(result.doc, .table_row));
    try testing.expectEqual(@as(u32, 6), countBlocks(result.doc, .table_cell));
}

test "prose with scattered fragments stays paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Three lines, two fragments each, but the second column drifts:
    // no shared lattice, no table.
    const content =
        "BT /F1 10 Tf 72 700 Td (one) Tj 78 0 Td (fragment) Tj " ++
        "-78 -15 Td (two) Tj 128 0 Td (drifted) Tj " ++
        "-128 -15 Td (three) Tj 178 0 Td (further) Tj ET";
    const bytes = try testpdf.singlePage(arena, content, mono_font_page);

    const result = try convertPdf(arena, bytes);
    try testing.expectEqual(@as(u32, 0), countBlocks(result.doc, .table));
}

test "xref stream and object stream documents load" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Objects 1 (catalog), 2 (pages), 3 (page) live inside object stream
    // 5; object 4 is the content stream; object 6 is the xref stream.
    const inner =
        "<< /Type /Catalog /Pages 2 0 R >>" ++
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>" ++
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>";
    const first_off = 0;
    const second_off = "<< /Type /Catalog /Pages 2 0 R >>".len;
    const third_off = second_off + "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".len;
    const header = try std.fmt.allocPrint(
        arena,
        "1 {d} 2 {d} 3 {d}\n",
        .{ first_off, second_off, third_off },
    );
    const objstm_payload = try std.mem.concat(arena, u8, &.{ header, inner });

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "%PDF-1.6\n");
    // Object 4: the content stream.
    const content = "BT /F1 12 Tf 72 720 Td (From an object stream.) Tj ET";
    const obj4_at = out.items.len;
    try out.print(
        arena,
        "4 0 obj\n<< /Length {d} >>\nstream\n{s}\nendstream\nendobj\n",
        .{ content.len, content },
    );
    // Object 5: the object stream.
    const obj5_at = out.items.len;
    try out.print(
        arena,
        "5 0 obj\n<< /Type /ObjStm /N 3 /First {d} /Length {d} >>\nstream\n{s}\nendstream\nendobj\n",
        .{ header.len, objstm_payload.len, objstm_payload },
    );
    // Object 6: the cross-reference stream (W [1 4 2], entries 0..6).
    const obj6_at = out.items.len;
    var rows: std.ArrayList(u8) = .empty;
    const fixed_entries = [_][3]u32{
        .{ 0, 0, 0xffff },
        .{ 2, 5, 0 },
        .{ 2, 5, 1 },
        .{ 2, 5, 2 },
        .{ 1, @intCast(obj4_at), 0 },
        .{ 1, @intCast(obj5_at), 0 },
        .{ 1, @intCast(obj6_at), 0 },
    };
    for (fixed_entries) |entry| {
        try rows.append(arena, @intCast(entry[0]));
        try rows.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, entry[1])));
        try rows.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(entry[2]))));
    }
    try out.print(
        arena,
        "6 0 obj\n<< /Type /XRef /Size 7 /W [1 4 2] /Root 1 0 R /Length {d} >>\nstream\n",
        .{rows.items.len},
    );
    try out.appendSlice(arena, rows.items);
    try out.appendSlice(arena, "\nendstream\nendobj\n");
    try out.print(arena, "startxref\n{d}\n%%EOF\n", .{obj6_at});

    const result = try convertPdf(arena, out.items);
    try testing.expect(std.mem.indexOf(u8, documentText(result.doc), "object") != null);
    try testing.expect(std.mem.indexOf(u8, documentText(result.doc), "stream.") != null);
}

test "projected blocks carry provenance and top-left layout facets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = testpdf.Builder.init(arena);
    _ = try b.add("<< /Type /Catalog /Pages 2 0 R >>");
    _ = try b.add("<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>");
    _ = try b.add("<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>");
    _ = try b.addStream("", "BT /F1 12 Tf 72 720 Td (Placed text) Tj ET");
    const bytes = try b.finish(1);

    const result = try convertPdf(arena, bytes);
    const store = result.doc.store;

    try testing.expectEqual(@as(usize, 1), store.provenance_facets.items.len);
    const provenance = store.provenance_facets.items[0];
    try testing.expectEqualStrings("page-1", store.textSlice(provenance.member));
    try testing.expectEqualStrings("ai.insan.zenfmt.pdf", store.textSlice(provenance.plugin));
    try testing.expectEqual(core.facets.Confidence.projected, provenance.confidence);

    try testing.expectEqual(@as(usize, 1), store.layout_facets.items.len);
    const layout = store.layout_facets.items[0];
    try testing.expectEqual(core.facets.Surface.page, layout.surface);
    try testing.expectEqual(@as(u32, 0), layout.surface_index);
    // x: 72 pt; y: (792 - 720 - 12) pt from the top; height: 12 pt.
    try testing.expectEqual(@as(i32, 72 * 12700), layout.x);
    try testing.expectEqual(@as(i32, 60 * 12700), layout.y);
    try testing.expectEqual(@as(i32, 0), layout.width);
    try testing.expectEqual(@as(i32, 12 * 12700), layout.height);

    // Both facets bind to the same paragraph entity.
    try testing.expectEqual(provenance.entity, layout.entity);
}
