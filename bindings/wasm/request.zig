//! Request decoding for the browser ABI (ZDS 0015, Low-level ABI).
//!
//! The schema carries browser authority only. There is no path on either
//! side and no overwrite flag, and memory is the only output mode, so no
//! output union is exposed: a browser caller cannot express a request the
//! module has no authority to satisfy.
//!
//! Unlike the Python bridge, the caller here is arbitrary page script rather
//! than a layer we ship. So every field is validated on this side, the
//! request is copied before it is parsed, and an unknown field is a refusal
//! rather than something ignored.

const std = @import("std");
const core = @import("zenfmt_core");
const names = @import("zenfmt_names");
const profile = @import("profile.zig");

pub const schema_version = 1;

/// A browser options blob is a few hundred bytes. The cap is small on
/// purpose: it costs a hostile page nothing to send a megabyte of JSON, and
/// nothing legitimate needs one.
pub const max_request_bytes = 64 * 1024;

pub const DecodeError = error{ InvalidRequest, OutOfMemory };

/// Why a request was refused, so the ABI can report the specific thing that
/// is wrong instead of one undifferentiated "malformed".
pub const Rejection = enum {
    malformed,
    unknown_schema,
    invalid_source_name,
    limit_above_profile,
    unknown_limit,
};

pub const Decoded = struct {
    options: core.ConvertOptions,
};

const RequestJson = struct {
    schema: u32,
    name: []const u8,
    artifact_name: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    strict: []const u8 = "off",
    preserve_facets: bool = false,
    limits: ?std.json.Value = null,
};

/// Decodes one request. `arena` is the result arena: every string the engine
/// may retain is copied into it, so no pointer into caller memory survives
/// the convert call except the input document bytes, which the engine only
/// reads while converting.
pub fn decode(
    arena: std.mem.Allocator,
    request_bytes: []const u8,
    input: []const u8,
    rejection: *Rejection,
) DecodeError!Decoded {
    rejection.* = .malformed;
    if (request_bytes.len > max_request_bytes) return error.InvalidRequest;

    // Copied before parsing so no parsed string borrows caller memory that
    // the page is free to overwrite the moment this call returns.
    const owned = try arena.dupe(u8, request_bytes);
    if (!std.unicode.utf8ValidateSlice(owned)) return error.InvalidRequest;

    const parsed = std.json.parseFromSliceLeaky(
        RequestJson,
        arena,
        owned,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };

    if (parsed.schema != schema_version) {
        rejection.* = .unknown_schema;
        return error.InvalidRequest;
    }

    const artifact_name = parsed.artifact_name orelse parsed.name;
    if (!names.validDisplayName(parsed.name) or
        !names.validDisplayName(artifact_name))
    {
        rejection.* = .invalid_source_name;
        return error.InvalidRequest;
    }

    const strict = decodeStrict(parsed.strict) orelse return error.InvalidRequest;
    const limits = try decodeLimits(parsed.limits, rejection);

    return .{ .options = .{
        .input = .{ .bytes = .{
            .name = try arena.dupe(u8, parsed.name),
            .data = input,
        } },
        .output = .{ .memory = .{
            .artifact_name = try arena.dupe(u8, artifact_name),
        } },
        .from = if (parsed.from) |value| try arena.dupe(u8, value) else null,
        .to = if (parsed.to) |value| try arena.dupe(u8, value) else null,
        .limits = limits,
        .strict = strict,
        .preserve_facets = parsed.preserve_facets,
    } };
}

fn decodeStrict(text: []const u8) ?core.Strictness {
    if (std.mem.eql(u8, text, "off")) return .off;
    return core.Strictness.parse(text);
}

/// Overrides start from the browser profile, not the engine defaults, and may
/// only lower it further.
fn decodeLimits(
    value: ?std.json.Value,
    rejection: *Rejection,
) DecodeError!core.Limits {
    var values = profile.browser;
    const object = switch (value orelse return values) {
        .object => |object| object,
        .null => return values,
        else => return error.InvalidRequest,
    };
    var it = object.iterator();
    while (it.next()) |entry| {
        const field = entry.value_ptr.*;
        if (field != .integer or field.integer <= 0) return error.InvalidRequest;
        const name = entry.key_ptr.*;
        if (!profile.known(name)) {
            rejection.* = .unknown_limit;
            return error.InvalidRequest;
        }
        if (profile.apply(&values, name, @intCast(field.integer)) != null) {
            rejection.* = .limit_above_profile;
            return error.InvalidRequest;
        }
    }
    return values;
}

const testing = std.testing;

fn decodeForTest(arena: std.mem.Allocator, json: []const u8) !Decoded {
    var rejection: Rejection = .malformed;
    return decode(arena, json, "# T\n", &rejection);
}

test "a minimal request decodes to a byte-in, memory-out conversion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = try decodeForTest(
        arena.allocator(),
        \\{"schema":1,"name":"note.md"}
        ,
    );
    try testing.expectEqualStrings("note.md", decoded.options.input.bytes.name);
    try testing.expectEqualStrings(
        "note.md",
        decoded.options.output.memory.artifact_name,
    );
    // Absent an override, the browser profile is what applies.
    try testing.expectEqual(
        profile.browser.max_input_bytes,
        decoded.options.limits.max_input_bytes,
    );
}

test "an unknown field is refused rather than ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidRequest, decodeForTest(
        arena.allocator(),
        \\{"schema":1,"name":"note.md","overwrite":true}
        ,
    ));
}

test "an unknown schema version is named as such" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var rejection: Rejection = .malformed;
    try testing.expectError(error.InvalidRequest, decode(
        arena.allocator(),
        \\{"schema":99,"name":"note.md"}
    ,
        "",
        &rejection,
    ));
    try testing.expectEqual(Rejection.unknown_schema, rejection);
}

test "a source name carrying path syntax is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var rejection: Rejection = .malformed;
    try testing.expectError(error.InvalidRequest, decode(
        arena.allocator(),
        \\{"schema":1,"name":"../etc/passwd"}
    ,
        "",
        &rejection,
    ));
    try testing.expectEqual(Rejection.invalid_source_name, rejection);
}

test "a limit override may lower but not raise the browser profile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const lowered = try decodeForTest(
        arena.allocator(),
        \\{"schema":1,"name":"note.md","limits":{"max_nodes":1000}}
        ,
    );
    try testing.expectEqual(@as(u32, 1000), lowered.options.limits.max_nodes);

    var rejection: Rejection = .malformed;
    try testing.expectError(error.InvalidRequest, decode(
        arena.allocator(),
        \\{"schema":1,"name":"note.md","limits":{"max_input_bytes":999999999}}
    ,
        "",
        &rejection,
    ));
    try testing.expectEqual(Rejection.limit_above_profile, rejection);
}

test "an oversized request is refused before it is parsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const huge = try testing.allocator.alloc(u8, max_request_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, ' ');
    var rejection: Rejection = .malformed;
    try testing.expectError(
        error.InvalidRequest,
        decode(arena.allocator(), huge, "", &rejection),
    );
}

test "invalid UTF-8 in the request is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var rejection: Rejection = .malformed;
    try testing.expectError(error.InvalidRequest, decode(
        arena.allocator(),
        "{\"schema\":1,\"name\":\"\xff\xfe\"}",
        "",
        &rejection,
    ));
}
