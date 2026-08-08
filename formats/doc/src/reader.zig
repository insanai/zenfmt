//! The legacy Word reader (`.doc`, MS-DOC): FIB, piece table, and the
//! character stream, projected to paragraphs, headings, hard breaks, and
//! hyperlink fields. Heading styles resolve through the stylesheet and the
//! paragraph property chains in `styles.zig`; non-heading styles, tables,
//! and embedded objects are deliberate omissions with reports. The text
//! itself survives in full, in both the compressed (cp1252) and UTF-16
//! piece encodings.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const cfb = @import("zenfmt_cfb");
const styles_mod = @import("styles.zig");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.doc",
    .format = "doc",
    .extensions = &.{"doc"},
    .input = .seekable,
    .read = read,
});

const fib_ident: u16 = 0xA5EC;
const flag_encrypted: u16 = 0x0100;
const flag_which_table: u16 = 0x0200;
const flag_ext_char: u16 = 0x1000;
/// fcClx/lcbClx in FibRgFcLcb97: pair 33 of the fc/lcb table at offset 154.
const fc_clx_offset = 154 + 33 * 8;

fn read(ctx: *core.ReadContext) core.ReadError!void {
    const arena = ctx.gpa;
    var file = cfb.Cfb.open(arena, try ctx.inputBytes(), ctx.limits) catch |err| {
        try ctx.reports.add(notCompoundReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };
    const word_entry = file.find("WordDocument") orelse {
        try ctx.reports.add(notWordReport());
        return error.Malformed;
    };
    const word = file.readStream(arena, word_entry, ctx.limits) catch |err| {
        try ctx.reports.add(notWordReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };
    if (word.len < fc_clx_offset + 8 or readInt(u16, word[0..2]) != fib_ident) {
        try ctx.reports.add(notWordReport());
        return error.Malformed;
    }
    const flags = readInt(u16, word[10..12]);
    if (flags & flag_encrypted != 0) {
        try ctx.reports.add(encryptionReport());
        return error.Malformed;
    }

    const table_name = if (flags & flag_which_table != 0) "1Table" else "0Table";
    const table: []const u8 = blk: {
        const table_entry = file.find(table_name) orelse break :blk &.{};
        break :blk file.readStream(arena, table_entry, ctx.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break :blk &.{},
        };
    };
    const ccp_text = readInt(u32, word[76..80]);
    const pieces = try pieceTable(arena, word, table, flags);
    const resolver = try styles_mod.parse(arena, word, table);

    var sink: Sink = .{ .ctx = ctx, .arena = arena, .styles = resolver };
    defer sink.deinit();
    var remaining: u64 = ccp_text;
    for (pieces) |piece| {
        if (remaining == 0) break;
        const take = @min(piece.cp_len, remaining);
        remaining -= take;
        try sink.pieceText(word, piece, take);
    }
    try sink.finish();
}

const Piece = struct {
    cp_len: u64,
    fc: u64,
    compressed: bool,
};

/// The CLX in the table stream maps character positions to file offsets.
/// A document without one (never written by modern Word) falls back to
/// the contiguous fcMin..fcMac range of the FIB.
fn pieceTable(
    arena: std.mem.Allocator,
    word: []const u8,
    table: []const u8,
    flags: u16,
) core.ReadError![]const Piece {
    const fc_clx = readInt(u32, word[fc_clx_offset..][0..4]);
    const lcb_clx = readInt(u32, word[fc_clx_offset + 4 ..][0..4]);
    fallback: {
        if (lcb_clx == 0) break :fallback;
        if (@as(u64, fc_clx) + lcb_clx > table.len) break :fallback;
        const clx = table[fc_clx..][0..lcb_clx];
        return parseClx(arena, clx) catch break :fallback;
    }
    const fc_min = readInt(u32, word[24..28]);
    const fc_mac = readInt(u32, word[28..32]);
    if (fc_mac <= fc_min) return &.{};
    const unicode = flags & flag_ext_char != 0;
    const byte_len: u64 = fc_mac - fc_min;
    const piece = try arena.alloc(Piece, 1);
    piece[0] = .{
        .cp_len = if (unicode) byte_len / 2 else byte_len,
        .fc = fc_min,
        .compressed = !unicode,
    };
    return piece;
}

fn parseClx(arena: std.mem.Allocator, clx: []const u8) ![]const Piece {
    var pos: usize = 0;
    // Prc property blocks precede the Pcdt; skip them by declared length.
    while (pos < clx.len and clx[pos] == 0x01) {
        if (pos + 3 > clx.len) return error.Malformed;
        const cb = readInt(u16, clx[pos + 1 ..][0..2]);
        pos += 3 + cb;
    }
    if (pos + 5 > clx.len or clx[pos] != 0x02) return error.Malformed;
    const lcb = readInt(u32, clx[pos + 1 ..][0..4]);
    pos += 5;
    if (pos + lcb > clx.len or lcb < 4) return error.Malformed;
    const plc = clx[pos..][0..lcb];
    const count = (lcb - 4) / 12;
    if (count == 0) return &.{};

    const pieces = try arena.alloc(Piece, count);
    for (pieces, 0..) |*piece, i| {
        const cp_start = readInt(u32, plc[i * 4 ..][0..4]);
        const cp_end = readInt(u32, plc[(i + 1) * 4 ..][0..4]);
        if (cp_end < cp_start) return error.Malformed;
        const pcd = plc[(count + 1) * 4 + i * 8 ..][0..8];
        const fc_raw = readInt(u32, pcd[2..6]);
        const compressed = fc_raw & 0x40000000 != 0;
        const fc_field = fc_raw & 0x3FFFFFFF;
        piece.* = .{
            .cp_len = cp_end - cp_start,
            .fc = if (compressed) fc_field / 2 else fc_field,
            .compressed = compressed,
        };
    }
    return pieces;
}

// ------------------------------------------------------------------ sink

/// Field nesting is bounded; deeper fields lose their markers but keep
/// their result text.
const max_field_depth = 32;

const Sink = struct {
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    styles: styles_mod.Resolver = .empty,
    paragraph: ?core.builder.BlockToken = null,
    paragraph_fc: ?u64 = null,
    link: ?core.builder.InlineToken = null,
    buffer: std.ArrayList(u8) = .empty,
    instruction: std.ArrayList(u8) = .empty,
    field_in_instruction: [max_field_depth]bool = @splat(false),
    field_depth: u32 = 0,
    count_cell_marks: u32 = 0,
    count_page_breaks: u32 = 0,
    count_objects: u32 = 0,

    fn deinit(s: *Sink) void {
        s.buffer.deinit(s.arena);
        s.instruction.deinit(s.arena);
    }

    fn pieceText(s: *Sink, word: []const u8, piece: Piece, cp_count: u64) core.ReadError!void {
        const unit: u64 = if (piece.compressed) 1 else 2;
        if (piece.fc + cp_count * unit > word.len) return;
        const bytes = word[@intCast(piece.fc)..@intCast(piece.fc + cp_count * unit)];
        if (piece.compressed) {
            for (bytes, 0..) |byte, i| {
                try s.char(cfb.cp1252ToUnicode(byte), piece.fc + i);
            }
        } else {
            var i: usize = 0;
            while (i + 2 <= bytes.len) : (i += 2) {
                try s.char(readInt(u16, bytes[i..][0..2]), piece.fc + i);
            }
        }
    }

    fn char(s: *Sink, code: u21, fc: u64) core.ReadError!void {
        if (s.paragraph == null and s.paragraph_fc == null) s.paragraph_fc = fc;
        if (s.inInstruction()) return s.instructionChar(code);
        switch (code) {
            0x0D => try s.endParagraph(),
            0x07 => {
                // Cell and row marks: the table grid is an omission here.
                s.count_cell_marks += 1;
                try s.endParagraph();
            },
            0x0B => {
                try s.flush();
                if (s.paragraph != null) try s.ctx.out.hardBreak();
            },
            0x0C => {
                s.count_page_breaks += 1;
                try s.endParagraph();
            },
            0x09 => try s.buffer.append(s.arena, ' '),
            0x13 => try s.fieldBegin(),
            0x14 => try s.fieldSeparate(),
            0x15 => try s.fieldEnd(),
            0x01, 0x08 => s.count_objects += 1,
            0x1E => try s.buffer.append(s.arena, '-'),
            0x00, 0x02...0x06, 0x0A, 0x0E...0x12, 0x16...0x1D, 0x1F => {},
            else => {
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(code, &encoded) catch return;
                try s.buffer.appendSlice(s.arena, encoded[0..length]);
            },
        }
    }

    fn inInstruction(s: *const Sink) bool {
        if (s.field_depth == 0) return false;
        return s.field_in_instruction[@min(s.field_depth, max_field_depth) - 1];
    }

    fn instructionChar(s: *Sink, code: u21) core.ReadError!void {
        switch (code) {
            0x13 => try s.fieldBegin(),
            0x14 => try s.fieldSeparate(),
            0x15 => try s.fieldEnd(),
            else => if (s.field_depth == 1 and code >= 0x20 and code < 0x80) {
                try s.instruction.append(s.arena, @intCast(code));
            },
        }
    }

    fn fieldBegin(s: *Sink) core.ReadError!void {
        if (s.field_depth < max_field_depth) {
            s.field_in_instruction[s.field_depth] = true;
        }
        s.field_depth += 1;
        if (s.field_depth == 1) s.instruction.clearRetainingCapacity();
    }

    fn fieldSeparate(s: *Sink) core.ReadError!void {
        if (s.field_depth == 0 or s.field_depth > max_field_depth) return;
        s.field_in_instruction[s.field_depth - 1] = false;
        if (s.field_depth != 1) return;
        if (parseHyperlink(s.instruction.items)) |target| {
            try s.flush();
            try s.ensureParagraph();
            const url = try s.arena.dupe(u8, target);
            s.link = try s.ctx.out.beginLink(url, "");
        }
    }

    fn fieldEnd(s: *Sink) core.ReadError!void {
        if (s.field_depth == 0) return;
        s.field_depth -= 1;
        if (s.field_depth == 0) {
            if (s.link) |token| {
                try s.flush();
                s.ctx.out.endInline(token);
                s.link = null;
            }
        }
    }

    /// Opens the pending block: a heading when the paragraph's style
    /// resolves to one, a plain paragraph otherwise. Headings carry a
    /// provenance facet naming the WordDocument stream position, and any
    /// paragraph whose style resolves to a named non-default style carries
    /// a style facet (ZDS 0013, Sparse Facets).
    fn ensureParagraph(s: *Sink) core.ReadError!void {
        if (s.paragraph != null) return;
        const fc = s.paragraph_fc orelse 0;
        const level = s.styles.headingLevel(fc);
        const token = if (level > 0)
            try s.ctx.out.beginHeading(@min(level, 6))
        else
            try s.ctx.out.beginParagraph();
        s.paragraph = token;
        if (s.styles.styleName(fc)) |name| {
            try s.ctx.out.attachStyle(token, .{ .name = name });
        }
        if (level > 0) {
            try s.ctx.out.attachProvenance(token, .{
                .plugin = "ai.insan.zenfmt.doc",
                .member = "WordDocument",
                .byte_start = fc,
                .confidence = .exact,
            });
        }
    }

    fn flush(s: *Sink) core.ReadError!void {
        if (s.buffer.items.len == 0) return;
        try s.ensureParagraph();
        try s.ctx.out.text(s.buffer.items);
        s.buffer.clearRetainingCapacity();
    }

    fn endParagraph(s: *Sink) core.ReadError!void {
        try s.flush();
        if (s.link) |token| {
            s.ctx.out.endInline(token);
            s.link = null;
        }
        if (s.paragraph) |token| {
            s.ctx.out.endBlock(token);
            s.paragraph = null;
        }
        s.paragraph_fc = null;
    }

    fn finish(s: *Sink) core.ReadError!void {
        try s.endParagraph();
        if (!s.styles.active()) try s.ctx.reports.add(stylesNote());
        if (s.count_cell_marks > 0) try s.ctx.reports.add(tablesNote(s.count_cell_marks));
        if (s.count_objects > 0) try s.ctx.reports.add(objectsNote(s.count_objects));
        if (s.count_page_breaks > 0) try s.ctx.reports.add(pageBreaksNote(s.count_page_breaks));
    }
};

/// ` HYPERLINK "https://..." \o "tip" ` → the first non-switch token;
/// `\l bookmark` targets become fragment links.
fn parseHyperlink(instruction: []const u8) ?[]const u8 {
    var rest = std.mem.trim(u8, instruction, " ");
    if (!std.mem.startsWith(u8, rest, "HYPERLINK")) return null;
    rest = rest["HYPERLINK".len..];
    var fragment = false;
    var iterations: u32 = 0;
    while (iterations < 16) : (iterations += 1) {
        rest = std.mem.trimStart(u8, rest, " ");
        if (rest.len == 0) return null;
        if (rest[0] == '\\') {
            fragment = rest.len > 1 and (rest[1] == 'l' or rest[1] == 'L');
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
            rest = rest[end..];
            if (!fragment) continue;
            rest = std.mem.trimStart(u8, rest, " ");
        }
        if (rest.len == 0) return null;
        const target = if (rest[0] == '"') blk: {
            const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse rest.len - 1;
            break :blk rest[1 .. 1 + end];
        } else blk: {
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            break :blk rest[0..end];
        };
        if (target.len == 0) return null;
        return target;
    }
    return null;
}

fn readInt(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return std.mem.readInt(T, bytes, .little);
}

// ------------------------------------------------------------- reports

fn notCompoundReport() core.Report {
    return .{
        .severity = .err,
        .code = "doc.not-a-compound-file",
        .title = "NOT A READABLE WORD FILE",
        .problem = "This file is not a compound (OLE) file zenfmt can " ++
            "read, or it trips a container safety limit.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Check the file",
            .explanation = "Open the file in Word or LibreOffice to verify " ++
                "it is intact, and check the detected format.",
        }},
    };
}

