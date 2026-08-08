//! Image XObject extraction (ZDS 0011): save embedded images as-is.
//!
//! JPEG (`DCTDecode`) and JPEG 2000 (`JPXDecode`) streams are complete
//! image files already — their raw bytes pass through verbatim. Flate or
//! uncompressed 8-bit DeviceRGB/DeviceGray rasters are wrapped losslessly
//! into a minimal PNG. Anything else (CCITT, JBIG2, indexed or CMYK
//! color) stays omitted and counted, per the record.

const std = @import("std");
const assert = std.debug.assert;
const objects = @import("objects.zig");
const xref = @import("xref.zig");

pub const Extracted = struct {
    bytes: []const u8,
    mime: []const u8,
};

/// Classifies an image XObject and returns its bytes as a standalone
/// image file, or null when the format is one zenfmt leaves omitted.
pub fn extract(file: *xref.File, stream: objects.Stream) xref.Error!?Extracted {
    const dict = stream.dict;

    var filter_names: [4][]const u8 = undefined;
    var filter_count: usize = 0;
    if (try file.dictGet(dict, "Filter")) |filter_obj| switch (filter_obj) {
        .name => |name| {
            filter_names[0] = name;
            filter_count = 1;
        },
        .array => |list| {
            if (list.len > filter_names.len) return null;
            for (list) |item| {
                const resolved = try file.resolve(item);
                if (resolved != .name) return null;
                filter_names[filter_count] = resolved.name;
                filter_count += 1;
            }
        },
        else => return null,
    };

    // Complete image formats pass through untouched — but only when the
    // image filter is the whole chain; a Flate-then-DCT chain would need
    // the prefix decoded and is rare enough to leave omitted.
    if (filter_count == 1) {
        if (std.mem.eql(u8, filter_names[0], "DCTDecode")) {
            return .{ .bytes = stream.raw, .mime = "image/jpeg" };
        }
        if (std.mem.eql(u8, filter_names[0], "JPXDecode")) {
            return .{ .bytes = stream.raw, .mime = "image/jp2" };
        }
    }

    // Raster path: everything the shared stream decoder handles (Flate
    // with predictors, ASCII armors, or no filter at all).
    for (filter_names[0..filter_count]) |name| {
        const supported = std.mem.eql(u8, name, "FlateDecode") or
            std.mem.eql(u8, name, "Fl") or
            std.mem.eql(u8, name, "ASCIIHexDecode") or
            std.mem.eql(u8, name, "AHx") or
            std.mem.eql(u8, name, "ASCII85Decode") or
            std.mem.eql(u8, name, "A85");
        if (!supported) return null;
    }

    const bits = (try file.dictGet(dict, "BitsPerComponent")) orelse return null;
    if ((bits.asInt() orelse 0) != 8) return null;
    const width_obj = (try file.dictGet(dict, "Width")) orelse return null;
    const height_obj = (try file.dictGet(dict, "Height")) orelse return null;
    const width = std.math.cast(u32, width_obj.asInt() orelse 0) orelse return null;
    const height = std.math.cast(u32, height_obj.asInt() orelse 0) orelse return null;
    if (width == 0 or height == 0) return null;
    if (width > 1 << 16 or height > 1 << 16) return null;

    const colorspace = (try file.dictGet(dict, "ColorSpace")) orelse return null;
    const channels: u32 = if (colorspace.isName("DeviceRGB"))
        3
    else if (colorspace.isName("DeviceGray"))
        1
    else
        return null;

    const samples = try file.decodeStream(stream);
    // Computed in 64 bits because the three factors are document-controlled,
    // then narrowed: `usize` is 32 bits on wasm32, where the product of three
    // in-range dimensions can still exceed the addressable range. An image
    // that large is refused rather than truncated.
    const needed = std.math.cast(
        usize,
        @as(u64, width) * height * channels,
    ) orelse return null;
    if (samples.len < needed) return null;

    const png = encodePng(file.arena, width, height, channels, samples[0..needed]) catch
        return error.OutOfMemory;
    return .{ .bytes = png, .mime = "image/png" };
}

