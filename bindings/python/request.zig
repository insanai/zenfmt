//! Request decoding for the Python bridge (ZDS 0014).
//!
//! Options cross the ABI as one versioned UTF-8 JSON object; large byte
//! sequences cross as pointer-length slices. The Python layer validates
//! everything first, so any rejection here is an embedding defect surfaced
//! as the `invalid_request` status, never a document failure.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("zenfmt_core");
const abi = @import("abi.zig");
const names = @import("zenfmt_names");

pub const schema_version = 1;

pub const DecodeError = error{ InvalidRequest, OutOfMemory };

/// The decoded engine options plus the display problem for rejections.
pub const Decoded = struct {
    options: core.ConvertOptions,
    /// Borrowed from the caller's request for the duration of the call:
    /// input bytes only. Everything else is arena-owned copies.
    problem: []const u8 = "",
};

const OptionsJson = struct {
    schema: u32,
    input: struct {
        kind: []const u8,
        name: ?[]const u8 = null,
    },
    output: struct {
        kind: []const u8,
        artifact_name: ?[]const u8 = null,
    },
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    strict: []const u8 = "off",
    overwrite: bool = false,
    preserve_facets: bool = false,
    limits: ?std.json.Value = null,
};

/// Decodes one request. `arena` is the result arena: every string the
/// engine may retain is copied into it so no pointer into caller memory
/// survives the convert call, except the input document bytes themselves,
/// which the engine only reads during conversion.
pub fn decode(
    arena: std.mem.Allocator,
    request: *const abi.Request,
) DecodeError!Decoded {
    const options_ptr = request.options_json.ptr orelse
        return error.InvalidRequest;
    if (request.options_json.len > 1024 * 1024) return error.InvalidRequest;
    const options_len = std.math.cast(usize, request.options_json.len) orelse
        return error.InvalidRequest;
    // Copy first so parsed strings never borrow caller memory.
    const options_bytes = try arena.dupe(u8, options_ptr[0..options_len]);
    if (!std.unicode.utf8ValidateSlice(options_bytes)) {
        return error.InvalidRequest;
    }

    const parsed = std.json.parseFromSliceLeaky(
        OptionsJson,
        arena,
        options_bytes,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };
    if (parsed.schema != schema_version) return error.InvalidRequest;

    const input = try decodeInput(arena, request, parsed);
    const output = try decodeOutput(arena, request, parsed);
    const strict = decodeStrict(parsed.strict) orelse
        return error.InvalidRequest;
    const limit_values = try decodeLimits(arena, parsed.limits);

    return .{ .options = .{
        .input = input,
        .output = output,
        .from = if (parsed.from) |value| try arena.dupe(u8, value) else null,
        .to = if (parsed.to) |value| try arena.dupe(u8, value) else null,
        .limits = limit_values,
        .overwrite = parsed.overwrite,
        .strict = strict,
        .preserve_facets = parsed.preserve_facets,
    } };
}

fn decodeInput(
    arena: std.mem.Allocator,
    request: *const abi.Request,
    parsed: OptionsJson,
) DecodeError!core.InputSpec {
    if (std.mem.eql(u8, parsed.input.kind, "path")) {
        return .{ .path = try decodePath(arena, request.input_path) };
    }
    if (std.mem.eql(u8, parsed.input.kind, "bytes")) {
        const name = parsed.input.name orelse return error.InvalidRequest;
        if (!names.validDisplayName(name)) return error.InvalidRequest;
        const len = std.math.cast(usize, request.input_bytes.len) orelse
            return error.InvalidRequest;
        const data: []const u8 = if (request.input_bytes.ptr) |ptr|
            ptr[0..len]
        else if (len == 0)
            &.{}
        else
            return error.InvalidRequest;
        return .{ .bytes = .{
            .name = try arena.dupe(u8, name),
            .data = data,
        } };
    }
    return error.InvalidRequest;
}

fn decodeOutput(
    arena: std.mem.Allocator,
    request: *const abi.Request,
    parsed: OptionsJson,
) DecodeError!core.OutputSpec {
    if (std.mem.eql(u8, parsed.output.kind, "memory")) {
        const name = parsed.output.artifact_name orelse
            return error.InvalidRequest;
        if (!names.validDisplayName(name)) return error.InvalidRequest;
        return .{ .memory = .{
            .artifact_name = try arena.dupe(u8, name),
        } };
    }
    if (std.mem.eql(u8, parsed.output.kind, "path")) {
        return .{ .path = try decodePath(arena, request.output_path) };
    }
    return error.InvalidRequest;
}

/// Native path decoding: raw bytes on POSIX, UTF-16LE code units on
/// Windows re-encoded as WTF-8. Always copied into the arena.
fn decodePath(
    arena: std.mem.Allocator,
    slice: abi.PathSlice,
) DecodeError![]const u8 {
    const ptr = slice.ptr orelse return error.InvalidRequest;
    const len = std.math.cast(usize, slice.len) orelse
        return error.InvalidRequest;
    if (len == 0 or len > 32 * 1024) return error.InvalidRequest;
    if (builtin.os.tag == .windows) {
        const byte_len = std.math.mul(usize, len, @sizeOf(u16)) catch
            return error.InvalidRequest;
        const source: [*]const u8 = @ptrCast(ptr);
        const wide = try arena.alloc(u16, len);
        // `PathSlice` deliberately promises no alignment. ctypes and other C
        // callers may provide a byte buffer at any address, so copy its
        // UTF-16LE representation before giving it to the Unicode decoder.
        @memcpy(std.mem.sliceAsBytes(wide), source[0..byte_len]);
        const path = std.unicode.wtf16LeToWtf8Alloc(
            arena,
            wide,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (std.mem.indexOfScalar(u8, path, 0) != null) {
            return error.InvalidRequest;
        }
        return path;
    }
    const bytes: [*]const u8 = @ptrCast(ptr);
    const path = bytes[0..len];
    if (std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.InvalidRequest;
    }
    return try arena.dupe(u8, path);
}

test "Windows path decoding accepts unaligned UTF-16LE" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const expected = "folder/note.md";
    const encoded = std.unicode.wtf8ToWtf16LeStringLiteral(expected);
    const encoded_bytes = std.mem.sliceAsBytes(encoded);
    var storage: [64]u8 align(2) = undefined;
    @memcpy(storage[1..][0..encoded_bytes.len], encoded_bytes);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try decodePath(arena.allocator(), .{
        .ptr = @ptrCast(&storage[1]),
        .len = encoded.len,
    });
    try std.testing.expectEqualStrings(expected, decoded);
}

fn decodeStrict(text: []const u8) ?core.Strictness {
    if (std.mem.eql(u8, text, "off")) return .off;
    return core.Strictness.parse(text);
}

fn decodeLimits(
    arena: std.mem.Allocator,
    value: ?std.json.Value,
) DecodeError!core.Limits {
    var limit_values: core.Limits = .{};
    const object = switch (value orelse return limit_values) {
        .object => |object| object,
        .null => return limit_values,
        else => return error.InvalidRequest,
    };
    var it = object.iterator();
    while (it.next()) |entry| {
        const field = entry.value_ptr.*;
        if (field != .integer or field.integer <= 0) {
            return error.InvalidRequest;
        }
        const text = try std.fmt.allocPrint(
            arena,
            "{s}={d}",
            .{ entry.key_ptr.*, field.integer },
        );
        limit_values.override(text) catch return error.InvalidRequest;
    }
    return limit_values;
}
