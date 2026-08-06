//! The PDF reader (ZDS: pdf-reader).
//!
//! Native text extraction: `xref.zig` opens the file, `content.zig` turns
//! each page's content streams into positioned lines, and this file walks
//! the page tree, projects the lines into headings and paragraphs by font
//! size and vertical rhythm, and reports every loss. Encrypted documents
//! are refused outright; there is no override.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const objects = @import("objects.zig");
const xref = @import("xref.zig");
const content_mod = @import("content.zig");
const layout = @import("layout.zig");
const reports_mod = @import("reports.zig");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.pdf",
    .format = "pdf",
    .extensions = &.{"pdf"},
    .input = .seekable,
    .data_version = 1,
    .read = read,
});

/// Pages one document may contribute; beyond this is a refusal.
const max_pages = 8192;

fn read(ctx: *core.ReadContext) core.ReadError!void {
    const arena = ctx.gpa;
    var file = xref.File.open(arena, ctx.input.bytes, ctx.limits) catch |err| {
        try ctx.reports.add(switch (err) {
            error.NotPdf => reports_mod.notPdfReport(),
            error.Encrypted => reports_mod.encryptionReport(),
            error.LimitExceeded => reports_mod.limitReport(),
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => reports_mod.malformedReport(),
        });
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    var machine = content_mod.Machine{ .arena = arena, .file = &file, .limits = ctx.limits };
    var link_count: u32 = 0;
    try walkPages(ctx, &file, &machine, &link_count);
    try machine.flushLine();

    try layout.emitDocument(ctx, &machine);
    try emitInfo(ctx, &file);

    try ctx.reports.add(reports_mod.projectionNote());
    if (machine.lines.items.len == 0) try ctx.reports.add(reports_mod.noTextReport());
    if (file.unsupported_filter) |name| {
        try ctx.reports.add(reports_mod.unsupportedFilterReport(try arena.dupe(u8, name)));
    }
    if (machine.unmappable > 0) {
        try ctx.reports.add(reports_mod.unmappableReport(machine.unmappable));
    }
    if (machine.images > 0) try ctx.reports.add(reports_mod.imagesNote(machine.images));
    if (link_count > 0) try ctx.reports.add(reports_mod.linksNote(link_count));
}

// ------------------------------------------------------------ page walk

const PendingNode = struct {
    node: objects.Object,
    resources: ?objects.Dict,
};

fn walkPages(
    ctx: *core.ReadContext,
    file: *xref.File,
    machine: *content_mod.Machine,
    link_count: *u32,
) core.ReadError!void {
    const arena = ctx.gpa;
    const root = pdfTry(ctx, file.dictGet(file.trailer, "Root")) catch return error.Malformed;
    const catalog = (root orelse return malformed(ctx)).asDict() orelse return malformed(ctx);
    const pages_obj = pdfTry(ctx, file.dictGet(catalog, "Pages")) catch return error.Malformed;

    var stack: std.ArrayList(PendingNode) = .empty;
    defer stack.deinit(arena);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(arena);
    try pushNode(arena, &stack, &visited, catalog.get("Pages"), null);
    _ = pages_obj;

    var page_index: u32 = 0;
    // Bounded by max_pages plus the visited set: each node enters once.
    while (stack.items.len > 0) {
        const pending = stack.pop().?;
        const resolved = pdfTry(ctx, file.resolve(pending.node)) catch continue;
        const dict = resolved.asDict() orelse continue;
        const resources: ?objects.Dict = blk: {
            const own = pdfTry(ctx, file.dictGet(dict, "Resources")) catch break :blk pending.resources;
            if (own) |value| {
                if (value.asDict()) |own_dict| break :blk own_dict;
            }
            break :blk pending.resources;
        };

        const node_type = dict.get("Type") orelse objects.Object.null;
        if (node_type.isName("Pages")) {
            const kids = pdfTry(ctx, file.dictGet(dict, "Kids")) catch continue;
            if (kids) |kids_obj| {
                if (kids_obj == .array) {
                    // Reverse order: the stack pops first-child first.
                    var i = kids_obj.array.len;
                    while (i > 0) {
                        i -= 1;
                        try pushNode(arena, &stack, &visited, kids_obj.array[i], resources);
                    }
                }
            }
            continue;
        }
        // A leaf page (declared or malformed-but-content-bearing).
        if (page_index >= max_pages) {
            try ctx.reports.add(reports_mod.limitReport());
            return error.LimitExceeded;
        }
        try readPage(ctx, file, machine, dict, resources orelse .{}, page_index);
        countLinks(file, dict, link_count);
        page_index += 1;
    }
}

fn pushNode(
    arena: std.mem.Allocator,
    stack: *std.ArrayList(PendingNode),
    visited: *std.AutoHashMapUnmanaged(u32, void),
    node: ?objects.Object,
    resources: ?objects.Dict,
) error{OutOfMemory}!void {
    const value = node orelse return;
    if (value == .ref) {
        const slot = try visited.getOrPut(arena, value.ref.num);
        if (slot.found_existing) return;
    }
    if (stack.items.len >= max_pages * 2) return;
    try stack.append(arena, .{ .node = value, .resources = resources });
}

fn readPage(
    ctx: *core.ReadContext,
    file: *xref.File,
    machine: *content_mod.Machine,
    page: objects.Dict,
    resources: objects.Dict,
    page_index: u32,
) core.ReadError!void {
    const arena = ctx.gpa;
    const contents = pdfTry(ctx, file.dictGet(page, "Contents")) catch return;
    const contents_obj = contents orelse return;

    var data: std.ArrayList(u8) = .empty;
    switch (contents_obj) {
        .stream => |s| {
            const decoded = pdfTry(ctx, file.decodeStream(s)) catch return;
            try data.appendSlice(arena, decoded);
        },
        .array => |parts| for (parts) |part| {
            const resolved = pdfTry(ctx, file.resolve(part)) catch continue;
            if (resolved != .stream) continue;
            const decoded = pdfTry(ctx, file.decodeStream(resolved.stream)) catch continue;
            try data.appendSlice(arena, decoded);
            try data.append(arena, '\n');
        },
        else => return,
    }
    machine.runPage(data.items, resources, page_index) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

fn countLinks(file: *xref.File, page: objects.Dict, link_count: *u32) void {
    const annots = (file.dictGet(page, "Annots") catch return) orelse return;
    if (annots != .array) return;
    for (annots.array) |entry| {
        const resolved = file.resolve(entry) catch continue;
        const dict = resolved.asDict() orelse continue;
        const subtype = dict.get("Subtype") orelse continue;
        if (subtype.isName("Link")) link_count.* += 1;
    }
}

// ------------------------------------------------------------- metadata

fn emitInfo(ctx: *core.ReadContext, file: *xref.File) core.ReadError!void {
    const info_obj = (file.dictGet(file.trailer, "Info") catch null) orelse return;
    const info = info_obj.asDict() orelse return;
    const keys = [_]struct { pdf: []const u8, meta: []const u8 }{
        .{ .pdf = "Title", .meta = "title" },
        .{ .pdf = "Author", .meta = "author" },
        .{ .pdf = "Subject", .meta = "subject" },
    };
    for (keys) |key| {
        const value = (file.dictGet(info, key.pdf) catch continue) orelse continue;
        if (value != .string) continue;
        const text = decodeTextString(ctx.gpa, value.string) catch continue;
        if (text.len > 0) try ctx.out.metaString(key.meta, text);
    }
}

/// PDF text strings are UTF-16BE with a BOM, or PDFDocEncoding (close
/// enough to CP-1252 for the printable range).
fn decodeTextString(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (bytes.len >= 2 and bytes[0] == 0xfe and bytes[1] == 0xff) {
        var i: usize = 2;
        while (i + 2 <= bytes.len) : (i += 2) {
            var cp: u21 = (@as(u21, bytes[i]) << 8) | bytes[i + 1];
            if (cp >= 0xd800 and cp <= 0xdbff and i + 4 <= bytes.len) {
                const low = (@as(u21, bytes[i + 2]) << 8) | bytes[i + 3];
                if (low >= 0xdc00 and low <= 0xdfff) {
                    cp = 0x10000 + ((@as(u21, cp - 0xd800) << 10) | (low - 0xdc00));
                    i += 2;
                }
            }
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buffer) catch continue;
            try out.appendSlice(arena, buffer[0..len]);
        }
        return out.items;
    }
    const glyphs = @import("glyphs.zig");
    for (bytes) |byte| {
        const cp = glyphs.baseChar(.win_ansi, byte);
        if (cp == 0) continue;
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buffer) catch continue;
        try out.appendSlice(arena, buffer[0..len]);
    }
    return out.items;
}

// -------------------------------------------------------------- helpers

fn malformed(ctx: *core.ReadContext) core.ReadError {
    ctx.reports.add(reports_mod.malformedReport()) catch return error.OutOfMemory;
    return error.Malformed;
}

/// Maps the pdf error set onto ReadError, reporting on the way out.
fn pdfTry(ctx: *core.ReadContext, result: anytype) core.ReadError!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LimitExceeded => blk: {
            try ctx.reports.add(reports_mod.limitReport());
            break :blk error.LimitExceeded;
        },
        else => blk: {
            try ctx.reports.add(reports_mod.malformedReport());
            break :blk error.Malformed;
        },
    };
}
