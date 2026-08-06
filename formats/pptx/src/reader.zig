//! The PPTX reader (ZDS 0002, The other formats): each slide becomes a
//! heading from the title placeholder followed by the body placeholders.
//! Speaker notes append as a `container` with class `notes`. Positioning,
//! animation, and non-text shapes are dropped — a presentation loses the
//! most in this projection, and the reports say so loudly.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const ooxml = @import("zenfmt_ooxml");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.pptx",
    .format = "pptx",
    .extensions = &.{"pptx"},
    .input = .seekable,
    .read = read,
});

const p_ns = "http://schemas.openxmlformats.org/presentationml/2006/main";
const a_ns = "http://schemas.openxmlformats.org/drawingml/2006/main";
const r_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const notes_type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide";

fn read(ctx: *core.ReadContext) core.ReadError!void {
    const arena = ctx.gpa;
    var archive = ooxml.zip.Archive.open(arena, ctx.input.bytes, ctx.limits) catch |err| {
        try ctx.reports.add(archiveReport());
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    const presentation = extract(&archive, arena, "ppt/presentation.xml", ctx) orelse {
        try ctx.reports.add(notPresentationReport());
        return error.Malformed;
    };
    const rels = blk: {
        const bytes = extract(&archive, arena, "ppt/_rels/presentation.xml.rels", ctx) orelse
            break :blk ooxml.Relationships.empty;
        break :blk ooxml.parseRelationships(arena, bytes, ctx.limits) catch ooxml.Relationships.empty;
    };

    try ctx.reports.add(projectionNote());

    // Slides in `sldIdLst` order.
    var parser = xml.Parser.init(arena, presentation, ctx.limits.max_xml_depth);
    defer parser.deinit();
    while (true) {
        const event = parser.next() catch {
            try ctx.reports.add(notPresentationReport());
            return error.Malformed;
        };
        switch (event) {
            .done => break,
            .element_start => |element| {
                if (!element.name.is(p_ns, "sldId")) continue;
                var rel_id: []const u8 = "";
                for (element.attributes) |attribute| {
                    if (std.mem.eql(u8, attribute.name.uri, r_ns) and
                        std.mem.eql(u8, attribute.name.local, "id"))
                    {
                        rel_id = try arena.dupe(u8, attribute.value);
                    }
                }
                const relationship = rels.byId(rel_id) orelse continue;
                const part = try ooxml.resolveTarget(arena, "ppt", relationship.target);
                try readSlide(ctx, &archive, arena, part);
            },
            else => {},
        }
    }
}

fn extract(
    archive: *ooxml.zip.Archive,
    arena: std.mem.Allocator,
    name: []const u8,
    ctx: *core.ReadContext,
) ?[]const u8 {
    const entry = archive.find(name) orelse return null;
    return archive.extract(arena, entry, ctx.limits) catch null;
}

fn readSlide(
    ctx: *core.ReadContext,
    archive: *ooxml.zip.Archive,
    arena: std.mem.Allocator,
    part: []const u8,
) core.ReadError!void {
    const bytes = extract(archive, arena, part, ctx) orelse return;
    try emitShapes(ctx, arena, bytes, .slide);

    // Speaker notes hang off the slide's own relationships.
    const dir = std.fs.path.dirname(part) orelse "ppt/slides";
    const base = std.fs.path.basename(part);
    const rels_part = try std.fmt.allocPrint(arena, "{s}/_rels/{s}.rels", .{ dir, base });
    const rels_bytes = extract(archive, arena, rels_part, ctx) orelse return;
    const rels = ooxml.parseRelationships(arena, rels_bytes, ctx.limits) catch return;
    const notes = rels.byType(notes_type) orelse return;
    const notes_part = try ooxml.resolveTarget(arena, dir, notes.target);
    const notes_bytes = extract(archive, arena, normalizePath(arena, notes_part) catch notes_part, ctx) orelse return;

    try ctx.out.attrs(.{ .classes = &.{"notes"} });
    const container = try ctx.out.beginBlock(.container);
    try emitShapes(ctx, arena, notes_bytes, .notes);
    ctx.out.endBlock(container);
}

/// `ppt/slides/../notesSlides/x.xml` becomes `ppt/notesSlides/x.xml`.
fn normalizePath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) parts.items.len -= 1;
        } else if (part.len > 0 and !std.mem.eql(u8, part, ".")) {
            try parts.append(arena, part);
        }
    }
    return std.mem.join(arena, "/", parts.items);
}

const ShapeContext = enum { slide, notes };

