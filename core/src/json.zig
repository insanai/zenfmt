//! The zenfmt canonical JSON profile, version 1 (ZDS 0013, Core Contract
//! Repairs).
//!
//! UTF-8 throughout; no insignificant whitespace; object keys unique and
//! in bytewise order; exact integer spelling; shortest round-trip floats;
//! a fixed escape set. This is zenfmt's own deterministic profile, not RFC
//! 8785 (JCS): JCS orders keys by UTF-16 code units and forces every
//! number through an IEEE-754 double, which cannot carry the exact 64-bit
//! counts the manifest records. The writer emits canonically by
//! construction and returns errors for key order; the parser is a bounded,
//! non-recursive loop over `std.json.Scanner` so hostile manifests are
//! refused within limits rather than recursed into.

const std = @import("std");
const assert = std.debug.assert;
const limits_mod = @import("limits.zig");

pub const WriteError = error{
    OutOfMemory,
    InvalidState,
    InvalidUtf8,
    NonCanonicalKey,
    InvalidNumber,
    InvalidRawJson,
    TooDeep,
};

// -------------------------------------------------------------- writing

/// A canonical JSON emitter into a growable buffer. Object keys must be
/// emitted in bytewise order; the writer asserts it.
pub const WriteStream = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Raw object keys for canonical bytewise comparisons. Only one key per
    /// open object is retained, so memory is O(nesting depth), not fields.
    keys: std.ArrayList(u8) = .empty,
    frames: [limits_mod.max_depth_hard_cap]Frame = undefined,
    depth: u32 = 0,
    /// Set when a value is expected immediately (array element slot filled,
    /// or after a key).
    value_expected: bool = true,

    const Frame = struct {
        kind: enum { object, array },
        count: u32,
        key_base: u32 = 0,
        last_key_start: u32 = 0,
        last_key_len: u32 = 0,
    };

    pub fn init(gpa: std.mem.Allocator) WriteStream {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *WriteStream) void {
        w.bytes.deinit(w.gpa);
        w.keys.deinit(w.gpa);
        w.* = undefined;
    }

    pub fn toOwnedSlice(w: *WriteStream) WriteError![]u8 {
        if (w.depth != 0 or w.value_expected) return error.InvalidState;
        return w.bytes.toOwnedSlice(w.gpa);
    }

    pub fn beginObject(w: *WriteStream) WriteError!void {
        try w.beforeValue();
        if (w.depth >= limits_mod.max_depth_hard_cap) return error.TooDeep;
        w.frames[w.depth] = .{
            .kind = .object,
            .count = 0,
            .key_base = @intCast(w.keys.items.len),
        };
        w.depth += 1;
        w.value_expected = false;
        try w.bytes.append(w.gpa, '{');
    }

    pub fn endObject(w: *WriteStream) WriteError!void {
        if (w.depth == 0) return error.InvalidState;
        if (w.frames[w.depth - 1].kind != .object) return error.InvalidState;
        if (w.value_expected) return error.InvalidState;
        const key_base = w.frames[w.depth - 1].key_base;
        w.depth -= 1;
        w.keys.items.len = key_base;
        try w.bytes.append(w.gpa, '}');
    }

    pub fn beginArray(w: *WriteStream) WriteError!void {
        try w.beforeValue();
        if (w.depth >= limits_mod.max_depth_hard_cap) return error.TooDeep;
        w.frames[w.depth] = .{ .kind = .array, .count = 0 };
        w.depth += 1;
        w.value_expected = false;
        try w.bytes.append(w.gpa, '[');
    }

    pub fn endArray(w: *WriteStream) WriteError!void {
        if (w.depth == 0) return error.InvalidState;
        if (w.frames[w.depth - 1].kind != .array) return error.InvalidState;
        w.depth -= 1;
        try w.bytes.append(w.gpa, ']');
    }

    /// Emits an object key. Keys must arrive in strictly increasing bytewise
    /// order — the canonical order is a caller obligation the stream checks.
    pub fn field(w: *WriteStream, key: []const u8) WriteError!void {
        if (w.depth == 0) return error.InvalidState;
        const frame = &w.frames[w.depth - 1];
        if (frame.kind != .object or w.value_expected) return error.InvalidState;
        if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidUtf8;

        if (frame.count > 0) {
            const last = w.keys.items[frame.last_key_start..][0..frame.last_key_len];
            if (std.mem.order(u8, last, key) != .lt) return error.NonCanonicalKey;
            try w.bytes.append(w.gpa, ',');
        }
        w.keys.items.len = frame.key_base;
        frame.last_key_start = @intCast(w.keys.items.len);
        frame.last_key_len = @intCast(key.len);
        try w.keys.appendSlice(w.gpa, key);
        frame.count += 1;
        try w.appendString(key);
        try w.bytes.append(w.gpa, ':');
        w.value_expected = true;
    }

    pub fn string(w: *WriteStream, value: []const u8) WriteError!void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        try w.beforeValue();
        try w.appendString(value);
        w.value_expected = false;
    }

    pub fn integer(w: *WriteStream, value: i64) WriteError!void {
        try w.beforeValue();
        var buffer: [24]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
        try w.bytes.appendSlice(w.gpa, rendered);
        w.value_expected = false;
    }

    pub fn float(w: *WriteStream, value: f64) WriteError!void {
        if (!std.math.isFinite(value)) return error.InvalidNumber;
        try w.beforeValue();
        var buffer: [32]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
        try w.bytes.appendSlice(w.gpa, rendered);
        w.value_expected = false;
    }

    pub fn boolean(w: *WriteStream, value: bool) WriteError!void {
        try w.beforeValue();
        try w.bytes.appendSlice(w.gpa, if (value) "true" else "false");
        w.value_expected = false;
    }

    pub fn nullValue(w: *WriteStream) WriteError!void {
        try w.beforeValue();
        try w.bytes.appendSlice(w.gpa, "null");
        w.value_expected = false;
    }

    /// Splices bytes that are already canonical JSON: a carried plugin
    /// namespace re-encoded by `writeValue`.
    pub fn raw(w: *WriteStream, canonical: []const u8) WriteError!void {
        if (canonical.len == 0) return error.InvalidRawJson;
        if (!std.unicode.utf8ValidateSlice(canonical)) return error.InvalidUtf8;
        if (!try std.json.validate(w.gpa, canonical)) return error.InvalidRawJson;
        try w.beforeValue();
        try w.bytes.appendSlice(w.gpa, canonical);
        w.value_expected = false;
    }

    fn beforeValue(w: *WriteStream) WriteError!void {
        if (w.depth == 0) {
            if (!w.value_expected) return error.InvalidState;
            return;
        }
        const frame = &w.frames[w.depth - 1];
        switch (frame.kind) {
            .object => if (!w.value_expected) return error.InvalidState,
            .array => {
                if (w.value_expected) return error.InvalidState;
                if (frame.count > 0) try w.bytes.append(w.gpa, ',');
                frame.count += 1;
            },
        }
    }

    fn appendString(w: *WriteStream, value: []const u8) error{OutOfMemory}!void {
        try w.bytes.append(w.gpa, '"');
        for (value) |byte| {
            switch (byte) {
                '"' => try w.bytes.appendSlice(w.gpa, "\\\""),
                '\\' => try w.bytes.appendSlice(w.gpa, "\\\\"),
                '\n' => try w.bytes.appendSlice(w.gpa, "\\n"),
                '\r' => try w.bytes.appendSlice(w.gpa, "\\r"),
                '\t' => try w.bytes.appendSlice(w.gpa, "\\t"),
                0x08 => try w.bytes.appendSlice(w.gpa, "\\b"),
                0x0c => try w.bytes.appendSlice(w.gpa, "\\f"),
                0x00...0x07, 0x0b, 0x0e...0x1f => {
                    var buffer: [6]u8 = undefined;
                    const rendered = std.fmt.bufPrint(
                        &buffer,
                        "\\u{x:0>4}",
                        .{byte},
                    ) catch unreachable;
                    try w.bytes.appendSlice(w.gpa, rendered);
                },
                else => try w.bytes.append(w.gpa, byte),
            }
        }
        try w.bytes.append(w.gpa, '"');
    }
};

