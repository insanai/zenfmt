//! The AsciiDoc reader (ZDS 0002, The other formats): blocks are delimited
//! by run-length markers, and admonitions, sidebars, and open blocks map to
//! `container` with a class — exactly the job `container` exists for.
//! Attribute entries become document metadata. The `include::` directive is
//! *not* followed — a converter that reads arbitrary files named by its
//! input is a file-disclosure primitive — and the refusal is reported
//! rather than silent.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.asciidoc",
    .format = "asciidoc",
    .extensions = &.{ "adoc", "asciidoc" },
    .read = read,
});

const admonitions = [_][]const u8{ "NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION" };

fn read(ctx: *core.ReadContext) core.ReadError!void {
    if (!std.unicode.utf8ValidateSlice(ctx.input.bytes)) {
        try ctx.reports.add(invalidUtf8Report());
        return error.Malformed;
    }
    var parser: Parser = .{ .ctx = ctx };
    defer parser.deinit();

    var lines = std.mem.splitScalar(u8, ctx.input.bytes, '\n');
    while (lines.next()) |raw| {
        try parser.addLine(std.mem.trimEnd(u8, raw, "\r"));
    }
    try parser.finish();
}

const ListEntry = struct {
    marker_depth: u32,
    ordered: bool,
    list_token: core.builder.BlockToken,
    item_token: ?core.builder.BlockToken,
};