/// Walks one slide or notes part: title placeholders become headings,
/// every other text body becomes paragraphs.
fn emitShapes(
    ctx: *core.ReadContext,
    arena: std.mem.Allocator,
    bytes: []const u8,
    shape_context: ShapeContext,
) core.ReadError!void {
    var parser = xml.Parser.init(arena, bytes, ctx.limits.max_xml_depth);
    defer parser.deinit();

    var is_title = false;
    var paragraph: ?core.builder.BlockToken = null;
    var strong_token: ?core.builder.InlineToken = null;
    var emphasis_token: ?core.builder.InlineToken = null;
    var run_strong = false;
    var run_emphasis = false;
    var in_text = false;
    var heading_pending = false;

    while (true) {
        const event = parser.next() catch return;
        switch (event) {
            .done => break,
            .element_start => |element| {
                if (element.name.is(p_ns, "sp")) {
                    is_title = false;
                } else if (element.name.is(p_ns, "ph")) {
                    for (element.attributes) |attribute| {
                        if (std.mem.eql(u8, attribute.name.local, "type")) {
                            is_title = std.mem.eql(u8, attribute.value, "title") or
                                std.mem.eql(u8, attribute.value, "ctrTitle");
                        }
                    }
                } else if (element.name.is(a_ns, "p")) {
                    heading_pending = shape_context == .slide and is_title;
                    paragraph = null;
                } else if (element.name.is(a_ns, "r")) {
                    run_strong = false;
                    run_emphasis = false;
                } else if (element.name.is(a_ns, "rPr")) {
                    for (element.attributes) |attribute| {
                        if (std.mem.eql(u8, attribute.name.local, "b")) {
                            run_strong = std.mem.eql(u8, attribute.value, "1");
                        } else if (std.mem.eql(u8, attribute.name.local, "i")) {
                            run_emphasis = std.mem.eql(u8, attribute.value, "1");
                        }
                    }
                } else if (element.name.is(a_ns, "t")) {
                    in_text = !element.self_closing;
                    if (in_text and paragraph == null) {
                        paragraph = if (heading_pending)
                            try ctx.out.beginHeading(2)
                        else
                            try ctx.out.beginParagraph();
                    }
                    if (in_text and paragraph != null) {
                        if (run_strong and strong_token == null) {
                            strong_token = try ctx.out.beginInline(.strong);
                        }
                        if (run_emphasis and emphasis_token == null) {
                            emphasis_token = try ctx.out.beginInline(.emphasis);
                        }
                    }
                } else if (element.name.is(a_ns, "br")) {
                    if (paragraph != null) try ctx.out.hardBreak();
                }
            },
            .element_end => |name| {
                if (std.mem.eql(u8, name.local, "t")) {
                    in_text = false;
                } else if (std.mem.eql(u8, name.local, "r")) {
                    if (emphasis_token) |token| {
                        ctx.out.endInline(token);
                        emphasis_token = null;
                    }
                    if (strong_token) |token| {
                        ctx.out.endInline(token);
                        strong_token = null;
                    }
                } else if (std.mem.eql(u8, name.local, "p") and
                    std.mem.eql(u8, name.uri, a_ns))
                {
                    if (emphasis_token) |token| {
                        ctx.out.endInline(token);
                        emphasis_token = null;
                    }
                    if (strong_token) |token| {
                        ctx.out.endInline(token);
                        strong_token = null;
                    }
                    if (paragraph) |token| {
                        ctx.out.endBlock(token);
                        paragraph = null;
                    }
                }
            },
            .text => |value| {
                if (in_text and paragraph != null) {
                    try ctx.out.text(value);
                }
            },
        }
    }
    if (paragraph) |token| {
        if (emphasis_token) |inline_token| ctx.out.endInline(inline_token);
        if (strong_token) |inline_token| ctx.out.endInline(inline_token);
        ctx.out.endBlock(token);
    }
}

// ------------------------------------------------------------- reports

fn archiveReport() core.Report {
    return .{
        .severity = .err,
        .code = "pptx.not-an-archive",
        .title = "NOT A READABLE PPTX ARCHIVE",
        .problem = "This file is not a ZIP archive zenfmt can read, or it " ++
            "trips an archive safety limit.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Check the file",
            .explanation = "Open the file in PowerPoint or LibreOffice to " ++
                "verify it is intact, and check the detected format.",
        }},
    };
}

fn notPresentationReport() core.Report {
    return .{
        .severity = .err,
        .code = "pptx.missing-presentation",
        .title = "THE PRESENTATION PART IS MISSING",
        .problem = "The archive opens but does not contain a readable " ++
            "ppt/presentation.xml, so it is not a presentation.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the presentation from its native " ++
                "application and convert the fresh copy.",
        }},
    };
}

fn projectionNote() core.Report {
    return .{
        .severity = .warning,
        .code = "pptx.presentation-projection",
        .title = "A PRESENTATION LOSES THE MOST",
        .problem = "A slide deck is a spatial, animated medium, and this " ++
            "projection keeps only its text: titles, body text, and " ++
            "speaker notes.",
        .consequence = "Positioning, animation, transitions, images, " ++
            "charts, and non-text shapes are absent from the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source PPTX; the visual design " ++
                "exists only there. Run with --strict to stop instead of " ++
                "converting with these losses.",
        }},
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "path normalization for slide-relative targets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(
        "ppt/notesSlides/notesSlide1.xml",
        try normalizePath(arena, "ppt/slides/../notesSlides/notesSlide1.xml"),
    );
}
