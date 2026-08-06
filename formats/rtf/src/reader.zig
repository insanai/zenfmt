//! The RTF reader (ZDS 0002, The other formats).
//!
//! Neither XML nor a container: a brace-delimited group language. One
//! explicit group stack carries character state; `\b` and `\i` are toggles
//! inherited by nested groups; `\par` ends a paragraph; `\'hh` hex escapes
//! decode in the code page named by `\ansicpg`; `\uN` carries its
//! skip-count convention; destination groups introduced by `\*` are
//! skipped wholesale. RTF in the wild comes from dozens of producers with
//! incompatible habits, so the reader is error-tolerant by design: an
//! unknown control word is skipped with a note rather than failing the
//! document.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.rtf",
    .format = "rtf",
    .extensions = &.{"rtf"},
    .read = read,
});

const GroupState = struct {
    strong: bool = false,
    emphasis: bool = false,
    strike: bool = false,
    superscript: bool = false,
    subscript: bool = false,
    small_caps: bool = false,
    underline: bool = false,
    /// Skip count for the character following `\uN`.
    unicode_skip: u8 = 1,
    /// The group is a destination whose text is not document content.
    destination: bool = false,

    fn styleEql(a: GroupState, b: GroupState) bool {
        return a.strong == b.strong and a.emphasis == b.emphasis and
            a.strike == b.strike and a.superscript == b.superscript and
            a.subscript == b.subscript and a.small_caps == b.small_caps and
            a.underline == b.underline;
    }
};

fn read(ctx: *core.ReadContext) core.ReadError!void {
    const bytes = ctx.input.bytes;
    if (!std.mem.startsWith(u8, bytes, "{\\rtf")) {
        try ctx.reports.add(notRtfReport());
        return error.Malformed;
    }
    var parser: Parser = .{ .ctx = ctx, .bytes = bytes };
    defer parser.deinit();
    try parser.run();
}

/// Destinations whose content never reaches the document, even without a
/// `\*` marker.
const skip_destinations = [_][]const u8{
    "fonttbl",  "colortbl", "stylesheet", "info",      "header",            "footer",
    "headerl",  "headerr",  "headerf",    "footerl",   "footerr",           "footerf",
    "pict",     "object",   "themedata",  "listtable", "listoverridetable", "generator",
    "xmlnstbl", "revtbl",
};