const Parser = struct {
    ctx: *core.ReadContext,

    paragraph: std.ArrayList(u8) = .empty,
    /// A block style from `[NOTE]`-form attribute lines, pending until the
    /// next block.
    pending_style: ?[]const u8 = null,
    /// Open delimited container: its class and closing delimiter line.
    container: ?Container = null,
    /// Inside a listing/literal block: verbatim accumulation.
    listing: ?Listing = null,
    lists: [16]ListEntry = undefined,
    list_depth: u32 = 0,
    include_noted: bool = false,

    const Container = struct {
        token: core.builder.BlockToken,
        delimiter: []const u8,
    };

    const Listing = struct {
        delimiter: []const u8,
        content: std.ArrayList(u8),
    };

    fn deinit(p: *Parser) void {
        p.paragraph.deinit(p.ctx.gpa);
        if (p.listing) |*listing| listing.content.deinit(p.ctx.gpa);
    }

    fn addLine(p: *Parser, line: []const u8) core.ReadError!void {
        // Verbatim blocks swallow everything to their closing delimiter.
        if (p.listing) |*listing| {
            if (std.mem.eql(u8, line, listing.delimiter)) {
                try p.ctx.out.codeBlock("", listing.content.items);
                listing.content.deinit(p.ctx.gpa);
                p.listing = null;
            } else {
                try listing.content.appendSlice(p.ctx.gpa, line);
                try listing.content.append(p.ctx.gpa, '\n');
            }
            return;
        }

        const trimmed = std.mem.trimEnd(u8, line, " \t");
        if (trimmed.len == 0) {
            try p.flushParagraph();
            try p.closeLists();
            return;
        }

        // The closing delimiter of an open container.
        if (p.container) |container| {
            if (std.mem.eql(u8, trimmed, container.delimiter)) {
                try p.flushParagraph();
                try p.closeLists();
                p.ctx.out.endBlock(container.token);
                p.container = null;
                return;
            }
        }

        // Attribute entries: `:name: value` become document metadata.
        if (trimmed.len > 2 and trimmed[0] == ':') {
            if (std.mem.indexOfScalarPos(u8, trimmed, 1, ':')) |close| {
                const name = trimmed[1..close];
                if (name.len > 0 and std.mem.indexOfScalar(u8, name, ' ') == null) {
                    try p.flushParagraph();
                    const value = std.mem.trimStart(u8, trimmed[close + 1 ..], " ");
                    try p.ctx.out.metaString(name, value);
                    return;
                }
            }
        }

        // include:: is refused, loudly, and never followed.
        if (std.mem.startsWith(u8, trimmed, "include::")) {
            try p.flushParagraph();
            if (!p.include_noted) {
                p.include_noted = true;
                try p.ctx.reports.add(includeReport());
            }
            return;
        }

        // Block attribute lines: `[NOTE]`, `[source,zig]`, `[quote]`.
        if (trimmed.len > 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            try p.flushParagraph();
            p.pending_style = try p.ctx.gpa.dupe(u8, trimmed[1 .. trimmed.len - 1]);
            return;
        }

        // Section titles: `= Title` through `====== Title`.
        if (matchHeading(trimmed)) |heading| {
            try p.flushParagraph();
            try p.closeLists();
            const token = try p.ctx.out.beginHeading(heading.level);
            try p.ctx.out.text(heading.text);
            p.ctx.out.endBlock(token);
            p.pending_style = null;
            return;
        }

        // Delimited blocks, by run-length marker.
        if (delimiterRun(trimmed)) |delimiter| {
            try p.flushParagraph();
            try p.closeLists();
            switch (delimiter.kind) {
                .listing => {
                    p.listing = .{
                        .delimiter = try p.ctx.gpa.dupe(u8, trimmed),
                        .content = .empty,
                    };
                    p.pending_style = null;
                },
                .container => {
                    if (p.container != null) {
                        // One level of delimited containers; deeper nesting
                        // folds into the open one.
                        return;
                    }
                    const class = p.takeStyleClass() orelse delimiter.default_class;
                    try p.ctx.out.attrs(.{ .classes = &.{class} });
                    const token = try p.ctx.out.beginBlock(.container);
                    p.container = .{
                        .token = token,
                        .delimiter = try p.ctx.gpa.dupe(u8, trimmed),
                    };
                },
                .quote => {
                    if (p.container != null) return;
                    const token = try p.ctx.out.beginBlock(.quote);
                    p.container = .{
                        .token = token,
                        .delimiter = try p.ctx.gpa.dupe(u8, trimmed),
                    };
                    p.pending_style = null;
                },
                .thematic_break => {
                    try p.ctx.out.thematicBreak();
                    p.pending_style = null;
                },
            }
            return;
        }

        // Admonition paragraphs: `NOTE: text`.
        for (admonitions) |admonition| {
            if (std.mem.startsWith(u8, trimmed, admonition) and
                trimmed.len > admonition.len + 1 and
                trimmed[admonition.len] == ':' and trimmed[admonition.len + 1] == ' ')
            {
                try p.flushParagraph();
                try p.closeLists();
                var class_buffer: [16]u8 = undefined;
                const class = std.ascii.lowerString(&class_buffer, admonition);
                try p.ctx.out.attrs(.{ .classes = &.{class} });
                const container = try p.ctx.out.beginBlock(.container);
                const paragraph = try p.ctx.out.beginParagraph();
                try emitInlines(p.ctx, trimmed[admonition.len + 2 ..]);
                p.ctx.out.endBlock(paragraph);
                p.ctx.out.endBlock(container);
                return;
            }
        }

        // List items: `*`/`**` bullets and `.`/`..` numbers.
        if (matchListItem(trimmed)) |item| {
            try p.flushParagraph();
            try p.enterListItem(item.depth, item.ordered);
            const paragraph = try p.ctx.out.beginPlain();
            try emitInlines(p.ctx, item.text);
            p.ctx.out.endBlock(paragraph);
            return;
        }

        // Ordinary text accumulates into the open paragraph.
        if (p.paragraph.items.len > 0) try p.paragraph.append(p.ctx.gpa, '\n');
        try p.paragraph.appendSlice(p.ctx.gpa, trimmed);
    }

    fn takeStyleClass(p: *Parser) ?[]const u8 {
        const style = p.pending_style orelse return null;
        p.pending_style = null;
        // `[source,zig]` and friends keep only the leading word.
        const comma = std.mem.indexOfScalar(u8, style, ',') orelse style.len;
        if (comma == 0) return null;
        var buffer: [64]u8 = undefined;
        if (comma > buffer.len) return null;
        const lowered = std.ascii.lowerString(buffer[0..comma], style[0..comma]);
        // The class must outlive this call; intern through the arena.
        return p.ctx.gpa.dupe(u8, lowered) catch null;
    }

    fn flushParagraph(p: *Parser) core.ReadError!void {
        if (p.paragraph.items.len == 0) return;
        const token = try p.ctx.out.beginParagraph();
        try emitInlines(p.ctx, p.paragraph.items);
        p.ctx.out.endBlock(token);
        p.paragraph.clearRetainingCapacity();
        p.pending_style = null;
    }

    fn enterListItem(p: *Parser, marker_depth: u32, ordered: bool) core.ReadError!void {
        while (p.list_depth > 0) {
            const top = &p.lists[p.list_depth - 1];
            if (top.marker_depth > marker_depth or
                (top.marker_depth == marker_depth and top.ordered != ordered))
            {
                try p.closeOneList();
            } else break;
        }
        if (p.list_depth == 0 or p.lists[p.list_depth - 1].marker_depth < marker_depth) {
            assert(p.list_depth < p.lists.len);
            const token = try p.ctx.out.beginList(.{
                .kind = if (ordered) .ordered else .unordered,
                .start = 1,
                .style = .decimal,
                .delimiter = .period,
            });
            p.lists[p.list_depth] = .{
                .marker_depth = marker_depth,
                .ordered = ordered,
                .list_token = token,
                .item_token = null,
            };
            p.list_depth += 1;
        }
        const top = &p.lists[p.list_depth - 1];
        if (top.item_token) |token| p.ctx.out.endBlock(token);
        top.item_token = try p.ctx.out.beginBlock(.list_item);
    }

    fn closeOneList(p: *Parser) core.ReadError!void {
        assert(p.list_depth > 0);
        const top = &p.lists[p.list_depth - 1];
        if (top.item_token) |token| p.ctx.out.endBlock(token);
        p.ctx.out.endBlock(top.list_token);
        p.list_depth -= 1;
    }

    fn closeLists(p: *Parser) core.ReadError!void {
        while (p.list_depth > 0) try p.closeOneList();
    }

    fn finish(p: *Parser) core.ReadError!void {
        try p.flushParagraph();
        try p.closeLists();
        if (p.listing) |*listing| {
            // An unclosed listing keeps its content; honesty over loss.
            try p.ctx.out.codeBlock("", listing.content.items);
            listing.content.deinit(p.ctx.gpa);
            p.listing = null;
        }
        if (p.container) |container| {
            p.ctx.out.endBlock(container.token);
            p.container = null;
        }
    }
};