fn notWordReport() core.Report {
    return .{
        .severity = .err,
        .code = "doc.missing-word-stream",
        .title = "THE WORD DOCUMENT STREAM IS MISSING",
        .problem = "The compound file opens but has no readable " ++
            "WordDocument stream, so it is not a Word document.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the document from Word or LibreOffice " ++
                "and convert the fresh copy, or export it as .docx.",
        }},
    };
}

fn encryptionReport() core.Report {
    return .{
        .severity = .err,
        .code = "doc.encryption-refused",
        .title = "THE DOCUMENT IS ENCRYPTED",
        .problem = "The FIB marks this document as encrypted, and zenfmt " ++
            "never attempts decryption.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Decrypt it first",
            .explanation = "Open the document in Word with its password, " ++
                "save an unencrypted copy, and convert that.",
        }},
    };
}

fn stylesNote() core.Report {
    return .{
        .severity = .note,
        .code = "doc.styles-omitted",
        .title = "PARAGRAPH STYLES COULD NOT BE RESOLVED",
        .problem = "This document carries no readable stylesheet, so " ++
            "heading styles cannot be identified.",
        .consequence = "Headings appear as plain paragraphs in the output.",
        .loss = .structural,
        .directions = &.{.{
            .title = "Convert via .docx",
            .explanation = "Open the file in Word and save as .docx; the " ++
                "DOCX reader resolves heading styles in full.",
        }},
    };
}

