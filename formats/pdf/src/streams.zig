//! PDF stream filters (ZDS: pdf-reader).
//!
//! FlateDecode (zlib-wrapped, with a raw-deflate fallback for sloppy
//! producers), ASCIIHexDecode, ASCII85Decode, and the TIFF/PNG predictors
//! that cross-reference streams rely on. Decompression is budgeted the
//! same way as the ZIP reader: a ratio bound times the encoded size,
//! capped by the entry limit, checked by the streaming reader itself.
//! Anything else (DCT, CCITT, JBIG2, JPX, LZW, Crypt) is reported as an
//! unsupported filter by the caller.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const objects = @import("objects.zig");

pub const Error = error{ OutOfMemory, Malformed, LimitExceeded, UnsupportedFilter };

/// The most filters one stream may chain; real files use one, rarely two.
const max_filter_chain = 4;

pub const DecodeResult = struct {
    data: []const u8,
    /// Set instead of data when an unsupported filter was met; the caller
    /// reports it with the filter's name.
    unsupported: ?[]const u8 = null,
};

/// Applies the stream's /Filter chain to its raw bytes. `resolve` values
/// must already be direct (no references) — the xref layer resolves the
/// dict before calling.
pub fn decode(
    arena: std.mem.Allocator,
    dict: objects.Dict,
    raw: []const u8,
    limits: core.Limits,
) Error!DecodeResult {
    var filters: [max_filter_chain]objects.Object = undefined;
    var parms: [max_filter_chain]?objects.Dict = @splat(null);
    var filter_count: usize = 0;

    if (dict.get("Filter")) |filter_obj| switch (filter_obj) {
        .name => {
            filters[0] = filter_obj;
            filter_count = 1;
        },
        .array => |list| {
            if (list.len > max_filter_chain) return error.LimitExceeded;
            for (list, 0..) |item, i| filters[i] = item;
            filter_count = list.len;
        },
        .null => {},
        else => return error.Malformed,
    };
    if (dict.get("DecodeParms") orelse dict.get("DP")) |parms_obj| switch (parms_obj) {
        .dict => |d| parms[0] = d,
        .array => |list| for (list, 0..) |item, i| {
            if (i >= max_filter_chain) break;
            parms[i] = item.asDict();
        },
        else => {},
    };

    var data = raw;
    for (filters[0..filter_count], parms[0..filter_count]) |filter, parm| {
        if (filter != .name) return error.Malformed;
        const name = filter.name;
        if (std.mem.eql(u8, name, "FlateDecode") or std.mem.eql(u8, name, "Fl")) {
            data = try inflate(arena, data, limits);
        } else if (std.mem.eql(u8, name, "ASCIIHexDecode") or std.mem.eql(u8, name, "AHx")) {
            data = try asciiHex(arena, data);
        } else if (std.mem.eql(u8, name, "ASCII85Decode") or std.mem.eql(u8, name, "A85")) {
            data = try ascii85(arena, data);
        } else {
            return .{ .data = &.{}, .unsupported = name };
        }
        if (parm) |p| data = try applyPredictor(arena, p, data);
    }
    return .{ .data = data };
}

fn inflate(arena: std.mem.Allocator, data: []const u8, limits: core.Limits) Error![]const u8 {
    const budget = @min(
        @max(@as(u64, data.len), 64) * limits.max_compression_ratio,
        limits.max_entry_uncompressed,
    );
    return inflateWith(arena, data, .zlib, budget) catch |err| switch (err) {
        // Some producers write raw deflate despite the spec.
        error.Malformed => inflateWith(arena, data, .raw, budget),
        else => err,
    };
}

fn inflateWith(
    arena: std.mem.Allocator,
    data: []const u8,
    container: std.compress.flate.Container,
    budget: u64,
) Error![]const u8 {
    var input = std.Io.Reader.fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, container, &window);
    const limit = std.math.cast(usize, budget) orelse std.math.maxInt(usize);
    const expanded = decompress.reader.allocRemaining(
        arena,
        .limited(@min(limit +| 1, std.math.maxInt(usize))),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.LimitExceeded,
        error.ReadFailed => return error.Malformed,
    };
    if (expanded.len > budget) return error.LimitExceeded;
    return expanded;
}

fn asciiHex(arena: std.mem.Allocator, data: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending: ?u8 = null;
    for (data) |byte| {
        if (byte == '>') break;
        if (objects.isWhite(byte)) continue;
        const digit = std.fmt.charToDigit(byte, 16) catch return error.Malformed;
        if (pending) |high| {
            try out.append(arena, (high << 4) | digit);
            pending = null;
        } else {
            pending = digit;
        }
    }
    if (pending) |high| try out.append(arena, high << 4);
    return out.items;
}

