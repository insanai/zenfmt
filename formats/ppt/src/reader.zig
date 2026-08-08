//! The legacy PowerPoint reader (`.ppt`, MS-PPT): a bounded, iterative
//! walk of the PowerPoint Document record tree, harvesting text atoms in
//! stream order. A `TextHeaderAtom` classifies the run that follows:
//! titles become headings, notes text is wrapped in a `container` with
//! class `notes`, everything else becomes paragraphs. Like the PPTX
//! reader, the projection warning is unconditional — a slide deck loses
//! the most in this projection.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const cfb = @import("zenfmt_cfb");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.ppt",
    .format = "ppt",
    .extensions = &.{ "ppt", "pps", "pot" },
    .input = .seekable,
    .read = read,
});

const rec_text_header: u16 = 0x0F9F;
const rec_text_chars: u16 = 0x0FA0;
const rec_text_bytes: u16 = 0x0FA8;
const rec_crypt_session: u16 = 0x2F14;

const TextKind = enum { title, body, notes, other };

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
    const entry = file.find("PowerPoint Document") orelse {
        try ctx.reports.add(notPowerPointReport());
        return error.Malformed;
    };
    const stream = file.readStream(arena, entry, ctx.limits) catch |err| {
        try ctx.reports.add(notPowerPointReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    // Encryption first: refuse before any output exists.
    var scan = RecordWalk{ .bytes = stream };
    while (scan.next()) |record| {
        if (record.id == rec_crypt_session) {
            try ctx.reports.add(encryptionReport());
            return error.Malformed;
        }
    }

    try ctx.reports.add(projectionNote());

    var walk = RecordWalk{ .bytes = stream };
    var kind: TextKind = .other;
    var notes_open: ?core.builder.BlockToken = null;
    var slide_index: u32 = 0;
    while (walk.next()) |record| {
        switch (record.id) {
            rec_text_header => {
                if (record.data.len < 4) continue;
                kind = switch (readInt(u32, record.data[0..4])) {
                    0, 6 => .title,
                    1, 5 => .body,
                    2 => .notes,
                    else => .other,
                };
                // Titles arrive once per slide in stream order; the
                // running count is the slide identity provenance names.
                if (kind == .title) slide_index += 1;
            },
            rec_text_chars, rec_text_bytes => {
                var text: std.ArrayList(u8) = .empty;
                if (record.id == rec_text_chars) {
                    try cfb.utf16LeToUtf8(arena, &text, record.data);
                } else {
                    for (record.data) |byte| {
                        try appendCodepoint(arena, &text, cfb.cp1252ToUnicode(byte));
                    }
                }
                if (kind == .notes and notes_open == null) {
                    try ctx.out.attrs(.{ .classes = &.{"notes"} });
                    notes_open = try ctx.out.beginBlock(.container);
                } else if (kind != .notes and notes_open != null) {
                    ctx.out.endBlock(notes_open.?);
                    notes_open = null;
                }
                try emitText(ctx, kind, text.items, slide_index);
            },
            else => {},
        }
    }
    if (notes_open) |token| ctx.out.endBlock(token);
}

/// One text atom holds one placeholder's text: `\r` separates paragraphs
/// and `\x0B` is a soft line break within one. Slide titles carry a
/// provenance facet naming their slide (ZDS 0013, Sparse Facets).
fn emitText(
    ctx: *core.ReadContext,
    kind: TextKind,
    text: []const u8,
    slide_index: u32,
) core.ReadError!void {
    var lines = std.mem.splitScalar(u8, text, '\r');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \x0B\x00").len == 0) continue;
        const token = if (kind == .title)
            try ctx.out.beginHeading(2)
        else
            try ctx.out.beginParagraph();
        if (kind == .title) {
            assert(slide_index >= 1);
            var member_buffer: [24]u8 = undefined;
            const member = std.fmt.bufPrint(&member_buffer, "slide-{d}", .{slide_index}) catch
                unreachable;
            try ctx.out.attachProvenance(token, .{
                .plugin = "ai.insan.zenfmt.ppt",
                .member = member,
                .confidence = .exact,
            });
        }
        var segments = std.mem.splitScalar(u8, line, '\x0B');
        var first = true;
        while (segments.next()) |segment| {
            if (!first) try ctx.out.hardBreak();
            first = false;
            if (segment.len > 0) try ctx.out.text(segment);
        }
        ctx.out.endBlock(token);
    }
}

