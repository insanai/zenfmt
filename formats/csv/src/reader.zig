//! The CSV reader (ZDS 0002, The other formats).
//!
//! RFC 4180 with quoting, embedded newlines, and doubled quotes: one
//! quote-aware state machine, one `table` with the first row as
//! `table_head`. The final field of a file with no trailing newline is
//! preserved — the preliminary sketch's example reader lost it, and this
//! record exists partly to remember that.

const std = @import("std");
const core = @import("zenfmt_core");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.csv",
    .format = "csv",
    .extensions = &.{ "csv", "tsv" },
    .read = read,
});

const Separator = enum(u8) { comma = ',', tab = '\t' };

fn read(ctx: *core.ReadContext) core.ReadError!void {
    const bytes = ctx.input.bytes;
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        try ctx.reports.add(invalidUtf8Report());
        return error.Malformed;
    }
    if (bytes.len == 0) return;

    // TSV is the same machine with a different separator; the extension
    // decides, and a tab in the first record beats a comma-less guess.
    const separator: u8 = detectSeparator(ctx.input_name, bytes);

    var parser: Parser = .{ .ctx = ctx, .bytes = bytes, .separator = separator };
    try parser.run();
}

fn detectSeparator(name: []const u8, bytes: []const u8) u8 {
    if (std.mem.endsWith(u8, name, ".tsv")) return '\t';
    const first_line_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    const first_line = bytes[0..first_line_end];
    if (std.mem.indexOfScalar(u8, first_line, ',') == null and
        std.mem.indexOfScalar(u8, first_line, '\t') != null)
    {
        return '\t';
    }
    return ',';
}

const Parser = struct {
    ctx: *core.ReadContext,
    bytes: []const u8,
    separator: u8,
    /// Reused unquoted field content.
    field: std.ArrayList(u8) = .empty,
    row_open: ?core.builder.BlockToken = null,
    column_count: u32 = 0,
    first_row_columns: u32 = 0,
    row_index: u32 = 0,
    head_open: ?core.builder.BlockToken = null,
    body_open: ?core.builder.BlockToken = null,
    table_open: core.builder.BlockToken = undefined,

    fn run(p: *Parser) core.ReadError!void {
        defer p.field.deinit(p.ctx.gpa);

        // Column count comes from the first record, for the alignment row.
        p.first_row_columns = countFirstRowColumns(p.bytes, p.separator);
        var alignments: std.ArrayList(core.payload.Alignment) = .empty;
        defer alignments.deinit(p.ctx.gpa);
        try alignments.appendNTimes(p.ctx.gpa, .default, p.first_row_columns);
        p.table_open = try p.ctx.out.beginTable(alignments.items);

        var i: usize = 0;
        var in_field = false;
        while (i < p.bytes.len) {
            const byte = p.bytes[i];
            if (byte == '"') {
                in_field = true;
                i = try p.consumeQuoted(i + 1);
            } else if (byte == p.separator) {
                try p.endField();
                in_field = false;
                i += 1;
            } else if (byte == '\n' or byte == '\r') {
                if (in_field or p.field.items.len > 0 or p.row_open != null) {
                    try p.endField();
                    try p.endRow();
                }
                in_field = false;
                i += 1;
                if (byte == '\r' and i < p.bytes.len and p.bytes[i] == '\n') i += 1;
            } else {
                in_field = true;
                try p.field.append(p.ctx.gpa, byte);
                i += 1;
            }
        }
        if (in_field or p.field.items.len > 0 or p.row_open != null) {
            try p.endField();
            try p.endRow();
        }

        if (p.body_open) |token| p.ctx.out.endBlock(token);
        p.ctx.out.endBlock(p.table_open);
    }

    /// From just after an opening quote to just after the closing quote.
    fn consumeQuoted(p: *Parser, start: usize) core.ReadError!usize {
        var i = start;
        while (i < p.bytes.len) {
            const byte = p.bytes[i];
            if (byte == '"') {
                if (i + 1 < p.bytes.len and p.bytes[i + 1] == '"') {
                    try p.field.append(p.ctx.gpa, '"');
                    i += 2;
                } else {
                    return i + 1;
                }
            } else {
                try p.field.append(p.ctx.gpa, byte);
                i += 1;
            }
        }
        try p.ctx.reports.add(unterminatedQuoteReport());
        return error.Malformed;
    }

    fn endField(p: *Parser) core.ReadError!void {
        if (p.row_open == null) {
            try p.openRow();
        }
        const cell = try p.ctx.out.beginTableCell(.plain);
        const content = try p.ctx.out.beginPlain();
        try p.ctx.out.text(p.field.items);
        p.ctx.out.endBlock(content);
        p.ctx.out.endBlock(cell);
        p.field.clearRetainingCapacity();
        p.column_count += 1;
    }

    fn openRow(p: *Parser) core.ReadError!void {
        if (p.row_index == 0) {
            p.head_open = try p.ctx.out.beginBlock(.table_head);
        } else if (p.row_index == 1) {
            p.body_open = try p.ctx.out.beginTableBody(.{
                .row_head_columns = 0,
                .head_rows = 0,
            });
        }
        p.row_open = try p.ctx.out.beginBlock(.table_row);
        p.column_count = 0;
    }

    fn endRow(p: *Parser) core.ReadError!void {
        const token = p.row_open orelse return;
        p.ctx.out.endBlock(token);
        p.row_open = null;
        if (p.row_index == 0) {
            p.ctx.out.endBlock(p.head_open.?);
            p.head_open = null;
        }
        if (p.column_count != p.first_row_columns) {
            try p.ctx.reports.add(raggedRowNote());
        }
        p.row_index += 1;
    }
};

