//! RTF reader tests: character state, structure synthesis, fields, notes.

const std = @import("std");
const testing = std.testing;
const core = @import("zenfmt_core");
const reader_mod = @import("reader.zig");

const Converted = struct {
    doc: core.ast.Document,
    reports: *core.Reports,
};

fn convertRtf(arena: std.mem.Allocator, bytes: []const u8) !Converted {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "test.rtf",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try reader_mod.read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return .{ .doc = doc, .reports = reports };
}

fn hasReport(reports: *core.Reports, code: []const u8) bool {
    for (reports.entries.items) |entry| {
        if (std.mem.eql(u8, entry.report.code, code)) return true;
    }
    return false;
}

fn countTag(doc: core.ast.Document, tag: core.BlockTag) u32 {
    var count: u32 = 0;
    for (doc.store.blocks.items(.tag)) |candidate| {
        if (candidate == tag) count += 1;
    }
    return count;
}

fn countInlineTag(doc: core.ast.Document, tag: core.InlineTag) u32 {
    var count: u32 = 0;
    for (doc.store.inlines.items(.tag)) |candidate| {
        if (candidate == tag) count += 1;
    }
    return count;
}

test "paragraphs, toggles, and inheritance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1\\ansi Plain {\\b bold {\\i both}} back\\par Second\\par}");
    try testing.expectEqual(@as(u32, 2), countTag(converted.doc, .paragraph));
    try testing.expectEqual(@as(u32, 1), countInlineTag(converted.doc, .strong));
    try testing.expectEqual(@as(u32, 1), countInlineTag(converted.doc, .emphasis));
}

test "hex and unicode escapes decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1 caf\\'e9 and \\u8212? dash\\par}");
    const text = converted.doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "café") != null);
    try testing.expect(std.mem.indexOf(u8, text, "—") != null);
}

test "destinations and the font table never reach the output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1{\\fonttbl{\\f0 Calibri;}}{\\*\\generator Riched20;}Visible\\par}");
    const text = converted.doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "Calibri") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Riched20") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Visible") != null);
}

test "a two-by-two table becomes rows and cells" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1\\trowd\\cellx1000\\cellx2000 " ++
        "\\pard\\intbl A\\cell \\pard\\intbl B\\cell\\row " ++
        "\\trowd\\cellx1000\\cellx2000 " ++
        "\\pard\\intbl C\\cell \\pard\\intbl D\\cell\\row " ++
        "\\pard After\\par}");
    try testing.expectEqual(@as(u32, 1), countTag(converted.doc, .table));
    try testing.expectEqual(@as(u32, 1), countTag(converted.doc, .table_body));
    try testing.expectEqual(@as(u32, 2), countTag(converted.doc, .table_row));
    try testing.expectEqual(@as(u32, 4), countTag(converted.doc, .table_cell));
    // Four cell paragraphs plus the trailing one.
    try testing.expectEqual(@as(u32, 5), countTag(converted.doc, .paragraph));
    const text = converted.doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "After") != null);
}

test "a header row goes under table_head" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1\\trowd\\trhdr\\cellx1000\\cellx2000 " ++
        "\\pard\\intbl Name\\cell \\pard\\intbl Value\\cell\\row " ++
        "\\trowd\\cellx1000\\cellx2000 " ++
        "\\pard\\intbl a\\cell \\pard\\intbl 1\\cell\\row \\pard\\par}");
    try testing.expectEqual(@as(u32, 1), countTag(converted.doc, .table_head));
    try testing.expectEqual(@as(u32, 1), countTag(converted.doc, .table_body));
    try testing.expectEqual(@as(u32, 2), countTag(converted.doc, .table_row));
}

test "list items with rising and falling levels nest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1\\pard{\\listtext \\'b7\\tab}\\ls1\\ilvl0 One\\par " ++
        "\\pard{\\listtext \\'b7\\tab}\\ls1\\ilvl1 Sub\\par " ++
        "\\pard{\\listtext \\'b7\\tab}\\ls1\\ilvl0 Two\\par " ++
        "\\pard Done\\par}");
    try testing.expectEqual(@as(u32, 2), countTag(converted.doc, .list));
    try testing.expectEqual(@as(u32, 3), countTag(converted.doc, .list_item));
    const text = converted.doc.store.text.items;
    // The marker fallback never reaches the output.
    try testing.expect(std.mem.indexOf(u8, text, "·") == null);
}

