//! EPUB reader tests: a synthetic two-chapter book built with the stored
//! ZIP helper, plus the refusal corpus (DRM, missing container).

const std = @import("std");
const testing = std.testing;
const core = @import("zenfmt_core");
const ooxml = @import("zenfmt_ooxml");
const reader_mod = @import("reader.zig");

const container_xml =
    \\<?xml version="1.0"?>
    \\<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    \\<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    \\</container>
;

const package_opf =
    \\<?xml version="1.0"?>
    \\<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
    \\<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    \\<dc:title>A Tiny Anthology</dc:title>
    \\<dc:creator>Ada Writer</dc:creator>
    \\<dc:language>en</dc:language>
    \\</metadata>
    \\<manifest>
    \\<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    \\<item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    \\<item id="cover" href="images/cover.png" media-type="image/png"/>
    \\</manifest>
    \\<spine><itemref idref="ch1"/><itemref idref="ch2"/><itemref idref="cover"/></spine>
    \\</package>
;

const ch1_xhtml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<!DOCTYPE html>
    \\<html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>
    \\<body><h1>Chapter One</h1><p>First words &amp; more.</p>
    \\<p><img src="images/pic.png" alt="a diagram"/></p></body></html>
;

const ch2_xhtml =
    \\<html><body><h1>Chapter Two</h1><p>Second words.</p></body></html>
;

fn buildBook(arena: std.mem.Allocator) ![]u8 {
    return ooxml.zip.buildStoredArchive(arena, &.{
        .{ .name = "mimetype", .data = "application/epub+zip" },
        .{ .name = "META-INF/container.xml", .data = container_xml },
        .{ .name = "OEBPS/content.opf", .data = package_opf },
        .{ .name = "OEBPS/ch1.xhtml", .data = ch1_xhtml },
        .{ .name = "OEBPS/text/ch2.xhtml", .data = ch2_xhtml },
        .{ .name = "OEBPS/images/cover.png", .data = "png" },
        .{ .name = "OEBPS/images/pic.png", .data = "png" },
    });
}

const Converted = struct {
    doc: core.ast.Document,
    reports: []const core.Report,
};

fn convertEpub(arena: std.mem.Allocator, bytes: []const u8) !Converted {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "book.epub",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try reader_mod.read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return .{ .doc = doc, .reports = try reports.finalize() };
}

fn failingConvert(arena: std.mem.Allocator, bytes: []const u8) ![]const core.Report {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "book.epub",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try testing.expectError(error.Malformed, reader_mod.read(&ctx));
    return reports.finalize();
}

test "a two-chapter book converts in spine order with metadata" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertEpub(arena, try buildBook(arena));
    const text = converted.doc.store.text.items;

    try testing.expect(std.mem.indexOf(u8, text, "A Tiny Anthology") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Ada Writer") != null);

    // The text pool stores whitespace-split words contiguously.
    const one = std.mem.indexOf(u8, text, "One").?;
    const two = std.mem.indexOf(u8, text, "Two").?;
    try testing.expect(one < two);
    try testing.expect(std.mem.indexOf(u8, text, "&") != null);
    try testing.expect(std.mem.indexOf(u8, text, "more.") != null);

    var headings: u32 = 0;
    for (converted.doc.store.blocks.items(.tag)) |tag| {
        if (tag == .heading) headings += 1;
    }
    try testing.expectEqual(@as(u32, 2), headings);

    // The chapter-relative image source is rebased to its container entry.
    var rebased = false;
    for (converted.doc.store.targets.items) |target| {
        const url = converted.doc.text(target.url);
        if (std.mem.eql(u8, url, "OEBPS/images/pic.png")) rebased = true;
    }
    try testing.expect(rebased);

    // The cover in the spine is skipped with a note, not silently.
    var noted = false;
    for (converted.reports) |item| {
        if (std.mem.eql(u8, item.code, "epub.skipped-spine-item")) noted = true;
    }
    try testing.expect(noted);
}

test "drm-protected books are refused outright" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try ooxml.zip.buildStoredArchive(arena, &.{
        .{ .name = "mimetype", .data = "application/epub+zip" },
        .{ .name = "META-INF/container.xml", .data = container_xml },
        .{ .name = "META-INF/encryption.xml", .data = "<encryption/>" },
        .{ .name = "OEBPS/content.opf", .data = package_opf },
    });
    const reports = try failingConvert(arena, bytes);
    try testing.expect(reports.len >= 1);
    try testing.expectEqualStrings("epub.drm-refused", reports[0].code);
}

test "a zip without the container entry is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try ooxml.zip.buildStoredArchive(arena, &.{
        .{ .name = "mimetype", .data = "application/epub+zip" },
        .{ .name = "OEBPS/content.opf", .data = package_opf },
    });
    const reports = try failingConvert(arena, bytes);
    try testing.expect(reports.len >= 1);
    try testing.expectEqualStrings("epub.missing-container", reports[0].code);
}