fn tablesNote(count: u32) core.Report {
    return .{
        .severity = .note,
        .code = "doc.tables-flattened",
        .title = "TABLE CELLS BECAME PARAGRAPHS",
        .problem = "The document places text in tables, and this reader " ++
            "does not reconstruct the legacy table grid.",
        .consequence = "Each table cell appears as its own paragraph.",
        .loss = .structural,
        .count = count,
        .directions = &.{.{
            .title = "Convert via .docx",
            .explanation = "Open the file in Word and save as .docx; the " ++
                "DOCX reader keeps tables as tables.",
        }},
    };
}

fn objectsNote(count: u32) core.Report {
    return .{
        .severity = .note,
        .code = "doc.embedded-objects-dropped",
        .title = "EMBEDDED PICTURES AND OBJECTS DROPPED",
        .problem = "The text stream marks embedded pictures or OLE " ++
            "objects, which this reader does not extract.",
        .consequence = "Those objects are absent from the output.",
        .loss = .dropped,
        .count = count,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "The objects exist only in the source file; " ++
                "keep it alongside the Markdown.",
        }},
    };
}

fn pageBreaksNote(count: u32) core.Report {
    return .{
        .severity = .note,
        .code = "doc.page-breaks-dropped",
        .title = "PAGE BREAKS HAVE NO MARKDOWN FORM",
        .problem = "The document contains explicit page breaks, and " ++
            "Markdown has no page model.",
        .consequence = "The text flows continuously in the output.",
        .loss = .dropped,
        .count = count,
        .directions = &.{.{
            .title = "Nothing to do",
            .explanation = "This is inherent to the target format.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const TestDoc = struct {
    word: [1024]u8,
    table: std.ArrayList(u8),

    fn init() TestDoc {
        var doc: TestDoc = .{ .word = @splat(0), .table = .empty };
        std.mem.writeInt(u16, doc.word[0..2], fib_ident, .little);
        std.mem.writeInt(u16, doc.word[2..4], 0x00C1, .little);
        std.mem.writeInt(u16, doc.word[10..12], flag_which_table, .little);
        return doc;
    }
};

fn buildTestDoc(
    arena: std.mem.Allocator,
    pieces: []const struct { text: []const u8, unicode: bool },
) ![]const u8 {
    var doc = TestDoc.init();
    // Piece texts land at 512-aligned offsets in the WordDocument stream.
    var cps: std.ArrayList(u32) = .empty;
    var pcds: std.ArrayList(u8) = .empty;
    var cp: u32 = 0;
    var fc: u32 = 512;
    try cps.append(arena, 0);
    for (pieces) |piece| {
        var piece_bytes: std.ArrayList(u8) = .empty;
        if (piece.unicode) {
            var i: usize = 0;
            while (i < piece.text.len) {
                const len = std.unicode.utf8ByteSequenceLength(piece.text[i]) catch 1;
                const code = std.unicode.utf8Decode(piece.text[i..][0..len]) catch 0xFFFD;
                var unit: [2]u8 = undefined;
                std.mem.writeInt(u16, &unit, @intCast(code), .little);
                try piece_bytes.appendSlice(arena, &unit);
                i += len;
            }
        } else {
            try piece_bytes.appendSlice(arena, piece.text);
        }
        @memcpy(doc.word[fc..][0..piece_bytes.items.len], piece_bytes.items);
        const cp_count: u32 = @intCast(if (piece.unicode)
            piece_bytes.items.len / 2
        else
            piece_bytes.items.len);
        cp += cp_count;
        try cps.append(arena, cp);
        var pcd: [8]u8 = @splat(0);
        const fc_raw: u32 = if (piece.unicode) fc else 0x40000000 | (fc * 2);
        std.mem.writeInt(u32, pcd[2..6], fc_raw, .little);
        try pcds.appendSlice(arena, &pcd);
        fc += @intCast((piece_bytes.items.len + 63) / 64 * 64);
    }
    std.mem.writeInt(u32, doc.word[76..80], cp, .little);

    // The CLX goes at offset 32 of the table stream.
    try doc.table.appendNTimes(arena, 0, 32);
    try doc.table.append(arena, 0x02);
    const lcb: u32 = @intCast(cps.items.len * 4 + pcds.items.len);
    var lcb_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &lcb_bytes, lcb, .little);
    try doc.table.appendSlice(arena, &lcb_bytes);
    for (cps.items) |value| {
        var value_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &value_bytes, value, .little);
        try doc.table.appendSlice(arena, &value_bytes);
    }
    try doc.table.appendSlice(arena, pcds.items);
    std.mem.writeInt(u32, doc.word[fc_clx_offset..][0..4], 32, .little);
    // The CLX length covers the Pcdt marker and size prefix too.
    std.mem.writeInt(u32, doc.word[fc_clx_offset + 4 ..][0..4], lcb + 5, .little);

    return cfb.buildFile(arena, &.{
        .{ .name = "WordDocument", .data = &doc.word },
        .{ .name = "1Table", .data = doc.table.items },
    });
}

fn convertDoc(arena: std.mem.Allocator, bytes: []const u8) !core.ast.Document {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "test.doc",
        .reports = reports,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return doc;
}

test "cp1252 and unicode pieces become paragraphs in cp order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try buildTestDoc(arena, &.{
        .{ .text = "Caf\xe9 first.\r", .unicode = false },
        .{ .text = "Zig \u{2014} second.\r", .unicode = true },
    });
    const doc = try convertDoc(arena, bytes);

    var paragraphs: u32 = 0;
    for (doc.store.blocks.items(.tag)) |tag| {
        if (tag == .paragraph) paragraphs += 1;
    }
    try testing.expectEqual(@as(u32, 2), paragraphs);
    try testing.expect(std.mem.indexOf(u8, doc.store.text.items, "Café") != null);
    try testing.expect(std.mem.indexOf(u8, doc.store.text.items, "first.") != null);
    try testing.expect(std.mem.indexOf(u8, doc.store.text.items, "—") != null);
    try testing.expect(std.mem.indexOf(u8, doc.store.text.items, "second.") != null);
}