const Heading = struct {
    level: u8,
    text: []const u8,
};

fn matchHeading(line: []const u8) ?Heading {
    var level: u8 = 0;
    while (level < line.len and line[level] == '=') level += 1;
    if (level == 0 or level > 6) return null;
    if (level >= line.len or line[level] != ' ') return null;
    return .{ .level = level, .text = std.mem.trim(u8, line[level..], " ") };
}

const DelimiterKind = enum { listing, container, quote, thematic_break };

const Delimiter = struct {
    kind: DelimiterKind,
    default_class: []const u8,
};

fn delimiterRun(line: []const u8) ?Delimiter {
    if (line.len < 3) return null;
    const char = line[0];
    for (line) |byte| {
        if (byte != char) return null;
    }
    return switch (char) {
        '-' => if (line.len == 4) .{ .kind = .listing, .default_class = "" } else null,
        '.' => .{ .kind = .listing, .default_class = "" },
        '=' => if (line.len >= 4) .{ .kind = .container, .default_class = "example" } else null,
        '*' => .{ .kind = .container, .default_class = "sidebar" },
        '_' => .{ .kind = .quote, .default_class = "" },
        '\'' => .{ .kind = .thematic_break, .default_class = "" },
        else => null,
    };
}

const ListItem = struct {
    depth: u32,
    ordered: bool,
    text: []const u8,
};

fn matchListItem(line: []const u8) ?ListItem {
    const char = line[0];
    if (char != '*' and char != '.') return null;
    var depth: u32 = 0;
    while (depth < line.len and line[depth] == char) depth += 1;
    if (depth >= line.len or line[depth] != ' ') return null;
    if (depth > 8) return null;
    return .{
        .depth = depth,
        .ordered = char == '.',
        .text = std.mem.trimStart(u8, line[depth..], " "),
    };
}

