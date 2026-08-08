//! The reStructuredText reader (ZDS 0002, The other formats):
//! indentation-structured, with directives and roles as the extension
//! mechanism. Directives map to `container` and roles to `span`, both
//! carrying the directive name as a class. Reference-style links need a
//! second pass, since a target may be defined anywhere in the document.
//! `.. include::` is refused for the same reason AsciiDoc's is.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.rst",
    .format = "rst",
    .extensions = &.{"rst"},
    .read = read,
});

fn read(ctx: *core.ReadContext) core.ReadError!void {
    if (!std.unicode.utf8ValidateSlice(ctx.input.bytes)) {
        try ctx.reports.add(invalidUtf8Report());
        return error.Malformed;
    }

    // First pass: reference targets, definable anywhere.
    var targets: std.StringHashMapUnmanaged([]const u8) = .empty;
    {
        var lines = std.mem.splitScalar(u8, ctx.input.bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (parseTarget(line)) |target| {
                const key = try ctx.gpa.dupe(u8, target.name);
                try targets.put(ctx.gpa, key, try ctx.gpa.dupe(u8, target.url));
            }
        }
    }

    var parser: Parser = .{ .ctx = ctx, .targets = &targets };
    defer parser.deinit();
    var lines = std.mem.splitScalar(u8, ctx.input.bytes, '\n');
    var previous: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        try parser.addLine(line, previous, lines.peek());
        previous = line;
    }
    try parser.finish();
}

const Target = struct {
    name: []const u8,
    url: []const u8,
};

/// `.. _name: url` on one line.
fn parseTarget(line: []const u8) ?Target {
    if (!std.mem.startsWith(u8, line, ".. _")) return null;
    const colon = std.mem.indexOfScalarPos(u8, line, 4, ':') orelse return null;
    const name = line[4..colon];
    const url = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (name.len == 0 or url.len == 0) return null;
    return .{ .name = name, .url = url };
}