const Parser = struct {
    ctx: *core.ReadContext,
    bytes: []const u8,
    pos: usize = 0,

    stack: [128]GroupState = undefined,
    depth: u32 = 0,
    current: GroupState = .{},

    paragraph: ?core.builder.BlockToken = null,
    style_tokens: [8]core.builder.InlineToken = undefined,
    style_count: u8 = 0,
    open_style: GroupState = .{},
    /// The code page for `\'hh` escapes; 1252 unless `\ansicpg` says else.
    code_page: u16 = 1252,
    unknown_words_noted: bool = false,

    fn deinit(p: *Parser) void {
        _ = p;
    }

    fn run(p: *Parser) core.ReadError!void {
        while (p.pos < p.bytes.len) {
            const byte = p.bytes[p.pos];
            switch (byte) {
                '{' => {
                    if (p.depth >= p.stack.len) {
                        try p.ctx.reports.add(tooDeepReport());
                        return error.LimitExceeded;
                    }
                    p.stack[p.depth] = p.current;
                    p.depth += 1;
                    p.pos += 1;
                },
                '}' => {
                    if (p.depth == 0) break;
                    p.depth -= 1;
                    p.current = p.stack[p.depth];
                    p.pos += 1;
                },
                '\\' => try p.controlWord(),
                '\r', '\n' => p.pos += 1,
                else => {
                    if (!p.current.destination) try p.emitByte(byte);
                    p.pos += 1;
                },
            }
        }
        try p.closeParagraph();
    }

    fn controlWord(p: *Parser) core.ReadError!void {
        assert(p.bytes[p.pos] == '\\');
        p.pos += 1;
        if (p.pos >= p.bytes.len) return;
        const first = p.bytes[p.pos];

        // Control symbols.
        if (!std.ascii.isAlphabetic(first)) {
            p.pos += 1;
            switch (first) {
                '\'' => try p.hexEscape(),
                '\\', '{', '}' => if (!p.current.destination) try p.emitByte(first),
                '~' => if (!p.current.destination) try p.emitByte(' '),
                '-' => {},
                '*' => p.current.destination = true,
                else => {},
            }
            return;
        }

        const word_start = p.pos;
        while (p.pos < p.bytes.len and std.ascii.isAlphabetic(p.bytes[p.pos])) p.pos += 1;
        const word = p.bytes[word_start..p.pos];

        var has_value = false;
        var value: i32 = 0;
        var negative = false;
        if (p.pos < p.bytes.len and (p.bytes[p.pos] == '-' or std.ascii.isDigit(p.bytes[p.pos]))) {
            has_value = true;
            if (p.bytes[p.pos] == '-') {
                negative = true;
                p.pos += 1;
            }
            while (p.pos < p.bytes.len and std.ascii.isDigit(p.bytes[p.pos])) : (p.pos += 1) {
                value = value *% 10 +% (p.bytes[p.pos] - '0');
            }
            if (negative) value = -value;
        }
        // One space after a control word belongs to the word.
        if (p.pos < p.bytes.len and p.bytes[p.pos] == ' ') p.pos += 1;

        try p.applyWord(word, if (has_value) value else null);
    }

    fn applyWord(p: *Parser, word: []const u8, value: ?i32) core.ReadError!void {
        // A toggle without a value turns on; `\b0` turns off.
        const enabled = (value orelse 1) != 0;

        if (std.mem.eql(u8, word, "b")) {
            p.current.strong = enabled;
        } else if (std.mem.eql(u8, word, "i")) {
            p.current.emphasis = enabled;
        } else if (std.mem.eql(u8, word, "strike")) {
            p.current.strike = enabled;
        } else if (std.mem.eql(u8, word, "super")) {
            p.current.superscript = enabled;
            p.current.subscript = false;
        } else if (std.mem.eql(u8, word, "sub")) {
            p.current.subscript = enabled;
            p.current.superscript = false;
        } else if (std.mem.eql(u8, word, "nosupersub")) {
            p.current.superscript = false;
            p.current.subscript = false;
        } else if (std.mem.eql(u8, word, "scaps")) {
            p.current.small_caps = enabled;
        } else if (std.mem.eql(u8, word, "ul")) {
            p.current.underline = enabled;
        } else if (std.mem.eql(u8, word, "ulnone")) {
            p.current.underline = false;
        } else if (std.mem.eql(u8, word, "plain")) {
            const destination = p.current.destination;
            const skip = p.current.unicode_skip;
            p.current = .{ .destination = destination, .unicode_skip = skip };
        } else if (std.mem.eql(u8, word, "par")) {
            if (!p.current.destination) try p.closeParagraph();
        } else if (std.mem.eql(u8, word, "line")) {
            if (!p.current.destination and p.paragraph != null) try p.ctx.out.hardBreak();
        } else if (std.mem.eql(u8, word, "tab")) {
            if (!p.current.destination) try p.emitByte(' ');
        } else if (std.mem.eql(u8, word, "ansicpg")) {
            if (value) |cp| p.code_page = @intCast(@max(0, @min(cp, 65535)));
        } else if (std.mem.eql(u8, word, "uc")) {
            if (value) |skip| p.current.unicode_skip = @intCast(@max(0, @min(skip, 8)));
        } else if (std.mem.eql(u8, word, "u")) {
            try p.unicodeEscape(value orelse 0);
        } else if (std.mem.eql(u8, word, "emdash")) {
            try p.emitUtf8("—");
        } else if (std.mem.eql(u8, word, "endash")) {
            try p.emitUtf8("–");
        } else if (std.mem.eql(u8, word, "lquote")) {
            try p.emitUtf8("\u{2018}");
        } else if (std.mem.eql(u8, word, "rquote")) {
            try p.emitUtf8("\u{2019}");
        } else if (std.mem.eql(u8, word, "ldblquote")) {
            try p.emitUtf8("\u{201c}");
        } else if (std.mem.eql(u8, word, "rdblquote")) {
            try p.emitUtf8("\u{201d}");
        } else if (std.mem.eql(u8, word, "bullet")) {
            try p.emitUtf8("•");
        } else if (isSkipDestination(word)) {
            p.current.destination = true;
        } else if (std.mem.eql(u8, word, "rtf") or std.mem.eql(u8, word, "ansi") or
            std.mem.eql(u8, word, "deff") or std.mem.eql(u8, word, "pard") or
            std.mem.eql(u8, word, "sectd") or std.mem.eql(u8, word, "f") or
            std.mem.eql(u8, word, "fs") or std.mem.eql(u8, word, "cf") or
            std.mem.eql(u8, word, "cb") or std.mem.eql(u8, word, "sa") or
            std.mem.eql(u8, word, "sb") or std.mem.eql(u8, word, "sl") or
            std.mem.eql(u8, word, "qc") or std.mem.eql(u8, word, "ql") or
            std.mem.eql(u8, word, "qr") or std.mem.eql(u8, word, "qj") or
            std.mem.eql(u8, word, "fi") or std.mem.eql(u8, word, "li") or
            std.mem.eql(u8, word, "ri") or std.mem.eql(u8, word, "lang") or
            std.mem.eql(u8, word, "noproof") or std.mem.eql(u8, word, "kerning"))
        {
            // Formatting and layout the tree does not represent.
        } else {
            // Unknown control word: skipped, and said once.
            if (!p.unknown_words_noted) {
                p.unknown_words_noted = true;
                try p.ctx.reports.add(unknownWordNote());
            }
        }
    }

    fn hexEscape(p: *Parser) core.ReadError!void {
        if (p.pos + 2 > p.bytes.len) return;
        const hex = p.bytes[p.pos..][0..2];
        p.pos += 2;
        const byte = std.fmt.parseInt(u8, hex, 16) catch return;
        if (p.current.destination) return;
        try p.emitCodepoint(cp1252ToUnicode(byte, p.code_page));
    }

    fn unicodeEscape(p: *Parser, value: i32) core.ReadError!void {
        // Negative values are the 16-bit two's-complement convention.
        const code: u21 = if (value < 0)
            @intCast(@as(i64, value) + 65536)
        else
            @intCast(@min(value, 0x10ffff));
        if (!p.current.destination) try p.emitCodepoint(code);
        // The following fallback characters are for non-Unicode readers.
        var skip = p.current.unicode_skip;
        while (skip > 0 and p.pos < p.bytes.len) : (skip -= 1) {
            if (p.bytes[p.pos] == '\\' and p.pos + 3 < p.bytes.len and p.bytes[p.pos + 1] == '\'') {
                p.pos += 4;
            } else if (p.bytes[p.pos] == '{' or p.bytes[p.pos] == '}' or p.bytes[p.pos] == '\\') {
                break;
            } else {
                p.pos += 1;
            }
        }
    }

    fn emitByte(p: *Parser, byte: u8) core.ReadError!void {
        if (byte < 0x80) {
            var single = [1]u8{byte};
            try p.emitText(&single);
        } else {
            try p.emitCodepoint(cp1252ToUnicode(byte, p.code_page));
        }
    }

    fn emitCodepoint(p: *Parser, code: u21) core.ReadError!void {
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code, &encoded) catch return;
        try p.emitText(encoded[0..length]);
    }

    fn emitUtf8(p: *Parser, bytes: []const u8) core.ReadError!void {
        if (p.current.destination) return;
        try p.emitText(bytes);
    }

    fn emitText(p: *Parser, bytes: []const u8) core.ReadError!void {
        try p.ensureParagraph();
        try p.ensureStyles();
        try p.ctx.out.text(bytes);
    }

    fn ensureParagraph(p: *Parser) core.ReadError!void {
        if (p.paragraph == null) {
            p.paragraph = try p.ctx.out.beginParagraph();
            p.open_style = .{};
            p.style_count = 0;
        }
    }

    /// The flag-to-nesting conversion, canonical order, merging runs: the
    /// common prefix of open containers stays open, so bold text followed
    /// by bold-italic text shares one `strong` — the tree pandoc would
    /// build, from flags that never expressed it.
    fn ensureStyles(p: *Parser) core.ReadError!void {
        if (p.current.styleEql(p.open_style)) return;

        var wanted: [8]core.InlineTag = undefined;
        const wanted_count = styleTags(p.current, &wanted);
        var have: [8]core.InlineTag = undefined;
        const have_count = styleTags(p.open_style, &have);

        var common: u8 = 0;
        while (common < wanted_count and common < have_count and
            wanted[common] == have[common])
        {
            common += 1;
        }
        while (p.style_count > common) {
            p.style_count -= 1;
            p.ctx.out.endInline(p.style_tokens[p.style_count]);
        }
        while (p.style_count < wanted_count) {
            p.style_tokens[p.style_count] = try p.ctx.out.beginInline(wanted[p.style_count]);
            p.style_count += 1;
        }
        p.open_style = p.current;
    }

    fn closeParagraph(p: *Parser) core.ReadError!void {
        const token = p.paragraph orelse return;
        while (p.style_count > 0) {
            p.style_count -= 1;
            p.ctx.out.endInline(p.style_tokens[p.style_count]);
        }
        p.open_style = .{};
        p.ctx.out.endBlock(token);
        p.paragraph = null;
    }
};

