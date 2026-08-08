//! Resource projection for path output (ZDS 0013, ResourceStore).
//!
//! This phase gives embedded resources deterministic sibling paths and
//! rewrites only image targets bound by `ResourceId`. It performs no I/O;
//! the engine stages and publishes the returned files transactionally.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const manifest = @import("manifest.zig");

pub const File = struct {
    rel_path: []const u8,
    disk_path: []const u8,
    bytes: []const u8,
    digest_hex: manifest.DigestHex,
};

pub fn plan(
    arena: std.mem.Allocator,
    output_path: []const u8,
    doc: ast.Document,
) error{OutOfMemory}![]const File {
    const store: *ast.Store = @constCast(doc.store);
    if (store.resources.items.len == 0) return &.{};

    const base = std.fs.path.basename(output_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot|
        base[0..dot]
    else
        base;
    const parent = std.fs.path.dirname(output_path);
    var files: std.ArrayList(File) = .empty;

    for (store.resources.items, 0..) |resource, index| {
        if (resource.kind == .external) continue;
        const rel_path = try resourcePath(arena, stem, files.items.len, store, resource);
        const disk_path = if (parent) |value|
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ value, rel_path })
        else
            rel_path;
        try rewriteTargets(arena, store, @intCast(index), rel_path);
        try files.append(arena, .{
            .rel_path = rel_path,
            .disk_path = disk_path,
            .bytes = store.resource_bytes.items[resource.bytes.start..resource.bytes.end()],
            .digest_hex = resource.digest_hex,
        });
    }
    return files.items;
}

fn resourcePath(
    arena: std.mem.Allocator,
    stem: []const u8,
    index: usize,
    store: *const ast.Store,
    resource: @import("resources.zig").Resource,
) error{OutOfMemory}![]const u8 {
    const extension = extensionForMime(store.textSlice(resource.mime));
    return std.fmt.allocPrint(
        arena,
        "{s}_media/image-{d}.{s}",
        .{ stem, index + 1, extension },
    );
}

fn rewriteTargets(
    arena: std.mem.Allocator,
    store: *ast.Store,
    resource: u32,
    rel_path: []const u8,
) error{OutOfMemory}!void {
    const url: ast.ByteRange = .{
        .start = @intCast(store.text.items.len),
        .len = @intCast(rel_path.len),
    };
    try store.text.appendSlice(arena, rel_path);
    const tags = store.inlines.items(.tag);
    const payloads = store.inlines.items(.payload);
    for (tags, payloads) |tag, payload_index| {
        if (tag != .image) continue;
        const target = &store.targets.items[payload_index];
        if (target.resource == resource) target.url = url;
    }
}

pub fn manifestEntries(
    arena: std.mem.Allocator,
    doc: *const ast.Document,
    files: []const File,
) error{OutOfMemory}![]const manifest.MediaFile {
    const store = doc.store;
    const entries = try arena.alloc(manifest.MediaFile, store.resources.items.len);
    var embedded: u32 = 0;
    for (store.resources.items, entries) |resource, *entry| {
        const external = resource.kind == .external;
        const path = if (external)
            store.textSlice(resource.source)
        else blk: {
            assert(embedded < files.len);
            defer embedded += 1;
            break :blk files[embedded].rel_path;
        };
        entry.* = .{
            .path = path,
            .source = store.textSlice(resource.source),
            .mime = store.textSlice(resource.mime),
            .digest_hex = resource.digest_hex,
            .external = external,
            .pixel_width = resource.pixel_width,
            .pixel_height = resource.pixel_height,
            .alt = store.textSlice(resource.alt),
        };
    }
    assert(embedded == files.len);
    return entries;
}

fn extensionForMime(mime: []const u8) []const u8 {
    const table = [_]struct { mime: []const u8, extension: []const u8 }{
        .{ .mime = "image/jpeg", .extension = "jpg" },
        .{ .mime = "image/png", .extension = "png" },
        .{ .mime = "image/gif", .extension = "gif" },
        .{ .mime = "image/jp2", .extension = "jp2" },
        .{ .mime = "image/jpx", .extension = "jpf" },
        .{ .mime = "image/tiff", .extension = "tif" },
        .{ .mime = "image/bmp", .extension = "bmp" },
        .{ .mime = "image/svg+xml", .extension = "svg" },
        .{ .mime = "image/webp", .extension = "webp" },
        .{ .mime = "image/emf", .extension = "emf" },
        .{ .mime = "image/wmf", .extension = "wmf" },
    };
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(row.mime, mime)) return row.extension;
    }
    return "bin";
}
