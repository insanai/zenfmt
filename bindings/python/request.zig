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
        if (!validDisplayName(name)) return error.InvalidRequest;
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
        if (!validDisplayName(name)) return error.InvalidRequest;
        return .{ .memory = .{
            .artifact_name = try arena.dupe(u8, name),
        } };
    }
    if (std.mem.eql(u8, parsed.output.kind, "path")) {
        return .{ .path = try decodePath(arena, request.output_path) };
    }
    return error.InvalidRequest;
}

/// A display basename: non-empty, no directory separator, no NUL or other
/// control character. Prevents an in-memory caller from steering resource
/// naming or diagnostics through path syntax.
fn validDisplayName(name: []const u8) bool {
    if (name.len == 0 or name.len > 1024) return false;
    for (name) |byte| switch (byte) {
        0...0x1f, 0x7f, '/', '\\' => return false,
        else => {},
    };
    return true;
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
        const wide: [*]const u16 = @ptrCast(@alignCast(ptr));
        const path = std.unicode.wtf16LeToWtf8Alloc(
            arena,
            wide[0..len],
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

test "display names refuse separators and control bytes" {
    try std.testing.expect(validDisplayName("report.docx"));
    try std.testing.expect(validDisplayName("übersicht.md"));
    try std.testing.expect(!validDisplayName(""));
    try std.testing.expect(!validDisplayName("a/b.md"));
    try std.testing.expect(!validDisplayName("a\\b.md"));
    try std.testing.expect(!validDisplayName("a\x00b"));
    try std.testing.expect(!validDisplayName("a\nb"));
}