fn appendCodepoint(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    code: u21,
) error{OutOfMemory}!void {
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(code, &encoded) catch return;
    try out.appendSlice(arena, encoded[0..length]);
}

// ---------------------------------------------------------- record walk

/// Iterative preorder over the record tree. Containers (recVer 0xF) are
/// entered; atoms are yielded. Both the position and the yield count are
/// bounded by the stream length, so a lying length cannot loop.
const RecordWalk = struct {
    bytes: []const u8,
    pos: usize = 0,

    const Item = struct {
        id: u16,
        data: []const u8,
    };

    fn next(walk: *RecordWalk) ?Item {
        while (walk.pos + 8 <= walk.bytes.len) {
            const ver_instance = readInt(u16, walk.bytes[walk.pos..][0..2]);
            const id = readInt(u16, walk.bytes[walk.pos + 2 ..][0..2]);
            const len = readInt(u32, walk.bytes[walk.pos + 4 ..][0..4]);
            walk.pos += 8;
            const is_container = ver_instance & 0x000F == 0x000F;
            if (is_container) {
                // Descend: children start here; the length needs no stack
                // because preorder position alone drives the walk.
                return .{ .id = id, .data = &.{} };
            }
            const available = walk.bytes.len - walk.pos;
            const take = @min(len, available);
            const data = walk.bytes[walk.pos..][0..take];
            walk.pos += take;
            return .{ .id = id, .data = data };
        }
        return null;
    }
};

fn readInt(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return std.mem.readInt(T, bytes, .little);
}

// ------------------------------------------------------------- reports

fn notCompoundReport() core.Report {
    return .{
        .severity = .err,
        .code = "ppt.not-a-compound-file",
        .title = "NOT A READABLE POWERPOINT FILE",
        .problem = "This file is not a compound (OLE) file zenfmt can " ++
            "read, or it trips a container safety limit.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Check the file",
            .explanation = "Open the file in PowerPoint or LibreOffice to " ++
                "verify it is intact, and check the detected format.",
        }},
    };
}

fn notPowerPointReport() core.Report {
    return .{
        .severity = .err,
        .code = "ppt.missing-document-stream",
        .title = "THE POWERPOINT DOCUMENT STREAM IS MISSING",
        .problem = "The compound file opens but has no readable " ++
            "PowerPoint Document stream, so it is not a presentation.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the presentation from PowerPoint or " ++
                "LibreOffice and convert the fresh copy, or export it as .pptx.",
        }},
    };
}

fn encryptionReport() core.Report {
    return .{
        .severity = .err,
        .code = "ppt.encryption-refused",
        .title = "THE PRESENTATION IS ENCRYPTED",
        .problem = "The document stream carries a cryptography session, " ++
            "and zenfmt never attempts decryption.",
        .consequence = "The conversion stopped and no output file was created.",
        .directions = &.{.{
            .title = "Decrypt it first",
            .explanation = "Open the presentation in PowerPoint with its " ++
                "password, save an unencrypted copy, and convert that.",
        }},
    };
}

fn projectionNote() core.Report {
    return .{
        .severity = .warning,
        .code = "ppt.presentation-projection",
        .title = "A PRESENTATION LOSES THE MOST",
        .problem = "A slide deck is a spatial, animated medium, and this " ++
            "projection keeps only its text: titles, body text, and " ++
            "speaker notes.",
        .consequence = "Positioning, animation, transitions, images, " ++
            "charts, and non-text shapes are absent from the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source PPT; the visual design exists " ++
                "only there. Run with --strict to stop instead of " ++
                "converting with these losses.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn appendAtom(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    id: u16,
    payload: []const u8,
) !void {
    var header: [8]u8 = undefined;
    std.mem.writeInt(u16, header[0..2], 0, .little);
    std.mem.writeInt(u16, header[2..4], id, .little);
    std.mem.writeInt(u32, header[4..8], @intCast(payload.len), .little);
    try out.appendSlice(arena, &header);
    try out.appendSlice(arena, payload);
}

fn appendContainer(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    id: u16,
    payload: []const u8,
) !void {
    var header: [8]u8 = undefined;
    std.mem.writeInt(u16, header[0..2], 0x000F, .little);
    std.mem.writeInt(u16, header[2..4], id, .little);
    std.mem.writeInt(u32, header[4..8], @intCast(payload.len), .little);
    try out.appendSlice(arena, &header);
    try out.appendSlice(arena, payload);
}

fn headerAtom(arena: std.mem.Allocator, out: *std.ArrayList(u8), text_type: u32) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, text_type, .little);
    try appendAtom(arena, out, rec_text_header, &payload);
}

