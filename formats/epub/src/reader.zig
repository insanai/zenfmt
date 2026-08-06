//! The EPUB reader (ZDS epub-reader record).
//!
//! An EPUB is a ZIP with a table of contents: `META-INF/container.xml`
//! names the OPF package, the package's manifest maps ids to entries, and
//! its spine orders the reading. Every XHTML spine item runs through the
//! shared HTML reader machinery into one emitter, so chapters concatenate
//! in spine order with their relative targets rebased to container paths.
//! DRM (`META-INF/encryption.xml`) is refused outright, like every other
//! security refusal: there is no override flag.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const ooxml = @import("zenfmt_ooxml");
const html = @import("zenfmt_html");

pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.epub",
    .format = "epub",
    .extensions = &.{"epub"},
    .input = .seekable,
    .data_version = 1,
    .read = read,
});

const container_ns = "urn:oasis:names:tc:opendocument:xmlns:container";
const opf_ns = "http://www.idpf.org/2007/opf";
const dc_ns = "http://purl.org/dc/elements/1.1/";

const ManifestItem = struct {
    id: []const u8,
    href: []const u8,
    media_type: []const u8,
};

const Package = struct {
    title: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    language: ?[]const u8 = null,
    date: ?[]const u8 = null,
    manifest: std.ArrayList(ManifestItem) = .empty,
    spine: std.ArrayList([]const u8) = .empty,

    fn find(package: *const Package, id: []const u8) ?*const ManifestItem {
        for (package.manifest.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) return item;
        }
        return null;
    }
};

pub fn read(ctx: *core.ReadContext) core.ReadError!void {
    const arena = ctx.gpa;
    var archive = ooxml.zip.Archive.open(arena, ctx.input.bytes, ctx.limits) catch |err| {
        try ctx.reports.add(archiveReport(err));
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };

    if (archive.find("META-INF/encryption.xml") != null) {
        try ctx.reports.add(drmReport());
        return error.Malformed;
    }

    const container_entry = archive.find("META-INF/container.xml") orelse {
        try ctx.reports.add(missingContainerReport());
        return error.Malformed;
    };
    const container_bytes = try extract(&archive, arena, container_entry, ctx);
    const opf_path = (try rootfilePath(arena, container_bytes, ctx)) orelse {
        try ctx.reports.add(missingPackageReport("META-INF/container.xml"));
        return error.Malformed;
    };
    const opf_entry = archive.find(opf_path) orelse {
        try ctx.reports.add(missingPackageReport(opf_path));
        return error.Malformed;
    };
    const opf_bytes = try extract(&archive, arena, opf_entry, ctx);
    const opf_dir = dirname(opf_path);

    var package = try parsePackage(arena, opf_bytes, ctx);
    defer {
        package.manifest.deinit(arena);
        package.spine.deinit(arena);
    }
    if (package.title) |value| try ctx.out.metaString("title", value);
    if (package.creator) |value| try ctx.out.metaString("author", value);
    if (package.language) |value| try ctx.out.metaString("language", value);
    if (package.date) |value| try ctx.out.metaString("date", value);

    var chapters: u32 = 0;
    var skipped: u32 = 0;
    var missing: u32 = 0;
    for (package.spine.items) |idref| {
        const item = package.find(idref) orelse {
            skipped += 1;
            continue;
        };
        const is_markup = std.mem.eql(u8, item.media_type, "application/xhtml+xml") or
            std.mem.eql(u8, item.media_type, "text/html");
        if (!is_markup) {
            skipped += 1;
            continue;
        }
        const resolved = try ooxml.resolveTarget(arena, opf_dir, item.href);
        const path = try normalizePath(arena, resolved);
        const entry = archive.find(path) orelse {
            missing += 1;
            continue;
        };
        const bytes = try extract(&archive, arena, entry, ctx);
        try html.parseFragment(ctx, bytes, dirname(path));
        chapters += 1;
    }

    if (chapters == 0 and package.spine.items.len > 0) {
        try ctx.reports.add(missingPackageReport(opf_path));
        return error.Malformed;
    }
    if (missing > 0) try ctx.reports.add(counted(missingChapterReport(), missing));
    if (skipped > 0) try ctx.reports.add(counted(skippedSpineReport(), skipped));
}

