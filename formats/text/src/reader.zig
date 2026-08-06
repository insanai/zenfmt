//! The plain-text reader (ZDS 0002, The other formats).
//!
//! Blank-line-separated blocks become paragraphs; line endings are
//! normalized; lines within a paragraph become soft breaks. The phase 1
//! plugin, which exists to exercise the pipeline end to end.

const std = @import("std");
const core = @import("zenfmt_core");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.text",
    .format = "text",
    .extensions = &.{ "txt", "text" },
    .read = read,
});

fn read(ctx: *core.ReadContext) core.ReadError!void {
    const bytes = ctx.input.bytes;
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        try ctx.reports.add(invalidUtf8Report(bytes));
        return error.Malformed;
    }

    var open: ?core.builder.BlockToken = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const blank = std.mem.indexOfNone(u8, line, " \t") == null;
        if (blank) {
            if (open) |token| ctx.out.endBlock(token);
            open = null;
            continue;
        }
        if (open == null) {
            open = try ctx.out.beginParagraph();
        } else {
            try ctx.out.softBreak();
        }
        try ctx.out.text(line);
    }
    if (open) |token| ctx.out.endBlock(token);
}

fn invalidUtf8Report(bytes: []const u8) core.Report {
    _ = bytes;
    return .{
        .severity = .err,
        .code = "text.invalid-utf8",
        .title = "THE INPUT IS NOT VALID UTF-8",
        .problem = "This file contains bytes that are not valid UTF-8, so " ++
            "I cannot treat it as plain text. It may be in a legacy " ++
            "encoding such as Latin-1 or Windows-1252, or it may not be a " ++
            "text file at all.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Convert the encoding first",
            .explanation = "If the file is text in a legacy encoding, " ++
                "convert it to UTF-8 first — for example with " ++
                "`iconv -f windows-1252 -t utf-8` — and run zenfmt on the " ++
                "result. If it is not text, select its actual format with " ++
                "--from.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "paragraphs split on blank lines and lines soft-break" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: core.ast.Store = .{};
    var b = core.builder.Builder.init(arena, &store, .{});
    var reports = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = "one line\ntwo line\r\n\n\t \nsecond para\n" },
        .input_name = "test.txt",
        .reports = &reports,
        .manifest_in = null,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});

    try testing.expectEqual(@as(u32, 2), doc.body.len);
    const tags = store.blocks.items(.tag);
    try testing.expectEqual(core.BlockTag.paragraph, tags[0]);
    try testing.expectEqual(core.BlockTag.paragraph, tags[1]);
    // "one line" + soft break + "two line" = 2+1+2+1+2 = 7 inlines, then
    // "second para" = 3 more.
    const first = doc.blockAs(@enumFromInt(0), .paragraph).?;
    try testing.expectEqual(@as(u32, 7), first.len);
}

test "invalid utf-8 is refused with a report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store: core.ast.Store = .{};
    var b = core.builder.Builder.init(arena, &store, .{});
    var reports = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = "ok\n\xff\xfe bad" },
        .input_name = "bad.txt",
        .reports = &reports,
        .manifest_in = null,
        .limits = .{},
    };
    try testing.expectError(error.Malformed, read(&ctx));
    try testing.expect(reports.hasErrors());
}
