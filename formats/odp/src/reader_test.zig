//! Unit tests for the ODP reader, split out of `reader.zig` (file-size
//! rule). The helpers drive `read` directly and validate every tree.

const std = @import("std");
const core = @import("zenfmt_core");
const ooxml = @import("zenfmt_ooxml");
const reader_mod = @import("reader.zig");
const read = reader_mod.read;

const testing = std.testing;
const zip = ooxml.zip;

const ConvertResult = struct {
    doc: core.ast.Document,
    reports: *core.Reports,
};

fn convertOdp(arena: std.mem.Allocator, content: []const u8) !ConvertResult {
    const archive_bytes = try zip.buildStoredArchive(arena, &.{
        .{ .name = "mimetype", .data = "application/vnd.oasis.opendocument.presentation" },
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
        .input_name = "test.odp",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return .{ .doc = doc, .reports = reports };
}

const content_prefix =
    \\<office:document-content
    \\  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    \\  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    \\  xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
    \\  xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
    \\  xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
    \\  xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"
    \\  xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    \\  xmlns:xlink="http://www.w3.org/1999/xlink">
;

fn allText(arena: std.mem.Allocator, doc: *const core.ast.Document) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    const tags = doc.store.inlines.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag == .space) {
            try buffer.append(arena, ' ');
        } else if (tag == .text) {
            const view = doc.inlineView(@enumFromInt(i));
            try buffer.appendSlice(arena, doc.text(view.content.text));
        }
    }
    return buffer.items;
}

test "title frame becomes the slide heading, body follows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOdp(arena, content_prefix ++
        \\<office:automatic-styles>
        \\<style:style style:name="T1" style:family="text">
        \\<style:text-properties fo:font-weight="bold"/></style:style>
        \\</office:automatic-styles>
        \\<office:body><office:presentation>
        \\<draw:page draw:name="page1">
        \\<draw:frame presentation:class="title"><draw:text-box>
        \\<text:p>Agenda</text:p></draw:text-box></draw:frame>
        \\<draw:frame presentation:class="outline"><draw:text-box>
        \\<text:p>Plain <text:span text:style-name="T1">bold</text:span></text:p>
        \\</draw:text-box></draw:frame>
        \\</draw:page>
        \\</office:presentation></office:body></office:document-content>
    );

    const text = try allText(arena, &result.doc);
    try testing.expectEqualStrings("AgendaPlain bold", text);

    var headings: u32 = 0;
    for (result.doc.store.blocks.items(.tag)) |tag| {
        if (tag == .heading) headings += 1;
    }
    try testing.expectEqual(@as(u32, 1), headings);

    var strongs: u32 = 0;
    for (result.doc.store.inlines.items(.tag)) |tag| {
        if (tag == .strong) strongs += 1;
    }
    try testing.expectEqual(@as(u32, 1), strongs);

    var projected = false;
    for (try result.reports.finalize()) |report| {
        if (std.mem.eql(u8, report.code, "odp.presentation-projection")) projected = true;
    }
    try testing.expect(projected);
}

test "notes land in a container and titleless slides use the page name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOdp(arena, content_prefix ++
        \\<office:body><office:presentation>
        \\<draw:page draw:name="Overview">
        \\<draw:frame presentation:class="outline"><draw:text-box>
        \\<text:p>Body text.</text:p></draw:text-box></draw:frame>
        \\<presentation:notes><draw:frame presentation:class="notes">
        \\<draw:text-box><text:p>Remember this.</text:p></draw:text-box>
        \\</draw:frame></presentation:notes>
        \\</draw:page>
        \\</office:presentation></office:body></office:document-content>
    );

    const text = try allText(arena, &result.doc);
    try testing.expectEqualStrings("OverviewBody text.Remember this.", text);

    var containers: u32 = 0;
    for (result.doc.store.blocks.items(.tag)) |tag| {
        if (tag == .container) containers += 1;
    }
    try testing.expectEqual(@as(u32, 1), containers);
}

