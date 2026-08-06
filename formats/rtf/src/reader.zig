//! The RTF reader (ZDS 0002, The other formats; ZDS 0004).
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
//!
//! Paragraph structure — tables from `\trowd`/`\cell`/`\row`, lists from
//! `\ls`/`\ilvl`/`{\*\pn}`, headings from `\outlinelevel` — lives in
//! `structure.zig`; this file owns the lexer, character state, fields,
//! and footnote capture.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const structure = @import("structure.zig");
const reports_mod = @import("reports.zig");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.rtf",
    .format = "rtf",
    .extensions = &.{"rtf"},
    .read = read,
});

/// What text inside the current group means.
pub const Capture = enum {
    /// Document content (or nothing, when the group is a destination).
    none,
    /// Field instruction text, collected for `HYPERLINK` parsing.
    instruction,
    /// List-item marker fallback text, collected for the digit heuristic.
    list_marker,
};

pub const GroupState = struct {
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
    capture: Capture = .none,

    fn styleEql(a: GroupState, b: GroupState) bool {
        return a.strong == b.strong and a.emphasis == b.emphasis and
            a.strike == b.strike and a.superscript == b.superscript and
            a.subscript == b.subscript and a.small_caps == b.small_caps and
            a.underline == b.underline;
    }
};

/// Paragraph properties, reset by `\pard`, applied when the paragraph's
/// first content opens its block.
pub const ParaProps = struct {
    in_table: bool = false,
    nested_table: bool = false,
    list: bool = false,
    ilvl: u8 = 0,
    list_kind: ListKind = .unknown,
    /// `\outlinelevelN`: 0-based heading level from the producing word
    /// processor's own outline, the most reliable heading signal RTF has.
    outline: ?u8 = null,

    pub const ListKind = enum { unknown, bullet, ordered };
};

pub const TableState = struct {
    token: ?core.builder.BlockToken = null,
    head: ?core.builder.BlockToken = null,
    body: ?core.builder.BlockToken = null,
    row: ?core.builder.BlockToken = null,
    cell: ?core.builder.BlockToken = null,
};

pub const ListLevel = struct {
    level: u8,
    ordered: bool,
    list_token: core.builder.BlockToken,
    item_token: ?core.builder.BlockToken,
};

const NoteCapture = struct {
    note: u32,
    body: []const u8,
};

pub fn read(ctx: *core.ReadContext) core.ReadError!void {
    const bytes = ctx.input.bytes;
    if (!std.mem.startsWith(u8, bytes, "{\\rtf")) {
        try ctx.reports.add(reports_mod.notRtfReport());
        return error.Malformed;
    }
    var parser: Parser = .{ .ctx = ctx, .bytes = bytes };
    defer parser.deinit();
    try parser.run();
    try parser.finish();

    // Footnote bodies were captured as raw RTF at their reference sites;
    // note bodies live after the document body, so replay them now.
    for (parser.notes.items) |entry| {
        var sub: Parser = .{
            .ctx = ctx,
            .bytes = entry.body,
            .code_page = parser.code_page,
            .in_note = true,
        };
        defer sub.deinit();
        ctx.out.beginNoteBody(entry.note);
        try sub.run();
        try sub.finish();
        ctx.out.endNoteBody(entry.note);
        parser.count_images += sub.count_images;
        parser.count_objects += sub.count_objects;
        parser.count_nested_tables += sub.count_nested_tables;
    }

    try parser.finishReports();
}

/// Destinations whose content never reaches the document, even without a
/// `\*` marker.
const skip_destinations = [_][]const u8{
    "fonttbl",   "colortbl", "stylesheet", "info",           "header",
    "footer",    "headerl",  "headerr",    "headerf",        "footerl",
    "footerr",   "footerf",  "themedata",  "listtable",      "listoverridetable",
    "generator", "xmlnstbl", "revtbl",     "nesttableprops",
};