/// The canonical nesting order, as a tag list.
fn styleTags(props: GroupState, out: *[8]core.InlineTag) u8 {
    var count: u8 = 0;
    const order = [_]struct { on: bool, tag: core.InlineTag }{
        .{ .on = props.strong, .tag = .strong },
        .{ .on = props.emphasis, .tag = .emphasis },
        .{ .on = props.strike, .tag = .strikethrough },
        .{ .on = props.superscript, .tag = .superscript },
        .{ .on = props.subscript, .tag = .subscript },
        .{ .on = props.small_caps, .tag = .small_caps },
        .{ .on = props.underline, .tag = .underline },
    };
    for (order) |entry| {
        if (!entry.on) continue;
        out[count] = entry.tag;
        count += 1;
    }
    return count;
}

fn isSkipDestination(word: []const u8) bool {
    for (skip_destinations) |destination| {
        if (std.mem.eql(u8, word, destination)) return true;
    }
    return false;
}

/// Windows-1252 (and the byte-identical range of most single-byte pages
/// zenfmt meets in practice) to Unicode. Other code pages fall back to
/// 1252, the overwhelmingly common case for RTF in the wild.
fn cp1252ToUnicode(byte: u8, code_page: u16) u21 {
    _ = code_page;
    if (byte < 0x80) return byte;
    const high = [_]u21{
        0x20ac, 0x81,   0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
        0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8d,   0x017d, 0x8f,
        0x90,   0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
        0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x9d,   0x017e, 0x0178,
    };
    if (byte >= 0x80 and byte <= 0x9f) return high[byte - 0x80];
    return byte;
}

