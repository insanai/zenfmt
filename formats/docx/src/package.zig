//! DOCX package front end, split out of `reader.zig` (file-size rule).
//!
//! Opens the OOXML archive, resolves the main document part through the
//! package relationships, loads the optional styles/numbering/rels parts,
//! and drives the reader's `Machine` over the document XML.

const std = @import("std");
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const ooxml = @import("zenfmt_ooxml");
const styles_mod = @import("styles.zig");
const numbering_mod = @import("numbering.zig");
const reader_mod = @import("reader.zig");
const reports_mod = @import("reports.zig");

const Machine = reader_mod.Machine;
const archiveReport = reports_mod.archiveReport;
const missingPartReport = reports_mod.missingPartReport;

pub fn read(ctx: *core.ReadContext) core.ReadError!void {
    const arena = ctx.gpa;
    var archive = ooxml.zip.Archive.openSource(arena, ooxml.zipSource(ctx), ctx.limits) catch |err| {
        try ctx.reports.add(archiveReport(err, ctx.input_name));
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    // The main part comes from the package relationships, not a guess.
    const document_part = blk: {
        if (try extractOptional(&archive, arena, "_rels/.rels", ctx)) |rels_bytes| {
            const rels = ooxml.parseRelationships(arena, rels_bytes, ctx.limits) catch null;
            if (rels) |value| {
                if (value.byType(ooxml.office_document_type)) |office| {
                    break :blk try ooxml.resolveTarget(arena, "", office.target);
                }
            }
        }
        break :blk "word/document.xml";
    };
    const document_entry = archive.find(document_part) orelse {
        try ctx.reports.add(missingPartReport(ctx.input_name, document_part));
        return error.Malformed;
    };
    const document_bytes = try extractRequired(&archive, arena, document_entry, ctx);

    const styles = blk: {
        const bytes = (try extractOptional(&archive, arena, "word/styles.xml", ctx)) orelse
            break :blk styles_mod.Styles.empty;
        break :blk styles_mod.parse(arena, bytes, ctx.limits) catch styles_mod.Styles.empty;
    };
    const numbering = blk: {
        const bytes = (try extractOptional(&archive, arena, "word/numbering.xml", ctx)) orelse
            break :blk numbering_mod.Numbering.empty;
        break :blk numbering_mod.parse(arena, bytes, ctx.limits) catch numbering_mod.Numbering.empty;
    };
    const rels = blk: {
        const bytes = (try extractOptional(&archive, arena, "word/_rels/document.xml.rels", ctx)) orelse
            break :blk ooxml.Relationships.empty;
        break :blk ooxml.parseRelationships(arena, bytes, ctx.limits) catch ooxml.Relationships.empty;
    };

    var machine: Machine = .{
        .ctx = ctx,
        .arena = arena,
        .styles = &styles,
        .numbering = &numbering,
        .rels = &rels,
        .archive = &archive,
    };
    defer machine.deinit();

    {
        var parser = xml.Parser.init(arena, document_bytes, ctx.limits.max_xml_depth);
        defer parser.deinit();
        machine.parser = &parser;
        try machine.run(0);
        try machine.closeLists(0);
    }

    if (machine.note_order.items.len > 0) {
        if (try extractOptional(&archive, arena, "word/footnotes.xml", ctx)) |footnote_bytes| {
            try machine.readFootnotes(footnote_bytes);
        }
    }
    // Every declared note gets a body, even when footnotes.xml is absent.
    for (machine.note_order.items) |entry| {
        if (!entry.emitted) {
            ctx.out.beginNoteBody(entry.note);
            ctx.out.endNoteBody(entry.note);
        }
    }

    try machine.finishReports();
    try machine.emitPluginData();
}

/// A missing part is normal; a part that trips a limit is a refusal even
/// when the part itself is optional — a bomb in styles.xml is still a bomb.
fn extractOptional(
    archive: *ooxml.zip.Archive,
    arena: std.mem.Allocator,
    name: []const u8,
    ctx: *core.ReadContext,
) core.ReadError!?[]const u8 {
    const entry = archive.find(name) orelse return null;
    return try extractRequired(archive, arena, entry, ctx);
}

fn extractRequired(
    archive: *ooxml.zip.Archive,
    arena: std.mem.Allocator,
    entry: *const ooxml.zip.Entry,
    ctx: *core.ReadContext,
) core.ReadError![]const u8 {
    return archive.extract(arena, entry, ctx.limits) catch |err| {
        try ctx.reports.add(archiveReport(err, entry.name));
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };
}