/// The first `rootfile` full-path in the container document.
fn rootfilePath(
    arena: std.mem.Allocator,
    bytes: []const u8,
    ctx: *core.ReadContext,
) core.ReadError!?[]const u8 {
    var parser = xml.Parser.init(arena, bytes, ctx.limits.max_xml_depth);
    defer parser.deinit();
    while (true) {
        const event = parser.next() catch return null;
        switch (event) {
            .done => return null,
            .element_start => |element| {
                const name = element.name;
                const matches = name.is(container_ns, "rootfile") or
                    (name.uri.len == 0 and std.mem.eql(u8, name.local, "rootfile"));
                if (matches) {
                    if (attribute(element.attributes, "full-path")) |value| {
                        if (value.len > 0) return try arena.dupe(u8, value);
                    }
                }
            },
            else => {},
        }
    }
}

/// One pass over the OPF: Dublin Core metadata, manifest items, spine order.
fn parsePackage(
    arena: std.mem.Allocator,
    bytes: []const u8,
    ctx: *core.ReadContext,
) core.ReadError!Package {
    var package: Package = .{};
    errdefer {
        package.manifest.deinit(arena);
        package.spine.deinit(arena);
    }
    var parser = xml.Parser.init(arena, bytes, ctx.limits.max_xml_depth);
    defer parser.deinit();

    var pending: ?*?[]const u8 = null;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(arena);

    while (true) {
        const event = parser.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try ctx.reports.add(malformedPackageReport());
                return error.Malformed;
            },
        };
        switch (event) {
            .done => return package,
            .element_start => |element| {
                const name = element.name;
                pending = null;
                text.clearRetainingCapacity();
                if (std.mem.eql(u8, name.uri, dc_ns)) {
                    if (std.mem.eql(u8, name.local, "title")) pending = &package.title;
                    if (std.mem.eql(u8, name.local, "creator")) pending = &package.creator;
                    if (std.mem.eql(u8, name.local, "language")) pending = &package.language;
                    if (std.mem.eql(u8, name.local, "date")) pending = &package.date;
                    if (element.self_closing) pending = null;
                } else if (isOpf(name, "item")) {
                    const id = attribute(element.attributes, "id") orelse "";
                    const href = attribute(element.attributes, "href") orelse "";
                    const media_type = attribute(element.attributes, "media-type") orelse "";
                    if (id.len > 0 and href.len > 0) {
                        try package.manifest.append(arena, .{
                            .id = try arena.dupe(u8, id),
                            .href = try arena.dupe(u8, href),
                            .media_type = try arena.dupe(u8, media_type),
                        });
                    }
                } else if (isOpf(name, "itemref")) {
                    if (attribute(element.attributes, "idref")) |idref| {
                        if (idref.len > 0) {
                            try package.spine.append(arena, try arena.dupe(u8, idref));
                        }
                    }
                }
            },
            .text => |value| {
                if (pending != null) try text.appendSlice(arena, value);
            },
            .element_end => {
                if (pending) |slot| {
                    const trimmed = std.mem.trim(u8, text.items, " \t\r\n");
                    if (slot.* == null and trimmed.len > 0) {
                        slot.* = try arena.dupe(u8, trimmed);
                    }
                }
                pending = null;
            },
        }
    }
}

fn isOpf(name: anytype, local: []const u8) bool {
    return name.is(opf_ns, local) or
        (name.uri.len == 0 and std.mem.eql(u8, name.local, local));
}

fn attribute(attributes: anytype, local: []const u8) ?[]const u8 {
    for (attributes) |item| {
        if (std.mem.eql(u8, item.name.local, local)) return item.value;
    }
    return null;
}

