//! Golden tests for the Markdown writer: exact output strings, because a
//! writer's output is its contract.

const std = @import("std");
const core = @import("zenfmt_core");
const ast = core.ast;
const write = @import("writer.zig").write;

const testing = std.testing;

const TestSetup = struct {
    arena: std.mem.Allocator,
    store: *ast.Store,
    builder: core.builder.Builder,
    reports: core.Reports,

    fn init(arena: std.mem.Allocator) !TestSetup {
        const store = try arena.create(ast.Store);
        store.* = .{};
        return .{
            .arena = arena,
            .store = store,
            .builder = core.builder.Builder.init(arena, store, .{}),
            .reports = core.Reports.init(arena, .{}),
        };
    }

    fn emitter(setup: *TestSetup) core.Emitter {
        return .{ .builder = &setup.builder };
    }

    fn render(setup: *TestSetup, buffer: []u8) ![]const u8 {
        const doc = try setup.builder.finish();
        try core.ast.validate(&doc, .{});
        var fixed = std.Io.Writer.fixed(buffer);
        var ctx: core.WriteContext = .{
            .gpa = setup.arena,
            .doc = &doc,
            .out = &fixed,
            .reports = &setup.reports,
            .limits = .{},
        };
        try write(&ctx);
        return fixed.buffered();
    }
};

test "paragraphs, emphasis, and links render with minimal escaping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var setup = try TestSetup.init(arena_state.allocator());
    const e = setup.emitter();

    {
        const h = try e.beginHeading(2);
        defer e.endBlock(h);
        try e.text("The ");
        const em = try e.beginInline(.emphasis);
        try e.text("quick");
        e.endInline(em);
        try e.text(" ");
        const link = try e.beginLink("http://x", "");
        try e.text("brown");
        e.endInline(link);
        try e.text(" fox");
    }
    {
        const p = try e.beginParagraph();
        defer e.endBlock(p);
        try e.text("Plain *stars* and 2 + 2.");
    }

    var buffer: [4096]u8 = undefined;
    const rendered = try setup.render(&buffer);
    try testing.expectEqualStrings(
        "## The _quick_ [brown](http://x) fox\n" ++
            "\n" ++
            "Plain \\*stars\\* and 2 + 2.\n",
        rendered,
    );
}

test "tight and loose lists nest with markers and indentation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var setup = try TestSetup.init(arena_state.allocator());
    const e = setup.emitter();

    const list = try e.beginList(.unordered);
    {
        const item = try e.beginBlock(.list_item);
        defer e.endBlock(item);
        const p = try e.beginPlain();
        try e.text("one");
        e.endBlock(p);
    }
    {
        const item = try e.beginBlock(.list_item);
        defer e.endBlock(item);
        {
            const p = try e.beginPlain();
            try e.text("two");
            e.endBlock(p);
        }
        const inner = try e.beginList(.{
            .kind = .ordered,
            .start = 3,
            .style = .decimal,
            .delimiter = .period,
        });
        {
            const inner_item = try e.beginBlock(.list_item);
            defer e.endBlock(inner_item);
            const p = try e.beginPlain();
            try e.text("three");
            e.endBlock(p);
        }
        e.endBlock(inner);
    }
    e.endBlock(list);

    var buffer: [4096]u8 = undefined;
    const rendered = try setup.render(&buffer);
    try testing.expectEqualStrings(
        "- one\n" ++
            "- two\n" ++
            "  3. three\n",
        rendered,
    );
}

test "quotes prefix every line including blanks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var setup = try TestSetup.init(arena_state.allocator());
    const e = setup.emitter();

    const quote = try e.beginBlock(.quote);
    {
        const p = try e.beginParagraph();
        defer e.endBlock(p);
        try e.text("first");
    }
    {
        const p = try e.beginParagraph();
        defer e.endBlock(p);
        try e.text("second");
    }
    e.endBlock(quote);

    var buffer: [4096]u8 = undefined;
    const rendered = try setup.render(&buffer);
    try testing.expectEqualStrings(
        "> first\n" ++
            ">\n" ++
            "> second\n",
        rendered,
    );
}

test "code blocks pick a fence longer than any run in the content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var setup = try TestSetup.init(arena_state.allocator());
    const e = setup.emitter();

    try e.codeBlock("zig", "const a = `tick`;\n```\nmore\n");

    var buffer: [4096]u8 = undefined;
    const rendered = try setup.render(&buffer);
    try testing.expectEqualStrings(
        "````zig\n" ++
            "const a = `tick`;\n" ++
            "```\n" ++
            "more\n" ++
            "````\n",
        rendered,
    );
}

test "tables render as GFM pipes with alignment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var setup = try TestSetup.init(arena_state.allocator());
    const e = setup.emitter();

    const table = try e.beginTable(&.{ .left, .right });
    {
        const head = try e.beginBlock(.table_head);
        defer e.endBlock(head);
        const row = try e.beginBlock(.table_row);
        defer e.endBlock(row);
        inline for (.{ "Name", "Count" }) |label| {
            const cell = try e.beginTableCell(.plain);
            const p = try e.beginPlain();
            try e.text(label);
            e.endBlock(p);
            e.endBlock(cell);
        }
    }
    {
        const body = try e.beginTableBody(.{ .row_head_columns = 0, .head_rows = 0 });
        defer e.endBlock(body);
        const row = try e.beginBlock(.table_row);
        defer e.endBlock(row);
        inline for (.{ "alpha", "3" }) |label| {
            const cell = try e.beginTableCell(.plain);
            const p = try e.beginPlain();
            try e.text(label);
            e.endBlock(p);
            e.endBlock(cell);
        }
    }
    e.endBlock(table);

    var buffer: [4096]u8 = undefined;
    const rendered = try setup.render(&buffer);
    try testing.expectEqualStrings(
        "| Name  | Count |\n" ++
            "| :---- | ----: |\n" ++
            "| alpha | 3     |\n",
        rendered,
    );
}
