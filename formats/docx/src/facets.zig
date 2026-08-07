//! Facet attachment and media extraction for the DOCX reader (ZDS 0013,
//! Sparse Facets), split out of `reader.zig` (file-size rule).
//!
//! Facets ride beside the kernel nodes the reader already emits: named
//! paragraph styles become `StyleFacet` rows, tracked changes become
//! `RevisionFacet` rows, the section's page size becomes one page
//! `LayoutFacet`, and embedded image bytes register with the resource
//! store. By the facet erasure axiom none of this changes the emitted
//! flow, and the byte-identity of the Markdown output is the test.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const reader_mod = @import("reader.zig");
const reports_mod = @import("reports.zig");
const util = @import("util.zig");

const Machine = reader_mod.Machine;
const stringAttribute = util.stringAttribute;

/// EMU per twip: a twip is 1/20 point, an EMU 1/914400 inch (ZDS 0013,
/// One coordinate system).
const emu_per_twip = 635;

/// A revision met outside any paragraph, held for the next one: a
/// paragraph-level `w:ins` wraps the paragraphs it inserted.
pub const PendingRevision = struct {
    kind: core.facets.RevisionKind,
    author: []const u8,
    timestamp: []const u8,
};

/// A tracked change: attach to the containing paragraph when one is open,
/// else stash for the paragraph that follows.
pub fn onRevision(
    m: *Machine,
    element: xml.ElementStart,
    kind: core.facets.RevisionKind,
) core.ReadError!void {
    const author = stringAttribute(element.attributes, "author") orelse "";
    const timestamp = stringAttribute(element.attributes, "date") orelse "";
    if (m.currentParagraphToken()) |token| {
        try m.ctx.out.attachRevision(token, .{
            .kind = kind,
            .author = author,
            .timestamp = timestamp,
        });
        return;
    }
    if (m.pending_revision == null) {
        m.pending_revision = .{
            .kind = kind,
            .author = try m.arena.dupe(u8, author),
            .timestamp = try m.arena.dupe(u8, timestamp),
        };
    }
}

/// Applies a stashed paragraph-level revision to the paragraph that just
/// opened.
pub fn applyPendingRevision(m: *Machine, token: core.builder.BlockToken) core.ReadError!void {
    const pending = m.pending_revision orelse return;
    m.pending_revision = null;
    try m.ctx.out.attachRevision(token, .{
        .kind = pending.kind,
        .author = pending.author,
        .timestamp = pending.timestamp,
    });
}

/// Consumes a body-level `w:sectPr` subtree, harvesting `w:pgSz` into one
/// page `LayoutFacet` on the document's first block. Counting stays with
/// the caller; the facet is additive.
pub fn onSectionProperties(m: *Machine) core.ReadError!void {
    const target = m.parser.depth;
    var width: ?u32 = null;
    var height: ?u32 = null;
    while (m.parser.depth >= target) {
        const event = try m.next();
        switch (event) {
            .done => break,
            .element_start => |child| {
                if (!child.name.is(reader_mod.w_ns, "pgSz")) continue;
                if (stringAttribute(child.attributes, "w")) |value| {
                    width = std.fmt.parseInt(u32, value, 10) catch null;
                }
                if (stringAttribute(child.attributes, "h")) |value| {
                    height = std.fmt.parseInt(u32, value, 10) catch null;
                }
            },
            else => {},
        }
    }
    if (m.layout_attached) return;
    const token = m.first_block_token orelse return;
    const page_width = width orelse return;
    const page_height = height orelse return;
    // Twips into EMU; a page wider than i32 EMU is not a page.
    if (page_width > std.math.maxInt(i32) / emu_per_twip) return;
    if (page_height > std.math.maxInt(i32) / emu_per_twip) return;
    m.layout_attached = true;
    try m.ctx.out.attachLayout(token, .{
        .surface = .page,
        .surface_index = 0,
        .width = @intCast(page_width * emu_per_twip),
        .height = @intCast(page_height * emu_per_twip),
    });
}

/// Extracts a drawing's image part from the archive and registers it with
/// the resource store under the same source name the `image` node carries,
/// so the engine's URL rewrite finds it on path output. A part past the
/// resource limits degrades to a counted note; a missing or broken part
/// leaves the reference as before, which is exactly the old behavior.
pub fn registerImage(m: *Machine, source: []const u8) core.ReadError!void {
    if (source.len == 0) return;
    const archive = m.archive orelse return;
    const entry = archive.find(source) orelse return;
    const bytes = archive.extract(m.arena, entry, m.ctx.limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded => {
            try m.ctx.reports.add(reports_mod.mediaLimitNote());
            return;
        },
        else => return,
    };
    if (bytes.len == 0) return;
    _ = m.ctx.out.resource(source, bytes, mimeForName(source)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DepthLimitExceeded => return error.DepthLimitExceeded,
        error.LimitExceeded => {
            try m.ctx.reports.add(reports_mod.mediaLimitNote());
            return;
        },
    };
}

/// MIME type from the part name's extension; unknown types stay opaque
/// rather than guessed.
pub fn mimeForName(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "application/octet-stream";
    const extension = name[dot + 1 ..];
    const table = [_]struct { extension: []const u8, mime: []const u8 }{
        .{ .extension = "png", .mime = "image/png" },
        .{ .extension = "jpg", .mime = "image/jpeg" },
        .{ .extension = "jpeg", .mime = "image/jpeg" },
        .{ .extension = "gif", .mime = "image/gif" },
        .{ .extension = "bmp", .mime = "image/bmp" },
        .{ .extension = "tif", .mime = "image/tiff" },
        .{ .extension = "tiff", .mime = "image/tiff" },
        .{ .extension = "svg", .mime = "image/svg+xml" },
        .{ .extension = "emf", .mime = "image/emf" },
        .{ .extension = "wmf", .mime = "image/wmf" },
    };
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(row.extension, extension)) return row.mime;
    }
    return "application/octet-stream";
}

test "mime lookup is extension-driven and honest about the unknown" {
    try std.testing.expectEqualStrings("image/png", mimeForName("word/media/image1.PNG"));
    try std.testing.expectEqualStrings("image/jpeg", mimeForName("a.jpeg"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeForName("a.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeForName("noext"));
}