fn convertPpt(
    arena: std.mem.Allocator,
    stream: []const u8,
    reports: *core.Reports,
) !core.ast.Document {
    const bytes = try cfb.buildFile(arena, &.{
        .{ .name = "PowerPoint Document", .data = stream },
    });
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "test.ppt",
        .reports = reports,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return doc;
}

test "titles become headings, bodies paragraphs, notes a container" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});

    var inner: std.ArrayList(u8) = .empty;
    try headerAtom(arena, &inner, 0);
    try appendAtom(arena, &inner, rec_text_chars, "B\x00i\x00g\x00 \x00T\x00i\x00t\x00l\x00e\x00");
    try headerAtom(arena, &inner, 1);
    try appendAtom(arena, &inner, rec_text_bytes, "First line\rCaf\xe9 second");
    try headerAtom(arena, &inner, 2);
    try appendAtom(arena, &inner, rec_text_bytes, "Speaker note");
    var stream: std.ArrayList(u8) = .empty;
    try appendContainer(arena, &stream, 0x0FF0, inner.items);

    const doc = try convertPpt(arena, stream.items, reports);
    var headings: u32 = 0;
    var paragraphs: u32 = 0;
    var containers: u32 = 0;
    for (doc.store.blocks.items(.tag)) |tag| switch (tag) {
        .heading => headings += 1,
        .paragraph => paragraphs += 1,
        .container => containers += 1,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), headings);
    try testing.expectEqual(@as(u32, 3), paragraphs);
    try testing.expectEqual(@as(u32, 1), containers);
    const text = doc.store.text.items;
    try testing.expect(std.mem.indexOf(u8, text, "Title") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Café") != null);
    try testing.expect(std.mem.indexOf(u8, text, "note") != null);

    var found = false;
    for (reports.entries.items) |report_entry| {
        if (std.mem.eql(u8, report_entry.report.code, "ppt.presentation-projection")) found = true;
    }
    try testing.expect(found);
}

test "slide titles carry provenance facets naming their slide" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});

    var inner: std.ArrayList(u8) = .empty;
    try headerAtom(arena, &inner, 0);
    try appendAtom(arena, &inner, rec_text_bytes, "First slide");
    try headerAtom(arena, &inner, 1);
    try appendAtom(arena, &inner, rec_text_bytes, "Body");
    try headerAtom(arena, &inner, 0);
    try appendAtom(arena, &inner, rec_text_bytes, "Second slide");
    var stream: std.ArrayList(u8) = .empty;
    try appendContainer(arena, &stream, 0x0FF0, inner.items);

    const doc = try convertPpt(arena, stream.items, reports);
    try testing.expectEqual(@as(usize, 2), doc.store.provenance_facets.items.len);

    var members: [2][]const u8 = undefined;
    var heading_index: usize = 0;
    const tags = doc.store.blocks.items(.tag);
    for (tags, 0..) |tag, index| {
        if (tag != .heading) continue;
        const entity = doc.blockEntity(@enumFromInt(index)).?;
        const provenance = doc.provenanceOf(entity).?;
        try testing.expectEqual(core.facets.Confidence.exact, provenance.confidence);
        try testing.expectEqualStrings(
            "ai.insan.zenfmt.ppt",
            doc.store.textSlice(provenance.plugin),
        );
        members[heading_index] = doc.store.textSlice(provenance.member);
        heading_index += 1;
    }
    try testing.expectEqual(@as(usize, 2), heading_index);
    try testing.expectEqualStrings("slide-1", members[0]);
    try testing.expectEqualStrings("slide-2", members[1]);
}

test "a cryptography session is a refusal with its own code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});

    var stream: std.ArrayList(u8) = .empty;
    try appendAtom(arena, &stream, rec_crypt_session, &.{ 0, 0, 0, 0 });
    try testing.expectError(error.Malformed, convertPpt(arena, stream.items, reports));
    try testing.expectEqualStrings(
        "ppt.encryption-refused",
        reports.entries.items[0].report.code,
    );
}