// ------------------------------------------------------------- reports

fn notRtfReport() core.Report {
    return .{
        .severity = .err,
        .code = "rtf.not-rtf",
        .title = "NOT AN RTF DOCUMENT",
        .problem = "This file does not begin with `{\\rtf`, so it is not " ++
            "an RTF document.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Select the real format",
            .explanation = "If the format was misdetected, select the " ++
                "actual one with --from.",
        }},
    };
}

fn tooDeepReport() core.Report {
    return .{
        .severity = .err,
        .code = "rtf.groups-too-deep",
        .title = "RTF GROUPS NEST TOO DEEPLY",
        .problem = "This document nests RTF groups deeper than any real " ++
            "producer writes.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .exit_class = .limit,
        .directions = &.{.{
            .title = "Do not trust this file",
            .explanation = "Treat the file as suspect; re-export it from " ++
                "its producing application if it is a real document.",
        }},
    };
}

fn unknownWordNote() core.Report {
    return .{
        .severity = .note,
        .code = "rtf.unknown-control-words",
        .title = "UNKNOWN CONTROL WORDS SKIPPED",
        .problem = "This document uses RTF control words zenfmt does not " ++
            "recognize. RTF producers vary widely, and the reader is " ++
            "tolerant by design.",
        .consequence = "The unknown instructions were skipped; their text " ++
            "content, if any, was kept.",
        .loss = .degraded,
        .directions = &.{.{
            .title = "Check the output",
            .explanation = "Skim the output for anything missing or " ++
                "misformatted, and keep the source if details matter.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn convertRtf(arena: std.mem.Allocator, bytes: []const u8) !core.ast.Document {
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
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return doc;
}

test "paragraphs, toggles, and inheritance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try convertRtf(arena, "{\\rtf1\\ansi Plain {\\b bold {\\i both}} back\\par Second\\par}");
    try testing.expectEqual(@as(u32, 2), countTag(doc, .paragraph));
    try testing.expectEqual(@as(u32, 1), countInlineTag(doc, .strong));
    try testing.expectEqual(@as(u32, 1), countInlineTag(doc, .emphasis));
}

test "hex and unicode escapes decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try convertRtf(arena, "{\\rtf1 caf\\'e9 and \\u8212? dash\\par}");
    const text = doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "café") != null);
    try testing.expect(std.mem.indexOf(u8, text, "—") != null);
}

test "destinations and the font table never reach the output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try convertRtf(arena, "{\\rtf1{\\fonttbl{\\f0 Calibri;}}{\\*\\generator Riched20;}Visible\\par}");
    const text = doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "Calibri") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Riched20") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Visible") != null);
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