// -------------------------------------------------------------- parsing

pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    array: []Value,
    object: []Member,
};

pub const Member = struct {
    key: []const u8,
    value: Value,
};

pub const ParseError = error{ OutOfMemory, Malformed, TooDeep, TooLarge };

const Partial = struct {
    members: std.ArrayList(Member),
    elements: std.ArrayList(Value),
    keys: std.StringHashMapUnmanaged(void),
    kind: Kind,
    pending_key: ?[]const u8,

    const Kind = enum { object, array };
};

const ParsedToken = union(enum) {
    stop,
    next,
    value: Value,
};

/// Parses untrusted JSON into an arena-allocated `Value` under explicit
/// byte and depth limits. Non-recursive: one explicit container stack.
pub fn parse(
    arena: std.mem.Allocator,
    bytes: []const u8,
    max_bytes: u32,
    max_depth: u32,
) ParseError!Value {
    if (bytes.len > max_bytes) return error.TooLarge;
    assert(max_depth <= limits_mod.max_depth_hard_cap);

    var scanner = std.json.Scanner.initCompleteInput(arena, bytes);
    defer scanner.deinit();

    var stack: std.ArrayList(Partial) = .empty;
    defer stack.deinit(arena);
    var result: ?Value = null;

    while (true) {
        const token = scanner.nextAlloc(arena, .alloc_if_needed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
        switch (try processToken(arena, token, &stack, max_depth)) {
            .stop => break,
            .next => continue,
            .value => |value| try attachValue(arena, &stack, &result, value),
        }
    }
    if (stack.items.len != 0) return error.Malformed;
    return result orelse error.Malformed;
}

fn processToken(
    arena: std.mem.Allocator,
    token: anytype,
    stack: *std.ArrayList(Partial),
    max_depth: u32,
) ParseError!ParsedToken {
    return switch (token) {
        .end_of_document => .stop,
        .object_begin => try pushPartial(arena, stack, max_depth, .object),
        .array_begin => try pushPartial(arena, stack, max_depth, .array),
        .object_end => .{ .value = try closePartial(arena, stack, .object) },
        .array_end => .{ .value = try closePartial(arena, stack, .array) },
        .string, .allocated_string => |slice| try stringToken(
            arena,
            stack,
            slice,
        ),
        .number, .allocated_number => |slice| .{
            .value = parseNumber(slice) orelse return error.Malformed,
        },
        .true => .{ .value = .{ .boolean = true } },
        .false => .{ .value = .{ .boolean = false } },
        .null => .{ .value = .null },
        .partial_number, .partial_string => unreachable,
        .partial_string_escaped_1,
        .partial_string_escaped_2,
        .partial_string_escaped_3,
        .partial_string_escaped_4,
        => unreachable,
    };
}

fn pushPartial(
    arena: std.mem.Allocator,
    stack: *std.ArrayList(Partial),
    max_depth: u32,
    kind: Partial.Kind,
) ParseError!ParsedToken {
    if (stack.items.len >= max_depth) return error.TooDeep;
    try stack.append(arena, .{
        .members = .empty,
        .elements = .empty,
        .keys = .empty,
        .kind = kind,
        .pending_key = null,
    });
    return .next;
}

fn closePartial(
    arena: std.mem.Allocator,
    stack: *std.ArrayList(Partial),
    expected: Partial.Kind,
) ParseError!Value {
    var frame = stack.pop() orelse return error.Malformed;
    defer frame.keys.deinit(arena);
    if (frame.kind != expected or frame.pending_key != null) {
        frame.members.deinit(arena);
        frame.elements.deinit(arena);
        return error.Malformed;
    }
    return switch (expected) {
        .object => blk: {
            frame.elements.deinit(arena);
            break :blk .{ .object = try frame.members.toOwnedSlice(arena) };
        },
        .array => blk: {
            frame.members.deinit(arena);
            break :blk .{ .array = try frame.elements.toOwnedSlice(arena) };
        },
    };
}

fn stringToken(
    arena: std.mem.Allocator,
    stack: *std.ArrayList(Partial),
    slice: []const u8,
) ParseError!ParsedToken {
    if (stack.items.len == 0) return .{ .value = .{ .string = slice } };
    const top = &stack.items[stack.items.len - 1];
    if (top.kind != .object or top.pending_key != null) {
        return .{ .value = .{ .string = slice } };
    }
    const entry = try top.keys.getOrPut(arena, slice);
    if (entry.found_existing) return error.Malformed;
    top.pending_key = slice;
    return .next;
}

fn attachValue(
    arena: std.mem.Allocator,
    stack: *std.ArrayList(Partial),
    result: *?Value,
    value: Value,
) ParseError!void {
    if (stack.items.len == 0) {
        if (result.* != null) return error.Malformed;
        result.* = value;
        return;
    }
    const top = &stack.items[stack.items.len - 1];
    switch (top.kind) {
        .object => {
            const key = top.pending_key orelse return error.Malformed;
            top.pending_key = null;
            try top.members.append(arena, .{ .key = key, .value = value });
        },
        .array => try top.elements.append(arena, value),
    }
}

fn parseNumber(slice: []const u8) ?Value {
    const is_float = std.mem.indexOfAny(u8, slice, ".eE") != null;
    if (!is_float) {
        if (std.fmt.parseInt(i64, slice, 10)) |int| {
            return .{ .integer = int };
        } else |_| {}
    }
    const float = std.fmt.parseFloat(f64, slice) catch return null;
    if (!std.math.isFinite(float)) return null;
    return .{ .float = float };
}

// --------------------------------------------------------- re-encoding

const EncodeTask = union(enum) {
    value: Value,
    member: Member,
    end_object,
    end_array,
};

/// Re-encodes a parsed value canonically: object members sorted bytewise,
/// unknown fields preserved value-for-value. Non-recursive.
pub fn writeValue(w: *WriteStream, root: Value) WriteError!void {
    var tasks: std.ArrayList(EncodeTask) = .empty;
    defer tasks.deinit(w.gpa);
    try tasks.append(w.gpa, .{ .value = root });

    while (tasks.pop()) |task| {
        switch (task) {
            .end_object => try w.endObject(),
            .end_array => try w.endArray(),
            .member => |member| {
                try w.field(member.key);
                try writeLeafOrPush(w, &tasks, member.value);
            },
            .value => |value| try writeLeafOrPush(w, &tasks, value),
        }
    }
}

fn writeLeafOrPush(
    w: *WriteStream,
    tasks: *std.ArrayList(EncodeTask),
    value: Value,
) WriteError!void {
    switch (value) {
        .null => try w.nullValue(),
        .boolean => |b| try w.boolean(b),
        .integer => |i| try w.integer(i),
        .float => |f| try w.float(f),
        .string => |s| try w.string(s),
        .array => |elements| {
            try w.beginArray();
            try tasks.append(w.gpa, .end_array);
            var i = elements.len;
            while (i > 0) {
                i -= 1;
                try tasks.append(w.gpa, .{ .value = elements[i] });
            }
        },
        .object => |members| {
            try w.beginObject();
            try tasks.append(w.gpa, .end_object);
            const sorted = try w.gpa.dupe(Member, members);
            std.mem.sort(Member, sorted, {}, memberLessThan);
            var i = sorted.len;
            while (i > 0) {
                i -= 1;
                try tasks.append(w.gpa, .{ .member = sorted[i] });
            }
            w.gpa.free(sorted);
        },
    }
}

fn memberLessThan(_: void, lhs: Member, rhs: Member) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the write stream emits canonical bytes" {
    var w = WriteStream.init(testing.allocator);
    defer w.deinit();

    try w.beginObject();
    try w.field("alpha");
    try w.integer(-3);
    try w.field("beta");
    try w.beginArray();
    try w.string("a\"b");
    try w.boolean(true);
    try w.nullValue();
    try w.endArray();
    try w.endObject();

    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        "{\"alpha\":-3,\"beta\":[\"a\\\"b\",true,null]}",
        bytes,
    );
}