pub const Parser = struct {
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

    // Paragraph structure (structure.zig).
    para: ParaProps = .{},
    table: TableState = .{},
    lists: [10]ListLevel = undefined,
    list_depth: u32 = 0,
    cell_list_base: u32 = 0,
    row_def_cells: u32 = 0,
    row_header: bool = false,
    nested_table_noted: bool = false,

    // Fields ({\field{\*\fldinst HYPERLINK ...}{\fldrslt ...}}).
    field_depth: ?u32 = null,
    field_link: ?core.builder.InlineToken = null,
    instr_buffer: std.ArrayList(u8) = .empty,
    marker_buffer: std.ArrayList(u8) = .empty,

    // Footnotes, captured as raw RTF and replayed after the body.
    notes: std.ArrayList(NoteCapture) = .empty,
    in_note: bool = false,

    // Deliberate-omission counters, reported once at the end.
    count_images: u32 = 0,
    count_objects: u32 = 0,
    count_nested_tables: u32 = 0,

    pub fn deinit(p: *Parser) void {
        p.instr_buffer.deinit(p.ctx.gpa);
        p.marker_buffer.deinit(p.ctx.gpa);
        p.notes.deinit(p.ctx.gpa);
    }

    pub fn run(p: *Parser) core.ReadError!void {
        while (p.pos < p.bytes.len) {
            const byte = p.bytes[p.pos];
            switch (byte) {
                '{' => {
                    if (p.depth >= p.stack.len) {
                        try p.ctx.reports.add(reports_mod.tooDeepReport());
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
                    try p.onGroupClose();
                },
                '\\' => try p.controlWord(),
                '\r', '\n' => p.pos += 1,
                else => {
                    try p.emitByte(byte);
                    p.pos += 1;
                },
            }
        }
    }

    /// Closes everything the document left open, in nesting order.
    pub fn finish(p: *Parser) core.ReadError!void {
        try p.closeParagraph();
        try structure.closeAll(p);
    }

    fn onGroupClose(p: *Parser) core.ReadError!void {
        const field_depth = p.field_depth orelse return;
        if (p.depth >= field_depth) return;
        // The whole {\field ...} group closed.
        if (p.field_link) |token| {
            p.closeAllStyles();
            p.ctx.out.endInline(token);
            p.field_link = null;
        }
        p.field_depth = null;
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
                '\\', '{', '}' => try p.emitByte(first),
                '~' => try p.emitByte(' '),
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
            const capture = p.current.capture;
            const skip = p.current.unicode_skip;
            p.current = .{ .destination = destination, .capture = capture, .unicode_skip = skip };
        } else if (std.mem.eql(u8, word, "par")) {
            if (!p.current.destination) try p.closeParagraph();
        } else if (std.mem.eql(u8, word, "line")) {
            if (!p.current.destination and p.paragraph != null) try p.ctx.out.hardBreak();
        } else if (std.mem.eql(u8, word, "tab")) {
            try p.emitByte(' ');
        } else if (try p.applyStructureWord(word, value)) {
            // Handled by the paragraph-structure vocabulary.
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
        } else if (std.mem.eql(u8, word, "pict")) {
            p.count_images += 1;
            p.current.destination = true;
        } else if (std.mem.eql(u8, word, "object")) {
            p.count_objects += 1;
            p.current.destination = true;
        } else if (std.mem.eql(u8, word, "footnote")) {
            try p.onFootnote();
        } else if (std.mem.eql(u8, word, "field")) {
            p.field_depth = p.depth;
        } else if (std.mem.eql(u8, word, "fldinst")) {
            p.current.destination = true;
            p.current.capture = .instruction;
            p.instr_buffer.clearRetainingCapacity();
        } else if (std.mem.eql(u8, word, "fldrslt")) {
            p.current.destination = false;
            p.current.capture = .none;
            try structure.onFieldResult(p);
        } else if (isSkipDestination(word)) {
            p.current.destination = true;
        } else if (std.mem.eql(u8, word, "rtf") or std.mem.eql(u8, word, "ansi") or
            std.mem.eql(u8, word, "deff") or std.mem.eql(u8, word, "sectd") or
            std.mem.eql(u8, word, "f") or std.mem.eql(u8, word, "fs") or
            std.mem.eql(u8, word, "cf") or std.mem.eql(u8, word, "cb") or
            std.mem.eql(u8, word, "sa") or std.mem.eql(u8, word, "sb") or
            std.mem.eql(u8, word, "sl") or std.mem.eql(u8, word, "qc") or
            std.mem.eql(u8, word, "ql") or std.mem.eql(u8, word, "qr") or
            std.mem.eql(u8, word, "qj") or std.mem.eql(u8, word, "fi") or
            std.mem.eql(u8, word, "li") or std.mem.eql(u8, word, "ri") or
            std.mem.eql(u8, word, "lang") or std.mem.eql(u8, word, "noproof") or
            std.mem.eql(u8, word, "kerning") or std.mem.eql(u8, word, "s") or
            std.mem.eql(u8, word, "cs") or std.mem.eql(u8, word, "chftn") or
            std.mem.eql(u8, word, "widctlpar") or std.mem.eql(u8, word, "nowidctlpar") or
            std.mem.eql(u8, word, "adjustright") or std.mem.eql(u8, word, "cgrid") or
            std.mem.eql(u8, word, "slmult") or std.mem.eql(u8, word, "lin") or
            std.mem.eql(u8, word, "rin") or std.mem.eql(u8, word, "aspalpha") or
            std.mem.eql(u8, word, "aspnum") or std.mem.eql(u8, word, "faauto"))
        {
            // Formatting and layout the tree does not represent.
        } else if (word.len >= 2 and (std.mem.startsWith(u8, word, "tr") or
            std.mem.startsWith(u8, word, "cl") or std.mem.startsWith(u8, word, "pn") or
            std.mem.startsWith(u8, word, "ts")))
        {
            // Row, cell, numbering, and table-style formatting detail; the
            // structural members of these families were handled above.
        } else {
            // Unknown control word: skipped, and said once.
            if (!p.unknown_words_noted) {
                p.unknown_words_noted = true;
                try p.ctx.reports.add(reports_mod.unknownWordNote());
            }
        }
    }

    /// The table, list, and heading vocabulary. Returns true when `word`
    /// was one of them.
    fn applyStructureWord(p: *Parser, word: []const u8, value: ?i32) core.ReadError!bool {
        if (std.mem.eql(u8, word, "pard")) {
            p.para = .{};
        } else if (std.mem.eql(u8, word, "intbl")) {
            p.para.in_table = true;
        } else if (std.mem.eql(u8, word, "itap")) {
            const depth_value = value orelse 1;
            p.para.in_table = depth_value > 0;
            p.para.nested_table = depth_value > 1;
        } else if (std.mem.eql(u8, word, "trowd")) {
            p.row_def_cells = 0;
            p.row_header = false;
        } else if (std.mem.eql(u8, word, "cellx")) {
            p.row_def_cells += 1;
        } else if (std.mem.eql(u8, word, "trhdr")) {
            p.row_header = true;
        } else if (std.mem.eql(u8, word, "cell")) {
            if (!p.current.destination) try structure.onCell(p);
        } else if (std.mem.eql(u8, word, "row")) {
            if (!p.current.destination) try structure.onRow(p);
        } else if (std.mem.eql(u8, word, "nestcell") or std.mem.eql(u8, word, "nestrow")) {
            p.count_nested_tables += 1;
            if (std.mem.eql(u8, word, "nestcell")) try p.emitByte(' ');
        } else if (std.mem.eql(u8, word, "ls")) {
            p.para.list = true;
        } else if (std.mem.eql(u8, word, "ilvl")) {
            p.para.ilvl = @intCast(@max(0, @min(value orelse 0, 8)));
        } else if (std.mem.eql(u8, word, "listtext") or std.mem.eql(u8, word, "pntext")) {
            p.current.destination = true;
            p.current.capture = .list_marker;
            p.marker_buffer.clearRetainingCapacity();
        } else if (std.mem.eql(u8, word, "pn")) {
            p.para.list = true;
        } else if (std.mem.eql(u8, word, "pnlvlblt")) {
            p.para.list = true;
            p.para.list_kind = .bullet;
        } else if (std.mem.eql(u8, word, "pnlvlbody") or std.mem.eql(u8, word, "pndec")) {
            p.para.list = true;
            p.para.list_kind = .ordered;
        } else if (std.mem.eql(u8, word, "outlinelevel")) {
            p.para.outline = @intCast(@max(0, @min(value orelse 0, 8)));
        } else {
            return false;
        }
        return true;
    }

    /// `{\footnote ...}`: declare the note, reference it here, and capture
    /// the group's raw bytes for the post-body replay.
    fn onFootnote(p: *Parser) core.ReadError!void {
        if (p.in_note or p.current.destination) {
            // Notes inside notes are beyond any real producer.
            p.current.destination = true;
            return;
        }
        const end = p.matchGroupEnd() orelse {
            p.current.destination = true;
            return;
        };
        const note = try p.ctx.out.declareNote();
        try structure.ensureParagraph(p);
        try p.ctx.out.noteReference(note);
        try p.notes.append(p.ctx.gpa, .{ .note = note, .body = p.bytes[p.pos..end] });
        p.pos = end;
    }

    /// Index of the `}` closing the current group, or null when the file
    /// is truncated. Bounded by the input length.
    fn matchGroupEnd(p: *Parser) ?usize {
        var balance: u32 = 1;
        var i = p.pos;
        while (i < p.bytes.len) {
            switch (p.bytes[i]) {
                '\\' => i += 2,
                '{' => {
                    balance += 1;
                    i += 1;
                },
                '}' => {
                    balance -= 1;
                    if (balance == 0) return i;
                    i += 1;
                },
                else => i += 1,
            }
        }
        return null;
    }

    fn hexEscape(p: *Parser) core.ReadError!void {
        if (p.pos + 2 > p.bytes.len) return;
        const hex = p.bytes[p.pos..][0..2];
        p.pos += 2;
        const byte = std.fmt.parseInt(u8, hex, 16) catch return;
        try p.emitCodepoint(cp1252ToUnicode(byte, p.code_page));
    }

    fn unicodeEscape(p: *Parser, value: i32) core.ReadError!void {
        // Negative values are the 16-bit two's-complement convention.
        const code: u21 = if (value < 0)
            @intCast(@as(i64, value) + 65536)
        else
            @intCast(@min(value, 0x10ffff));
        try p.emitCodepoint(code);
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
        try p.emitText(bytes);
    }

    /// All text funnels through here: captures first, then destination
    /// suppression, then document content.
    fn emitText(p: *Parser, bytes: []const u8) core.ReadError!void {
        switch (p.current.capture) {
            .instruction => return p.instr_buffer.appendSlice(p.ctx.gpa, bytes),
            .list_marker => return p.marker_buffer.appendSlice(p.ctx.gpa, bytes),
            .none => {},
        }
        if (p.current.destination) return;
        try structure.ensureParagraph(p);
        try p.ensureStyles();
        try p.ctx.out.text(bytes);
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

    pub fn closeAllStyles(p: *Parser) void {
        while (p.style_count > 0) {
            p.style_count -= 1;
            p.ctx.out.endInline(p.style_tokens[p.style_count]);
        }
        p.open_style = .{};
    }

    pub fn closeParagraph(p: *Parser) core.ReadError!void {
        const token = p.paragraph orelse return;
        p.closeAllStyles();
        if (p.field_link) |link| {
            p.ctx.out.endInline(link);
            p.field_link = null;
        }
        p.ctx.out.endBlock(token);
        p.paragraph = null;
    }

    fn finishReports(p: *Parser) core.ReadError!void {
        if (p.count_images > 0) try p.ctx.reports.add(reports_mod.imagesDroppedNote());
        if (p.count_objects > 0) try p.ctx.reports.add(reports_mod.objectsDroppedNote());
        if (p.count_nested_tables > 0) {
            try p.ctx.reports.add(reports_mod.nestedTableNote());
        }
    }
};

/// The canonical nesting order, as a tag list.
pub fn styleTags(props: GroupState, out: *[8]core.InlineTag) u8 {
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
pub fn cp1252ToUnicode(byte: u8, code_page: u16) u21 {
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