fn ascii85(arena: std.mem.Allocator, data: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var group: [5]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    // Optional <~ prefix.
    if (std.mem.startsWith(u8, data, "<~")) i = 2;
    while (i < data.len) : (i += 1) {
        const byte = data[i];
        if (objects.isWhite(byte)) continue;
        if (byte == '~') break;
        if (byte == 'z' and n == 0) {
            try out.appendSlice(arena, &.{ 0, 0, 0, 0 });
            continue;
        }
        if (byte < '!' or byte > 'u') return error.Malformed;
        group[n] = byte - '!';
        n += 1;
        if (n == 5) {
            var value: u32 = 0;
            for (group) |digit| value = value *% 85 +% digit;
            try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, value)));
            n = 0;
        }
    }
    if (n == 1) return error.Malformed;
    if (n > 1) {
        // Pad with 'u' (84) and keep n-1 output bytes.
        var value: u32 = 0;
        for (0..5) |k| value = value *% 85 +% (if (k < n) group[k] else 84);
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u32, value));
        try out.appendSlice(arena, bytes[0 .. n - 1]);
    }
    return out.items;
}

/// TIFF predictor 2 and PNG predictors 10–15 (per-row filter bytes).
fn applyPredictor(
    arena: std.mem.Allocator,
    parms: objects.Dict,
    data: []const u8,
) Error![]const u8 {
    const predictor = intParam(parms, "Predictor", 1);
    if (predictor <= 1) return data;
    const colors = @max(intParam(parms, "Colors", 1), 1);
    const bpc = @max(intParam(parms, "BitsPerComponent", 8), 1);
    const columns = @max(intParam(parms, "Columns", 1), 1);
    const sample_bytes64 = @divTrunc(colors * bpc + 7, 8);
    const row_bytes64 = @divTrunc(columns * colors * bpc + 7, 8);
    const sample_bytes = std.math.cast(usize, sample_bytes64) orelse return error.Malformed;
    const row_bytes = std.math.cast(usize, row_bytes64) orelse return error.Malformed;
    if (row_bytes == 0 or sample_bytes == 0) return error.Malformed;

    if (predictor == 2) {
        // TIFF horizontal differencing on whole bytes (bpc >= 8).
        if (bpc < 8) return data;
        const out = try arena.dupe(u8, data);
        var row: usize = 0;
        while (row * row_bytes < out.len) : (row += 1) {
            const line = out[row * row_bytes ..][0..@min(row_bytes, out.len - row * row_bytes)];
            var i: usize = sample_bytes;
            while (i < line.len) : (i += 1) {
                line[i] = line[i] +% line[i - sample_bytes];
            }
        }
        return out;
    }
    if (predictor < 10 or predictor > 15) return error.Malformed;

    const stride = row_bytes + 1;
    const rows = data.len / stride;
    var out = try arena.alloc(u8, rows * row_bytes);
    var previous: []const u8 = &.{};
    for (0..rows) |row| {
        const filter = data[row * stride];
        const src = data[row * stride + 1 ..][0..row_bytes];
        const dst = out[row * row_bytes ..][0..row_bytes];
        for (src, 0..) |byte, i| {
            const left: u8 = if (i >= sample_bytes) dst[i - sample_bytes] else 0;
            const up: u8 = if (previous.len > i) previous[i] else 0;
            const up_left: u8 = if (i >= sample_bytes and previous.len > i - sample_bytes)
                previous[i - sample_bytes]
            else
                0;
            dst[i] = switch (filter) {
                0 => byte,
                1 => byte +% left,
                2 => byte +% up,
                3 => byte +% @as(u8, @truncate((@as(u16, left) + up) / 2)),
                4 => byte +% paeth(left, up, up_left),
                else => return error.Malformed,
            };
        }
        previous = dst;
    }
    return out;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn intParam(parms: objects.Dict, key: []const u8, default: i64) i64 {
    const value = parms.get(key) orelse return default;
    return value.asInt() orelse default;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "flate round-trips through zlib framing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = "Hello, streams! " ** 8;
    const compressed_buffer = try arena.alloc(u8, 4096);
    var fixed = std.Io.Writer.fixed(compressed_buffer);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var compress = try std.compress.flate.Compress.init(
        &fixed,
        window,
        .zlib,
        std.compress.flate.Compress.Options.best,
    );
    try compress.writer.writeAll(plain);
    try compress.finish();

    const dict = objects.Dict{ .entries = &.{
        .{ .key = "Filter", .value = .{ .name = "FlateDecode" } },
    } };
    const result = try decode(arena, dict, fixed.buffered(), .{});
    try testing.expectEqualStrings(plain, result.data);
}

test "ascii hex and ascii85 decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hex = try asciiHex(arena, "48 65 6C 6C 6F>");
    try testing.expectEqualStrings("Hello", hex);
    const a85 = try ascii85(arena, "87cURDZ~>");
    try testing.expectEqualStrings("Hello", a85);
}

test "unsupported filter is surfaced by name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dict = objects.Dict{ .entries = &.{
        .{ .key = "Filter", .value = .{ .name = "DCTDecode" } },
    } };
    const result = try decode(arena, dict, "\xff\xd8", .{});
    try testing.expectEqualStrings("DCTDecode", result.unsupported.?);
}

test "png up predictor reconstructs rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two rows of three bytes; second row is Up-filtered.
    const parms = objects.Dict{ .entries = &.{
        .{ .key = "Predictor", .value = .{ .integer = 12 } },
        .{ .key = "Columns", .value = .{ .integer = 3 } },
    } };
    const filtered = [_]u8{ 0, 1, 2, 3, 2, 1, 1, 1 };
    const out = try applyPredictor(arena, parms, &filtered);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 2, 3, 4 }, out);
}