test "parse and re-encode canonicalizes key order and whitespace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const input = "{ \"z\": 1, \"a\": { \"b\": [1.5, 2] } }";
    const value = try parse(arena, input, 1024, 8);

    var w = WriteStream.init(testing.allocator);
    defer w.deinit();
    try writeValue(&w, value);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\"a\":{\"b\":[1.5,2]},\"z\":1}", bytes);
}

test "parse refuses depth and size beyond the limits" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.TooDeep, parse(arena, "[[[[1]]]]", 1024, 3));
    try testing.expectError(error.TooLarge, parse(arena, "[1,2,3]", 4, 8));
    try testing.expectError(error.Malformed, parse(arena, "{\"a\":}", 1024, 8));
}

test "parse refuses duplicate object keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(
        error.Malformed,
        parse(arena_state.allocator(), "{\"same\":1,\"same\":2}", 1024, 8),
    );
}

test "scanner allocation failure remains out of memory" {
    const input = "{\"escaped\":\"\\u0061\\u0062\\u0063\\u0064\"}";
    var reached_end = false;
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var arena_state = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena_state.deinit();
        const result = parse(arena_state.allocator(), input, 128, 8);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            _ = try result;
            reached_end = true;
            break;
        }
    }
    try testing.expect(reached_end);
}

test "canonical keys use UTF-8 byte order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try parse(arena, "{\"𐀀\":2,\"\":1}", 1024, 8);

    var stream = WriteStream.init(testing.allocator);
    defer stream.deinit();
    try writeValue(&stream, value);
    const canonical = try stream.toOwnedSlice();
    defer testing.allocator.free(canonical);
    try testing.expectEqualStrings("{\"\":1,\"𐀀\":2}", canonical);
}

test "writer correctness checks survive ReleaseFast" {
    var stream = WriteStream.init(testing.allocator);
    defer stream.deinit();

    try stream.beginObject();
    try stream.field("z");
    try stream.integer(1);
    try testing.expectError(error.NonCanonicalKey, stream.field("a"));

    var invalid = WriteStream.init(testing.allocator);
    defer invalid.deinit();
    try testing.expectError(error.InvalidUtf8, invalid.string("\xff"));
    try testing.expectError(error.InvalidNumber, invalid.float(std.math.nan(f64)));
    try testing.expectError(error.InvalidRawJson, invalid.raw("{broken"));
}