const Parser = struct {
    ctx: *core.ReadContext,
    targets: *const std.StringHashMapUnmanaged([]const u8),

    paragraph: std.ArrayList(u8) = .empty,
    /// Adornment characters seen for section levels, in first-seen order.
    adornments: [6]u8 = .{0} ** 6,
    adornment_count: u8 = 0,
    /// The paragraph line just consumed as a heading, to skip its underline.
    heading_underline_pending: bool = false,
    /// Open directive container and its content indent.
    directive: ?Directive = null,
    /// Literal block state after a `::` paragraph.
    literal: ?Literal = null,
    list_open: ?struct {
        list_token: core.builder.BlockToken,
        item_token: ?core.builder.BlockToken,
        ordered: bool,
    } = null,
    include_noted: bool = false,

    const Directive = struct {
        token: core.builder.BlockToken,
        indent: u32,
    };

    const Literal = struct {
        content: std.ArrayList(u8),
        /// Established by the first content line.
        indent: ?u32,
    };

    fn deinit(p: *Parser) void {
        p.paragraph.deinit(p.ctx.gpa);
        if (p.literal) |*literal| literal.content.deinit(p.ctx.gpa);
    }

    fn addLine(
        p: *Parser,
        line: []const u8,
        previous: ?[]const u8,
        next: ?[]const u8,
    ) core.ReadError!void {
        if (p.heading_underline_pending) {
            p.heading_underline_pending = false;
            return;
        }

        // Literal blocks: indented content after `::`.
        if (p.literal) |*literal| {
            const blank = std.mem.indexOfNone(u8, line, " \t") == null;
            if (blank) {
                // Interior blanks are content; the leading ones are not.
                if (literal.content.items.len > 0) {
                    try literal.content.append(p.ctx.gpa, '\n');
                }
                return;
            }
            const indent = indentWidth(line);
            if (literal.indent == null and indent > 0) literal.indent = indent;
            if (literal.indent != null and indent >= literal.indent.?) {
                const content_start = @min(literal.indent.?, line.len);
                try literal.content.appendSlice(p.ctx.gpa, line[content_start..]);
                try literal.content.append(p.ctx.gpa, '\n');
                return;
            }
            // Dedent ends the block.
            const trimmed_content = std.mem.trimEnd(u8, literal.content.items, "\n");
            try p.ctx.out.codeBlock("", trimmed_content);
            literal.content.deinit(p.ctx.gpa);
            p.literal = null;
        }

        const trimmed = std.mem.trim(u8, line, " \t");
        const indent = indentWidth(line);

        // Directive content is anything indented deeper than its marker.
        if (p.directive) |directive| {
            if (trimmed.len > 0 and indent < directive.indent) {
                try p.flushParagraph();
                try p.closeList();
                p.ctx.out.endBlock(directive.token);
                p.directive = null;
            }
        }

        if (trimmed.len == 0) {
            try p.flushParagraph();
            try p.closeList();
            return;
        }

        // Explicit markup: targets, directives, comments, includes.
        if (std.mem.startsWith(u8, trimmed, ".. ")) {
            try p.flushParagraph();
            try p.closeList();
            const body = trimmed[3..];
            if (parseTarget(trimmed) != null) return; // collected in pass one
            if (std.mem.startsWith(u8, body, "include::")) {
                if (!p.include_noted) {
                    p.include_noted = true;
                    try p.ctx.reports.add(includeReport());
                }
                return;
            }
            if (std.mem.indexOf(u8, body, "::")) |marker| {
                const name = std.mem.trim(u8, body[0..marker], " ");
                if (name.len > 0) {
                    // A directive: its indented body becomes a container.
                    if (p.directive) |open| {
                        p.ctx.out.endBlock(open.token);
                    }
                    var class_buffer: [64]u8 = undefined;
                    if (name.len <= class_buffer.len) {
                        const class = std.ascii.lowerString(&class_buffer, name);
                        try p.ctx.out.attrs(.{ .classes = &.{class} });
                    }
                    const token = try p.ctx.out.beginBlock(.container);
                    p.directive = .{ .token = token, .indent = indent + 3 };
                    return;
                }
            }
            // A comment: ignored.
            return;
        }

        // Section titles: a text line underlined by punctuation.
        if (next) |next_line| {
            const next_trimmed = std.mem.trim(u8, next_line, " \t\r");
            if (isAdornment(next_trimmed) and next_trimmed.len >= trimmed.len and
                p.paragraph.items.len == 0)
            {
                try p.closeList();
                const level = p.levelFor(next_trimmed[0]);
                const token = try p.ctx.out.beginHeading(level);
                try p.emitInlines(trimmed);
                p.ctx.out.endBlock(token);
                p.heading_underline_pending = true;
                return;
            }
        }
        _ = previous;

        // Transitions: a lone adornment line.
        if (isAdornment(trimmed) and trimmed.len >= 4 and p.paragraph.items.len == 0) {
            try p.closeList();
            try p.ctx.out.thematicBreak();
            return;
        }

        // Bullet and enumerated list items.
        if (matchListItem(trimmed)) |item| {
            try p.flushParagraph();
            try p.enterListItem(item.ordered);
            const paragraph = try p.ctx.out.beginPlain();
            try p.emitInlines(item.text);
            p.ctx.out.endBlock(paragraph);
            return;
        }

        // Paragraph text; a trailing `::` also opens a literal block.
        if (p.paragraph.items.len > 0) try p.paragraph.append(p.ctx.gpa, '\n');
        try p.paragraph.appendSlice(p.ctx.gpa, trimmed);
        if (std.mem.endsWith(u8, trimmed, "::")) {
            // Trim to a single colon for the visible paragraph, per spec.
            p.paragraph.items.len -= 1;
            if (std.mem.endsWith(u8, p.paragraph.items, " :")) {
                p.paragraph.items.len -= 2;
            }
            try p.flushParagraph();
            p.literal = .{ .content = .empty, .indent = null };
        }
    }

    fn levelFor(p: *Parser, adornment: u8) u8 {
        for (p.adornments[0..p.adornment_count], 0..) |seen, i| {
            if (seen == adornment) return @intCast(i + 1);
        }
        if (p.adornment_count < p.adornments.len) {
            p.adornments[p.adornment_count] = adornment;
            p.adornment_count += 1;
            return p.adornment_count;
        }
        return 6;
    }

    fn flushParagraph(p: *Parser) core.ReadError!void {
        if (p.paragraph.items.len == 0) return;
        const token = try p.ctx.out.beginParagraph();
        try p.emitInlines(p.paragraph.items);
        p.ctx.out.endBlock(token);
        p.paragraph.clearRetainingCapacity();
    }

    fn enterListItem(p: *Parser, ordered: bool) core.ReadError!void {
        if (p.list_open) |*open| {
            if (open.ordered != ordered) {
                try p.closeList();
            }
        }
        if (p.list_open == null) {
            p.list_open = .{
                .list_token = try p.ctx.out.beginList(.{
                    .kind = if (ordered) .ordered else .unordered,
                    .start = 1,
                    .style = .decimal,
                    .delimiter = .period,
                }),
                .item_token = null,
                .ordered = ordered,
            };
        }
        const open = &p.list_open.?;
        if (open.item_token) |token| p.ctx.out.endBlock(token);
        open.item_token = try p.ctx.out.beginBlock(.list_item);
    }

    fn closeList(p: *Parser) core.ReadError!void {
        const open = p.list_open orelse return;
        if (open.item_token) |token| p.ctx.out.endBlock(token);
        p.ctx.out.endBlock(open.list_token);
        p.list_open = null;
    }

    fn finish(p: *Parser) core.ReadError!void {
        if (p.literal) |*literal| {
            const trimmed = std.mem.trimEnd(u8, literal.content.items, "\n");
            try p.ctx.out.codeBlock("", trimmed);
            literal.content.deinit(p.ctx.gpa);
            p.literal = null;
        }
        try p.flushParagraph();
        try p.closeList();
        if (p.directive) |directive| {
            p.ctx.out.endBlock(directive.token);
            p.directive = null;
        }
    }

    /// Inline forms: `**strong**`, `*emphasis*`, double-backtick literals,
    /// `` `text <url>`_ `` links, and `` `name`_ `` references.
    fn emitInlines(p: *Parser, text: []const u8) core.ReadError!void {
        var i: usize = 0;
        var literal_start: usize = 0;
        while (i < text.len) {
            if (std.mem.startsWith(u8, text[i..], "``")) {
                if (std.mem.indexOfPos(u8, text, i + 2, "``")) |close| {
                    try p.ctx.out.text(text[literal_start..i]);
                    try p.ctx.out.code(text[i + 2 .. close]);
                    i = close + 2;
                    literal_start = i;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, text[i..], "**")) {
                if (std.mem.indexOfPos(u8, text, i + 2, "**")) |close| {
                    try p.ctx.out.text(text[literal_start..i]);
                    const token = try p.ctx.out.beginInline(.strong);
                    try p.ctx.out.text(text[i + 2 .. close]);
                    p.ctx.out.endInline(token);
                    i = close + 2;
                    literal_start = i;
                    continue;
                }
            }
            if (text[i] == '*') {
                if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |close| {
                    if (close > i + 1) {
                        try p.ctx.out.text(text[literal_start..i]);
                        const token = try p.ctx.out.beginInline(.emphasis);
                        try p.ctx.out.text(text[i + 1 .. close]);
                        p.ctx.out.endInline(token);
                        i = close + 1;
                        literal_start = i;
                        continue;
                    }
                }
            }
            if (text[i] == '`') {
                // `text <url>`_ or `name`_ reference forms.
                if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
                    if (close + 1 < text.len and text[close + 1] == '_') {
                        const inner = text[i + 1 .. close];
                        try p.ctx.out.text(text[literal_start..i]);
                        try p.emitReference(inner);
                        i = close + 2;
                        literal_start = i;
                        continue;
                    }
                }
            }
            i += 1;
        }
        try p.ctx.out.text(text[literal_start..]);
    }

    fn emitReference(p: *Parser, inner: []const u8) core.ReadError!void {
        if (std.mem.lastIndexOfScalar(u8, inner, '<')) |open| {
            if (std.mem.endsWith(u8, inner, ">")) {
                const label = std.mem.trim(u8, inner[0..open], " ");
                const url = inner[open + 1 .. inner.len - 1];
                const token = try p.ctx.out.beginLink(url, "");
                try p.ctx.out.text(if (label.len > 0) label else url);
                p.ctx.out.endInline(token);
                return;
            }
        }
        const url = p.targets.get(inner) orelse {
            // An unresolvable reference keeps its text.
            try p.ctx.out.text(inner);
            return;
        };
        const token = try p.ctx.out.beginLink(url, "");
        try p.ctx.out.text(inner);
        p.ctx.out.endInline(token);
    }
};