test "hyperlink fields become links with display text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try buildTestDoc(arena, &.{.{
        .text = "See \x13HYPERLINK \"https://ziglang.org/\" \x14the Zig site\x15 today.\r",
        .unicode = false,
    }});
    const doc = try convertDoc(arena, bytes);

    var links: u32 = 0;
    for (doc.store.inlines.items(.tag)) |tag| {
        if (tag == .link) links += 1;
    }
    try testing.expectEqual(@as(u32, 1), links);
    try testing.expect(std.mem.indexOf(u8, doc.store.text.items, "https://ziglang.org/") != null);
    try testing.expect(std.mem.indexOf(u8, doc.store.text.items, "site") != null);
    try testing.expect(std.mem.indexOf(u8, doc.store.text.items, "HYPERLINK") == null);
}

/// A document with a real style chain: STSH naming style 1 "heading 1"
/// (sti 1), a PlcfBtePapx pointing at one FKP page, and a PAPX giving the
/// first paragraph istd 1. The second paragraph keeps the default style.
fn buildStyledDoc(arena: std.mem.Allocator) ![]const u8 {
    var word: [2048]u8 = @splat(0);
    std.mem.writeInt(u16, word[0..2], fib_ident, .little);
    std.mem.writeInt(u16, word[10..12], flag_which_table, .little);
    const text = "Title\rBody text.\r";
    @memcpy(word[512..][0..text.len], text);
    std.mem.writeInt(u32, word[76..80], text.len, .little);

    // FKP page 3: boundaries 512/518/529, paragraph 0 has a PAPX with
    // istd 1, paragraph 1 defers to the default style.
    const fkp = word[1536..2048];
    std.mem.writeInt(u32, fkp[0..4], 512, .little);
    std.mem.writeInt(u32, fkp[4..8], 518, .little);
    std.mem.writeInt(u32, fkp[8..12], 529, .little);
    fkp[12] = 64; // BxPap of paragraph 0: PAPX at word offset 128.
    fkp[25] = 0; // BxPap of paragraph 1: no PAPX.
    fkp[128] = 1; // PapxInFkp cb; the istd follows directly.
    std.mem.writeInt(u16, fkp[129..131], 1, .little);
    fkp[511] = 2; // cpara.

    var table: std.ArrayList(u8) = .empty;
    try table.appendNTimes(arena, 0, 32);
    // CLX: one compressed piece at byte fc 512 holding all 17 characters.
    try table.append(arena, 0x02);
    var scratch: [4]u8 = undefined;
    std.mem.writeInt(u32, &scratch, 16, .little);
    try table.appendSlice(arena, &scratch);
    std.mem.writeInt(u32, &scratch, 0, .little);
    try table.appendSlice(arena, &scratch);
    std.mem.writeInt(u32, &scratch, text.len, .little);
    try table.appendSlice(arena, &scratch);
    var pcd: [8]u8 = @splat(0);
    std.mem.writeInt(u32, pcd[2..6], 0x40000000 | (512 * 2), .little);
    try table.appendSlice(arena, &pcd);
    std.mem.writeInt(u32, word[fc_clx_offset..][0..4], 32, .little);
    std.mem.writeInt(u32, word[fc_clx_offset + 4 ..][0..4], 16 + 5, .little);

    // STSH at table offset 64: style 0 empty, style 1 named "heading 1".
    try table.appendNTimes(arena, 0, 64 - table.items.len);
    var stsh: [40]u8 = @splat(0);
    std.mem.writeInt(u16, stsh[0..2], 4, .little); // cbStshi
    std.mem.writeInt(u16, stsh[2..4], 2, .little); // cstd
    std.mem.writeInt(u16, stsh[4..6], 10, .little); // cbSTDBase
    // LPStd 0 at 6: cb 0. LPStd 1 at 8: cb 30, sti 1, Xst "heading 1".
    std.mem.writeInt(u16, stsh[8..10], 30, .little);
    std.mem.writeInt(u16, stsh[10..12], 1, .little);
    std.mem.writeInt(u16, stsh[20..22], 9, .little);
    for ("heading 1", 0..) |byte, i| {
        std.mem.writeInt(u16, stsh[22 + i * 2 ..][0..2], byte, .little);
    }
    try table.appendSlice(arena, &stsh);
    std.mem.writeInt(u32, word[162..166], 64, .little);
    std.mem.writeInt(u32, word[166..170], 40, .little);

    // PlcfBtePapx at table offset 112: fcs 512..529, page number 3.
    try table.appendNTimes(arena, 0, 112 - table.items.len);
    std.mem.writeInt(u32, &scratch, 512, .little);
    try table.appendSlice(arena, &scratch);
    std.mem.writeInt(u32, &scratch, 529, .little);
    try table.appendSlice(arena, &scratch);
    std.mem.writeInt(u32, &scratch, 3, .little);
    try table.appendSlice(arena, &scratch);
    std.mem.writeInt(u32, word[258..262], 112, .little);
    std.mem.writeInt(u32, word[262..266], 12, .little);

    return cfb.buildFile(arena, &.{
        .{ .name = "WordDocument", .data = &word },
        .{ .name = "1Table", .data = table.items },
    });
}