fn dirname(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

/// `a/b/../c` becomes `a/c`; `.` components and empty segments vanish.
fn normalizePath(
    arena: std.mem.Allocator,
    path: []const u8,
) error{OutOfMemory}![]const u8 {
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

fn extract(
    archive: *ooxml.zip.Archive,
    arena: std.mem.Allocator,
    entry: *const ooxml.zip.Entry,
    ctx: *core.ReadContext,
) core.ReadError![]const u8 {
    return archive.extract(arena, entry, ctx.limits) catch |err| {
        try ctx.reports.add(archiveReport(err));
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            else => error.Malformed,
        };
    };
}

fn counted(report: core.Report, count: u32) core.Report {
    var out = report;
    out.count = count;
    return out;
}

// --------------------------------------------------------------- reports

fn archiveReport(err: anytype) core.Report {
    return switch (err) {
        error.OutOfMemory, error.LimitExceeded => .{
            .severity = .err,
            .code = "epub.archive-limit",
            .title = "THE ARCHIVE TRIPS A SAFETY LIMIT",
            .problem = "Unpacking this EPUB exceeds an archive safety " ++
                "limit (entry count, entry size, or compression ratio).",
            .consequence = "The conversion stopped and no output file " ++
                "was created.",
            .exit_class = .limit,
            .directions = &.{.{
                .title = "Raise the limit if the book is trusted",
                .explanation = "If this is a legitimate book, raise the " ++
                    "relevant limit for this run with --limit NAME=VALUE.",
            }},
        },
        else => .{
            .severity = .err,
            .code = "epub.bad-archive",
            .title = "THE ARCHIVE CANNOT BE READ",
            .problem = "This file is not a ZIP archive zenfmt can read: " ++
                "it is truncated, encrypted, hostile, or uses an " ++
                "unsupported compression method.",
            .consequence = "The conversion stopped and no output file " ++
                "was created.",
            .exit_class = .limit,
            .directions = &.{.{
                .title = "Re-export the book",
                .explanation = "Re-export the EPUB from the original " ++
                    "application and convert the fresh file.",
            }},
        },
    };
}

fn drmReport() core.Report {
    return .{
        .severity = .err,
        .code = "epub.drm-refused",
        .title = "THIS BOOK IS ENCRYPTED",
        .problem = "This EPUB carries `META-INF/encryption.xml`: some or " ++
            "all of its content is DRM-protected or font-obfuscated.",
        .consequence = "The book was refused outright and no output file " ++
            "was created. There is no override flag.",
        .exit_class = .limit,
        .directions = &.{.{
            .title = "Obtain an unprotected copy",
            .explanation = "Ask the publisher or storefront for a " ++
                "DRM-free copy and convert that file.",
        }},
    };
}

fn missingContainerReport() core.Report {
    return .{
        .severity = .err,
        .code = "epub.missing-container",
        .title = "NOT AN EPUB CONTAINER",
        .problem = "This ZIP has no `META-INF/container.xml`, the entry " ++
            "every EPUB must carry to name its package document.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Check the file",
            .explanation = "The file may be a plain ZIP or a different " ++
                "format wearing the .epub extension. Convert the real " ++
                "source, or select the actual format with --from.",
        }},
    };
}

fn missingPackageReport(path: []const u8) core.Report {
    return .{
        .severity = .err,
        .code = "epub.missing-package",
        .title = "THE PACKAGE DOCUMENT IS MISSING",
        .problem = "The container names a package document that cannot " ++
            "be loaded, or no spine chapter could be read from it.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .context = .{ .archive_member = path },
        .directions = &.{.{
            .title = "Re-export the book",
            .explanation = "Re-export the EPUB from the original " ++
                "application; this copy is incomplete.",
        }},
    };
}

fn malformedPackageReport() core.Report {
    return .{
        .severity = .err,
        .code = "epub.malformed-package",
        .title = "THE PACKAGE DOCUMENT IS MALFORMED",
        .problem = "The OPF package document is not well-formed XML.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the book",
            .explanation = "Re-export the EPUB from the original " ++
                "application; this copy is damaged.",
        }},
    };
}

fn missingChapterReport() core.Report {
    return .{
        .severity = .warning,
        .code = "epub.missing-chapter",
        .title = "A SPINE CHAPTER IS MISSING",
        .problem = "The spine references chapters whose files are not in " ++
            "the archive.",
        .consequence = "The missing chapters are absent from the output; " ++
            "everything else converted.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Re-export the book",
            .explanation = "Re-export the EPUB from the original " ++
                "application; this copy is incomplete.",
        }},
    };
}

fn skippedSpineReport() core.Report {
    return .{
        .severity = .note,
        .code = "epub.skipped-spine-item",
        .title = "NON-TEXT SPINE ITEMS SKIPPED",
        .problem = "The spine lists items that are not XHTML documents " ++
            "(images, scripts, or unknown ids).",
        .consequence = "Those items are not part of the output; the " ++
            "XHTML chapters converted in order.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the EPUB if the skipped items (covers, " ++
                "embedded media) matter.",
        }},
    };
}