// ------------------------------------------------------------------ png

/// A minimal, lossless PNG: 8-bit gray or RGB, filter 0 on every row,
/// IDAT as stored-block zlib. Deterministic, dependency-free.
pub fn encodePng(
    arena: std.mem.Allocator,
    width: u32,
    height: u32,
    channels: u32,
    samples: []const u8,
) error{OutOfMemory}![]const u8 {
    assert(channels == 1 or channels == 3);
    assert(samples.len == @as(u64, width) * height * channels);

    // Raw scanlines, each prefixed by filter byte 0.
    const stride = @as(usize, width) * channels;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(arena);
    try raw.ensureTotalCapacity(arena, (stride + 1) * height);
    var row: usize = 0;
    while (row < height) : (row += 1) {
        raw.appendAssumeCapacity(0);
        raw.appendSliceAssumeCapacity(samples[row * stride ..][0..stride]);
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = if (channels == 3) 2 else 0; // color type
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // interlace
    try writeChunk(arena, &out, "IHDR", &ihdr);

    const idat = try zlibStored(arena, raw.items);
    defer arena.free(idat);
    try writeChunk(arena, &out, "IDAT", idat);
    try writeChunk(arena, &out, "IEND", "");
    return out.items;
}

fn writeChunk(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    kind: *const [4]u8,
    data: []const u8,
) error{OutOfMemory}!void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try out.appendSlice(arena, &length);
    try out.appendSlice(arena, kind);
    try out.appendSlice(arena, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try out.appendSlice(arena, &crc_bytes);
}

/// A zlib container around uncompressed deflate stored blocks: two header
/// bytes, blocks of at most 65535 bytes, Adler-32 of the raw data. Every
/// inflater accepts it, and it needs no compressor state.
fn zlibStored(arena: std.mem.Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.appendSlice(arena, "\x78\x01");
    var offset: usize = 0;
    while (true) {
        const remaining = data.len - offset;
        const block_len: u16 = @intCast(@min(remaining, 65535));
        const is_final: u8 = @intFromBool(remaining <= 65535);
        try out.append(arena, is_final);
        var header: [4]u8 = undefined;
        std.mem.writeInt(u16, header[0..2], block_len, .little);
        std.mem.writeInt(u16, header[2..4], ~block_len, .little);
        try out.appendSlice(arena, &header);
        try out.appendSlice(arena, data[offset..][0..block_len]);
        offset += block_len;
        if (is_final == 1) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(data), .big);
    try out.appendSlice(arena, &adler);
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the png wrapper round-trips a gray raster" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const samples = [_]u8{ 0, 85, 170, 255 };
    const png = try encodePng(arena, 2, 2, 1, &samples);

    try testing.expect(std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n"));
    // IHDR: length 13, then dimensions big-endian.
    try testing.expectEqualStrings("IHDR", png[12..16]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[16..20], .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[20..24], .big));
    try testing.expectEqual(@as(u8, 8), png[24]); // bit depth
    try testing.expectEqual(@as(u8, 0), png[25]); // gray
    try testing.expect(std.mem.indexOf(u8, png, "IDAT") != null);
    try testing.expectEqualStrings("IEND", png[png.len - 8 ..][0..4]);

    // The IDAT zlib payload inflates back to the filtered scanlines.
    const idat_at = std.mem.indexOf(u8, png, "IDAT").?;
    const idat_len = std.mem.readInt(u32, png[idat_at - 4 ..][0..4], .big);
    const zlib_bytes = png[idat_at + 4 ..][0..idat_len];
    // Stored zlib: skip the 2-byte header and 5-byte block header.
    try testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 85, 0, 170, 255 },
        zlib_bytes[2 + 5 ..][0..6],
    );
}