fn countFirstRowColumns(bytes: []const u8, separator: u8) u32 {
    var count: u32 = 1;
    var i: usize = 0;
    var quoted = false;
    while (i < bytes.len) : (i += 1) {
        const byte = bytes[i];
        if (quoted) {
            if (byte == '"') {
                if (i + 1 < bytes.len and bytes[i + 1] == '"') {
                    i += 1;
                } else {
                    quoted = false;
                }
            }
        } else if (byte == '"') {
            quoted = true;
        } else if (byte == separator) {
            count += 1;
        } else if (byte == '\n' or byte == '\r') {
            break;
        }
    }
    return count;
}

fn invalidUtf8Report() core.Report {
    return .{
        .severity = .err,
        .code = "csv.invalid-utf8",
        .title = "THE INPUT IS NOT VALID UTF-8",
        .problem = "This file contains bytes that are not valid UTF-8. It " ++
            "may be in a legacy spreadsheet export encoding.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Convert the encoding first",
            .explanation = "Re-export the data as UTF-8 CSV, or convert " ++
                "it — for example with `iconv -f windows-1252 -t utf-8` — " ++
                "and run zenfmt on the result.",
        }},
    };
}

fn unterminatedQuoteReport() core.Report {
    return .{
        .severity = .err,
        .code = "csv.unterminated-quote",
        .title = "A QUOTED FIELD NEVER ENDS",
        .problem = "A field opens with a double quote that is never " ++
            "closed, so the rest of the file is one endless field.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Fix the quote",
            .explanation = "Find the unbalanced double quote — it is " ++
                "usually in the last row the file was edited in — and " ++
                "close or remove it. A literal quote inside a quoted " ++
                "field is written doubled: \"\".",
        }},
    };
}

fn raggedRowNote() core.Report {
    return .{
        .severity = .note,
        .code = "csv.ragged-row",
        .title = "ROW WIDTH DIFFERS FROM THE HEADER",
        .problem = "A row has a different number of fields than the " ++
            "first row.",
        .consequence = "The row was kept as-is; the rendered table pads " ++
            "or truncates its columns to stay rectangular.",
        .loss = .structural,
        .directions = &.{.{
            .title = "Check the source data",
            .explanation = "Check the source data for missing or extra " ++
                "separators in that row if the table looks wrong.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn parseCsv(arena: std.mem.Allocator, bytes: []const u8, name: []const u8) !core.Document {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = name,
        .reports = reports,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return doc;
}

test "quoting, embedded newlines, and the final unterminated field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try parseCsv(arena,
        \\name,note
        \\alpha,"says ""hi"", twice"
        \\beta,last
    , "data.csv");

    const tags = doc.store.blocks.items(.tag);
    try testing.expectEqual(core.BlockTag.table, tags[0]);
    // table > head > row > 2 cells, body > 2 rows > 2 cells each.
    var cells: u32 = 0;
    for (tags) |tag| {
        if (tag == .table_cell) cells += 1;
    }
    try testing.expectEqual(@as(u32, 6), cells);
}

test "tsv detection by extension and by content" {
    try testing.expectEqual(@as(u8, '\t'), detectSeparator("x.tsv", "a\tb"));
    try testing.expectEqual(@as(u8, '\t'), detectSeparator("x.csv", "a\tb\nc\td"));
    try testing.expectEqual(@as(u8, ','), detectSeparator("x.csv", "a,b\tc"));
}

test "an unterminated quote is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.Malformed, parseCsv(arena, "a,\"open\nnever closed", "x.csv"));
}