/// Constrained inline forms: `*bold*`, `_italic_`, backtick code, and
/// URL macros `https://...[text]`.
fn emitInlines(ctx: *core.ReadContext, text: []const u8) core.ReadError!void {
    var i: usize = 0;
    var literal_start: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if ((byte == '*' or byte == '_' or byte == '`') and constrainedOpen(text, i)) {
            if (findConstrainedClose(text, i)) |close| {
                try ctx.out.text(text[literal_start..i]);
                const content = text[i + 1 .. close];
                switch (byte) {
                    '`' => try ctx.out.code(content),
                    '*' => {
                        const token = try ctx.out.beginInline(.strong);
                        try ctx.out.text(content);
                        ctx.out.endInline(token);
                    },
                    '_' => {
                        const token = try ctx.out.beginInline(.emphasis);
                        try ctx.out.text(content);
                        ctx.out.endInline(token);
                    },
                    else => unreachable,
                }
                i = close + 1;
                literal_start = i;
                continue;
            }
        }
        if (std.mem.startsWith(u8, text[i..], "http://") or
            std.mem.startsWith(u8, text[i..], "https://"))
        {
            const url_end = std.mem.indexOfAnyPos(u8, text, i, " [") orelse text.len;
            if (url_end < text.len and text[url_end] == '[') {
                if (std.mem.indexOfScalarPos(u8, text, url_end, ']')) |label_end| {
                    try ctx.out.text(text[literal_start..i]);
                    const token = try ctx.out.beginLink(text[i..url_end], "");
                    const label = text[url_end + 1 .. label_end];
                    try ctx.out.text(if (label.len > 0) label else text[i..url_end]);
                    ctx.out.endInline(token);
                    i = label_end + 1;
                    literal_start = i;
                    continue;
                }
            }
        }
        i += 1;
    }
    try ctx.out.text(text[literal_start..]);
}

fn constrainedOpen(text: []const u8, i: usize) bool {
    const before_ok = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
    const after_ok = i + 1 < text.len and !std.ascii.isWhitespace(text[i + 1]) and
        text[i + 1] != text[i];
    return before_ok and after_ok;
}

fn findConstrainedClose(text: []const u8, open: usize) ?usize {
    const char = text[open];
    var i = open + 1;
    while (std.mem.indexOfScalarPos(u8, text, i, char)) |candidate| {
        const before_ok = candidate > 0 and !std.ascii.isWhitespace(text[candidate - 1]);
        const after_ok = candidate + 1 >= text.len or
            !std.ascii.isAlphanumeric(text[candidate + 1]);
        if (before_ok and after_ok) return candidate;
        i = candidate + 1;
    }
    return null;
}

// ------------------------------------------------------------- reports

fn invalidUtf8Report() core.Report {
    return .{
        .severity = .err,
        .code = "asciidoc.invalid-utf8",
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
        .code = "asciidoc.include-refused",
        .title = "INCLUDE DIRECTIVES REFUSED",
        .problem = "This document uses include:: directives. A converter " ++
            "that reads arbitrary files named by its input is a " ++
            "file-disclosure primitive, so zenfmt never follows them.",
        .consequence = "The included files' content is absent from the " ++
            "output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Pre-process the includes",
            .explanation = "Resolve the includes first with a trusted " ++
                "AsciiDoc toolchain — `asciidoctor -o combined.adoc` " ++
                "style — and convert the combined document.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn convertAdoc(arena: std.mem.Allocator, bytes: []const u8) !core.ast.Document {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "test.adoc",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return doc;
}

test "sections, admonitions, lists, and attribute entries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try convertAdoc(arena,
        \\= The Manual
        \\:author: Zen
        \\
        \\Some *bold* text with a https://ziglang.org/[link].
        \\
        \\NOTE: Mind the gap.
        \\
        \\* one
        \\** nested
        \\* two
        \\
        \\[source,zig]
        \\----
        \\const a = 1;
        \\----
        \\
    );
    var headings: u32 = 0;
    var containers: u32 = 0;
    var code_blocks: u32 = 0;
    var lists: u32 = 0;
    for (doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .heading => headings += 1,
        .container => containers += 1,
        .code_block => code_blocks += 1,
        .list => lists += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), headings);
    try testing.expectEqual(@as(u32, 1), containers);
    try testing.expectEqual(@as(u32, 1), code_blocks);
    try testing.expectEqual(@as(u32, 2), lists);
    // The attribute entry became metadata.
    const entries = doc.metaEntries(doc.meta);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("author", doc.text(entries[0].key));
}

test "include is refused with a report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    var reports = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = "include::/etc/passwd[]\n\ntext\n" },
        .input_name = "evil.adoc",
        .reports = &reports,
        .manifest_in = null,
        .limits = .{},
    };
    try read(&ctx);
    var found = false;
    for (reports.entries.items) |entry| {
        if (std.mem.eql(u8, entry.report.code, "asciidoc.include-refused")) found = true;
    }
    try testing.expect(found);
}