test "digit markers make an ordered list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1\\pard{\\listtext 1.\\tab}\\ls2\\ilvl0 First\\par " ++
        "\\pard{\\listtext 2.\\tab}\\ls2\\ilvl0 Second\\par \\pard\\par}");
    try testing.expectEqual(@as(u32, 1), countTag(converted.doc, .list));
    try testing.expectEqual(@as(u32, 2), countTag(converted.doc, .list_item));
    try testing.expectEqual(core.payload.ListKind.ordered, converted.doc.store.lists.items[0].kind);
}

test "old-style pn numbering makes an ordered list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1\\pard{\\*\\pn\\pnlvlbody\\pndec\\pnstart1}First\\par " ++
        "\\pard{\\*\\pn\\pnlvlbody\\pndec\\pnstart1}Second\\par \\pard\\par}");
    try testing.expectEqual(@as(u32, 1), countTag(converted.doc, .list));
    try testing.expectEqual(@as(u32, 2), countTag(converted.doc, .list_item));
    try testing.expectEqual(core.payload.ListKind.ordered, converted.doc.store.lists.items[0].kind);
}

test "hyperlink fields become links with display text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1 See {\\field{\\*\\fldinst HYPERLINK \"https://ziglang.org\"}" ++
        "{\\fldrslt the site}} now\\par}");
    try testing.expectEqual(@as(u32, 1), countInlineTag(converted.doc, .link));
    const text = converted.doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "https://ziglang.org") != null);
    // The pool stores words; spaces are structural `space` nodes.
    try testing.expect(std.mem.indexOf(u8, text, "site") != null);
    try testing.expect(std.mem.indexOf(u8, text, "HYPERLINK") == null);
}

test "footnotes reference at the site and carry their body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1 A claim{\\footnote \\pard The evidence.\\par} stands\\par}");
    try testing.expectEqual(@as(u32, 1), countInlineTag(converted.doc, .note));
    try testing.expectEqual(@as(usize, 1), converted.doc.store.block_ranges.items.len);
    const text = converted.doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "evidence.") != null);
    // The note body is a paragraph outside the document body.
    try testing.expectEqual(@as(u32, 2), countTag(converted.doc, .paragraph));
}

test "outline levels become headings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1\\pard\\outlinelevel0 Title\\par \\pard\\outlinelevel1 Section\\par " ++
        "\\pard Body text\\par}");
    try testing.expectEqual(@as(u32, 2), countTag(converted.doc, .heading));
    try testing.expectEqual(@as(u32, 1), countTag(converted.doc, .paragraph));
    try testing.expectEqual(@as(u8, 1), converted.doc.store.headings.items[0].level);
    try testing.expectEqual(@as(u8, 2), converted.doc.store.headings.items[1].level);
}

test "images and objects are reported, not silently dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(arena, "{\\rtf1 Before {\\pict\\pngblip 89504e47} after " ++
        "{\\object\\objemb 0102}\\par}");
    try testing.expect(hasReport(converted.reports, "rtf.images-dropped"));
    try testing.expect(hasReport(converted.reports, "rtf.objects-dropped"));
    const text = converted.doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "89504e47") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Before") != null);
}

test "stylesheet names become style facets on styled paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(
        arena,
        "{\\rtf1\\ansi{\\stylesheet{\\s0 Normal;}{\\s1\\b\\fs32 Heading 1;}" ++
            "{\\*\\cs16 Hyperlink;}}" ++
            "\\pard\\s1 Title text\\par" ++
            "\\pard Plain body\\par}",
    );
    const store = converted.doc.store;

    // Exactly the styled paragraph carries a facet; the plain one is free.
    try testing.expectEqual(@as(usize, 1), store.style_facets.items.len);
    const facet = store.style_facets.items[0];
    try testing.expectEqualStrings("Heading 1", store.textSlice(facet.name));

    const styled_block = store.block_entities.items[converted.doc.block_entities.start].node;
    try testing.expectEqual(core.BlockTag.paragraph, store.blocks.items(.tag)[styled_block]);
}

test "a missing stylesheet attaches no style facets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertRtf(
        arena,
        "{\\rtf1\\ansi\\pard\\s7 Unmapped style\\par}",
    );
    try testing.expectEqual(@as(usize, 0), converted.doc.store.style_facets.items.len);
    const text = converted.doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "Unmapped") != null);
}