test "a styled heading carries style and provenance facets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try buildStyledDoc(arena);
    const doc = try convertDoc(arena, bytes);

    const tags = doc.store.blocks.items(.tag);
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqual(core.BlockTag.heading, tags[0]);
    try testing.expectEqual(core.BlockTag.paragraph, tags[1]);

    const entity = doc.blockEntity(@enumFromInt(0)).?;
    const style = doc.styleOf(entity).?;
    try testing.expectEqualStrings("heading 1", doc.store.textSlice(style.name));
    const provenance = doc.provenanceOf(entity).?;
    try testing.expectEqualStrings("WordDocument", doc.store.textSlice(provenance.member));
    try testing.expectEqual(@as(u64, 512), provenance.byte_start);
    try testing.expectEqual(core.facets.Confidence.exact, provenance.confidence);

    // The default-styled paragraph carries nothing: facets are sparse.
    try testing.expectEqual(@as(?core.EntityId, null), doc.blockEntity(@enumFromInt(1)));
}

test "an encrypted document is refused with its own code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = TestDoc.init();
    std.mem.writeInt(u16, doc.word[10..12], flag_which_table | flag_encrypted, .little);
    const bytes = try cfb.buildFile(arena, &.{
        .{ .name = "WordDocument", .data = &doc.word },
    });

    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "locked.doc",
        .reports = reports,
        .limits = .{},
    };
    try testing.expectError(error.Malformed, read(&ctx));
    try testing.expectEqual(@as(usize, 1), reports.entries.items.len);
    try testing.expectEqualStrings(
        "doc.encryption-refused",
        reports.entries.items[0].report.code,
    );
}