fn indentWidth(line: []const u8) u32 {
    var width: u32 = 0;
    for (line) |byte| switch (byte) {
        ' ' => width += 1,
        '\t' => width += 4,
        else => return width,
    };
    return width;
}

fn isAdornment(line: []const u8) bool {
    if (line.len < 2) return false;
    const char = line[0];
    if (std.ascii.isAlphanumeric(char) or char == ' ') return false;
    for (line) |byte| {
        if (byte != char) return false;
    }
    return true;
}

const ListItem = struct {
    ordered: bool,
    text: []const u8,
};

fn matchListItem(trimmed: []const u8) ?ListItem {
    if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and
        trimmed[1] == ' ')
    {
        return .{ .ordered = false, .text = std.mem.trimStart(u8, trimmed[2..], " ") };
    }
    var digits: usize = 0;
    while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) digits += 1;
    if (digits > 0 and digits + 1 < trimmed.len and trimmed[digits] == '.' and
        trimmed[digits + 1] == ' ')
    {
        return .{ .ordered = true, .text = std.mem.trimStart(u8, trimmed[digits + 2 ..], " ") };
    }
    if (trimmed.len >= 3 and trimmed[0] == '#' and trimmed[1] == '.' and trimmed[2] == ' ') {
        return .{ .ordered = true, .text = std.mem.trimStart(u8, trimmed[3..], " ") };
    }
    return null;
}