test "slide tables emit rows and cells, headerless by default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOdp(arena, content_prefix ++
        \\<office:body><office:presentation>
        \\<draw:page draw:name="page1">
        \\<draw:frame><table:table>
        \\<table:table-row>
        \\<table:table-cell><text:p>a</text:p></table:table-cell>
        \\<table:table-cell><text:p>b</text:p></table:table-cell>
        \\</table:table-row>
        \\<table:table-row>
        \\<table:table-cell><text:p>c</text:p></table:table-cell>
        \\<table:table-cell><text:p>d</text:p></table:table-cell>
        \\</table:table-row>
        \\</table:table></draw:frame>
        \\</draw:page>
        \\</office:presentation></office:body></office:document-content>
    );

    const text = try allText(arena, &result.doc);
    try testing.expectEqualStrings("page1abcd", text);

    var tables: u32 = 0;
    var heads: u32 = 0;
    var bodies: u32 = 0;
    var rows: u32 = 0;
    var cells: u32 = 0;
    for (result.doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .table => tables += 1,
        .table_head => heads += 1,
        .table_body => bodies += 1,
        .table_row => rows += 1,
        .table_cell => cells += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), tables);
    // Presentations have no header semantics: every row is body.
    try testing.expectEqual(@as(u32, 0), heads);
    try testing.expectEqual(@as(u32, 1), bodies);
    try testing.expectEqual(@as(u32, 2), rows);
    try testing.expectEqual(@as(u32, 4), cells);
}

test "self-closing empty cells still occupy the grid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOdp(arena, content_prefix ++
        \\<office:body><office:presentation>
        \\<draw:page draw:name="page1">
        \\<draw:frame><table:table>
        \\<table:table-row><table:table-cell/><table:table-cell/></table:table-row>
        \\<table:table-row><table:table-cell/><table:table-cell/></table:table-row>
        \\</table:table></draw:frame>
        \\</draw:page>
        \\</office:presentation></office:body></office:document-content>
    );

    var rows: u32 = 0;
    var cells: u32 = 0;
    for (result.doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .table_row => rows += 1,
        .table_cell => cells += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 2), rows);
    try testing.expectEqual(@as(u32, 4), cells);
}

test "declared header rows map to table_head, covered cells fold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOdp(arena, content_prefix ++
        \\<office:body><office:presentation>
        \\<draw:page draw:name="page1">
        \\<draw:frame><table:table>
        \\<table:table-header-rows><table:table-row>
        \\<table:table-cell><text:p>h1</text:p></table:table-cell>
        \\<table:table-cell><text:p>h2</text:p></table:table-cell>
        \\</table:table-row></table:table-header-rows>
        \\<table:table-row>
        \\<table:table-cell table:number-columns-spanned="2"><text:p>wide</text:p></table:table-cell>
        \\<table:covered-table-cell/>
        \\</table:table-row>
        \\</table:table></draw:frame>
        \\</draw:page>
        \\</office:presentation></office:body></office:document-content>
    );

    const text = try allText(arena, &result.doc);
    try testing.expectEqualStrings("page1h1h2wide", text);

    var heads: u32 = 0;
    var cells: u32 = 0;
    for (result.doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .table_head => heads += 1,
        .table_cell => cells += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), heads);
    try testing.expectEqual(@as(u32, 3), cells);
}

test "lists inside slides keep their structure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try convertOdp(arena, content_prefix ++
        \\<office:body><office:presentation>
        \\<draw:page draw:name="Items">
        \\<draw:frame presentation:class="outline"><draw:text-box>
        \\<text:list><text:list-item><text:p>one</text:p></text:list-item>
        \\<text:list-item><text:p>two</text:p></text:list-item></text:list>
        \\</draw:text-box></draw:frame>
        \\</draw:page>
        \\</office:presentation></office:body></office:document-content>
    );

    var lists: u32 = 0;
    var items: u32 = 0;
    for (result.doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .list => lists += 1,
        .list_item => items += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), lists);
    try testing.expectEqual(@as(u32, 2), items);
}