// ------------------------------------------------------------- reports

fn invalidUtf8Report() core.Report {
    return .{
        .severity = .err,
        .code = "rst.invalid-utf8",
        .title = "THE INPUT IS NOT VALID UTF-8",
        .problem = "This file contains bytes that are not valid UTF-8.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Convert the encoding first",
            .explanation = "Convert the file to UTF-8 and run zenfmt on " ++
                "the result.",
        }},
    };
}

fn includeReport() core.Report {
    return .{
        .severity = .warning,
        .code = "rst.include-refused",
        .title = "INCLUDE DIRECTIVES REFUSED",
        .problem = "This document uses .. include:: directives. A " ++
            "converter that reads arbitrary files named by its input is " ++
            "a file-disclosure primitive, so zenfmt never follows them.",
        .consequence = "The included files' content is absent from the " ++
            "output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Pre-process the includes",
            .explanation = "Resolve the includes with a trusted " ++
                "docutils toolchain first and convert the combined " ++
                "document.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn convertRst(arena: std.mem.Allocator, bytes: []const u8) !core.ast.Document {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "test.rst",
        .reports = reports,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return doc;
}

test "sections, directives, literals, lists, and references" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try convertRst(arena,
        \\The Title
        \\=========
        \\
        \\A Section
        \\---------
        \\
        \\Some **strong** and *soft* text with ``code`` and `Zig`_.
        \\
        \\.. note::
        \\   Indented directive body.
        \\
        \\A literal follows::
        \\
        \\   const a = 1;
        \\
        \\- one
        \\- two
        \\
        \\.. _Zig: https://ziglang.org/
        \\
    );
    var headings: u32 = 0;
    var containers: u32 = 0;
    var code_blocks: u32 = 0;
    for (doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .heading => headings += 1,
        .container => containers += 1,
        .code_block => code_blocks += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 2), headings);
    try testing.expectEqual(@as(u32, 1), containers);
    try testing.expectEqual(@as(u32, 1), code_blocks);

    var links: u32 = 0;
    for (doc.store.inlines.items(.tag)) |tag| {
        if (tag == .link) links += 1;
    }
    try testing.expectEqual(@as(u32, 1), links);
}
