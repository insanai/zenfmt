//! Canonical JSON (ZDS 0002, Adjacent Artifact Manifest).
//!
//! The manifest follows RFC 8785 canonicalization rules: UTF-8, no
//! insignificant whitespace, object keys in bytewise order, and canonical
//! number spelling. The writer here emits canonically by construction and
//! asserts key order; the parser is a bounded, non-recursive loop over
//! `std.json.Scanner` so hostile manifests are refused within limits rather
//! than recursed into.

const std = @import("std");
const assert = std.debug.assert;
const limits_mod = @import("limits.zig");

// -------------------------------------------------------------- writing

/// A canonical JSON emitter into a growable buffer. Object keys must be
/// emitted in bytewise order; the writer asserts it.
pub const WriteStream = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    frames: [limits_mod.max_depth_hard_cap]Frame = undefined,
    depth: u32 = 0,
    /// Set when a value is expected immediately (array element slot filled,
    /// or after a key).
    value_expected: bool = true,

    const Frame = struct {
        kind: enum { object, array },
        count: u32,
        /// Byte range of the previous key within `bytes`, for order asserts.
        last_key_start: u32 = 0,
        last_key_len: u32 = 0,
    };

    pub fn init(gpa: std.mem.Allocator) WriteStream {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *WriteStream) void {
        w.bytes.deinit(w.gpa);
        w.* = undefined;
    }

    pub fn toOwnedSlice(w: *WriteStream) error{OutOfMemory}![]u8 {
        assert(w.depth == 0);
        assert(!w.value_expected);
        return w.bytes.toOwnedSlice(w.gpa);
    }

    pub fn beginObject(w: *WriteStream) error{OutOfMemory}!void {
        try w.beforeValue();
        assert(w.depth < limits_mod.max_depth_hard_cap);
        w.frames[w.depth] = .{ .kind = .object, .count = 0 };
        w.depth += 1;
        w.value_expected = false;
        try w.bytes.append(w.gpa, '{');
    }

    pub fn endObject(w: *WriteStream) error{OutOfMemory}!void {
        assert(w.depth > 0);
        assert(w.frames[w.depth - 1].kind == .object);
        assert(!w.value_expected);
        w.depth -= 1;
        try w.bytes.append(w.gpa, '}');
    }

    pub fn beginArray(w: *WriteStream) error{OutOfMemory}!void {
        try w.beforeValue();
        assert(w.depth < limits_mod.max_depth_hard_cap);
        w.frames[w.depth] = .{ .kind = .array, .count = 0 };
        w.depth += 1;
        w.value_expected = false;
        try w.bytes.append(w.gpa, '[');
    }

    pub fn endArray(w: *WriteStream) error{OutOfMemory}!void {
        assert(w.depth > 0);
        assert(w.frames[w.depth - 1].kind == .array);
        w.depth -= 1;
        try w.bytes.append(w.gpa, ']');
    }

    /// Emits an object key. Keys must arrive in strictly increasing bytewise
    /// order — the canonical order is a caller obligation the stream checks.
    pub fn field(w: *WriteStream, key: []const u8) error{OutOfMemory}!void {
        assert(w.depth > 0);
        const frame = &w.frames[w.depth - 1];
        assert(frame.kind == .object);
        assert(!w.value_expected);

        if (frame.count > 0) {
            const last = w.bytes.items[frame.last_key_start..][0..frame.last_key_len];
            assert(std.mem.order(u8, last, key) == .lt);
            try w.bytes.append(w.gpa, ',');
        }
        frame.count += 1;
        frame.last_key_start = @intCast(w.bytes.items.len + 1);
        frame.last_key_len = @intCast(key.len);
        try w.appendString(key);
        // The recorded range must hold the raw key for the order check;
        // escaping would shift it, so keys are restricted to plain ASCII.
        assert(std.mem.eql(u8, w.bytes.items[frame.last_key_start..][0..key.len], key));
        try w.bytes.append(w.gpa, ':');
        w.value_expected = true;
    }

    pub fn string(w: *WriteStream, value: []const u8) error{OutOfMemory}!void {
        try w.beforeValue();
        try w.appendString(value);
        w.value_expected = false;
    }

    pub fn integer(w: *WriteStream, value: i64) error{OutOfMemory}!void {
        try w.beforeValue();
        var buffer: [24]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
        try w.bytes.appendSlice(w.gpa, rendered);
        w.value_expected = false;
    }

    pub fn float(w: *WriteStream, value: f64) error{OutOfMemory}!void {
        assert(std.math.isFinite(value));
        try w.beforeValue();
        var buffer: [32]u8 = undefined;
        const rendered = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
        try w.bytes.appendSlice(w.gpa, rendered);
        w.value_expected = false;
    }

    pub fn boolean(w: *WriteStream, value: bool) error{OutOfMemory}!void {
        try w.beforeValue();
        try w.bytes.appendSlice(w.gpa, if (value) "true" else "false");
        w.value_expected = false;
    }

    pub fn nullValue(w: *WriteStream) error{OutOfMemory}!void {
        try w.beforeValue();
        try w.bytes.appendSlice(w.gpa, "null");
        w.value_expected = false;
    }

    /// Splices bytes that are already canonical JSON: a carried plugin
    /// namespace re-encoded by `writeValue`.
    pub fn raw(w: *WriteStream, canonical: []const u8) error{OutOfMemory}!void {
        assert(canonical.len > 0);
        try w.beforeValue();
        try w.bytes.appendSlice(w.gpa, canonical);
        w.value_expected = false;
    }

    fn beforeValue(w: *WriteStream) error{OutOfMemory}!void {
        if (w.depth == 0) {
            assert(w.value_expected);
            return;
        }
        const frame = &w.frames[w.depth - 1];
        switch (frame.kind) {
            .object => assert(w.value_expected),
            .array => {
                assert(!w.value_expected);
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
                    const rendered = std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{byte}) catch unreachable;
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

    const Partial = struct {
        members: std.ArrayList(Member),
        elements: std.ArrayList(Value),
        kind: enum { object, array },
        pending_key: ?[]const u8,
    };
    var stack: std.ArrayList(Partial) = .empty;
    defer stack.deinit(arena);
    var result: ?Value = null;

    while (true) {
        const token = scanner.nextAlloc(arena, .alloc_if_needed) catch return error.Malformed;
        var completed: ?Value = null;
        switch (token) {
            .end_of_document => break,
            .object_begin => {
                if (stack.items.len >= max_depth) return error.TooDeep;
                try stack.append(arena, .{
                    .members = .empty,
                    .elements = .empty,
                    .kind = .object,
                    .pending_key = null,
                });
                continue;
            },
            .array_begin => {
                if (stack.items.len >= max_depth) return error.TooDeep;
                try stack.append(arena, .{
                    .members = .empty,
                    .elements = .empty,
                    .kind = .array,
                    .pending_key = null,
                });
                continue;
            },
            .object_end => {
                var frame = stack.pop().?;
                assert(frame.kind == .object);
                assert(frame.pending_key == null);
                completed = .{ .object = try frame.members.toOwnedSlice(arena) };
                frame.elements.deinit(arena);
            },
            .array_end => {
                var frame = stack.pop().?;
                assert(frame.kind == .array);
                completed = .{ .array = try frame.elements.toOwnedSlice(arena) };
                frame.members.deinit(arena);
            },
            .string, .allocated_string => |slice| {
                const top = if (stack.items.len > 0) &stack.items[stack.items.len - 1] else null;
                if (top != null and top.?.kind == .object and top.?.pending_key == null) {
                    top.?.pending_key = slice;
                    continue;
                }
                completed = .{ .string = slice };
            },
            .number, .allocated_number => |slice| {
                completed = parseNumber(slice) orelse return error.Malformed;
            },
            .true => completed = .{ .boolean = true },
            .false => completed = .{ .boolean = false },
            .null => completed = .null,
            .partial_number, .partial_string => unreachable,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => unreachable,
        }

        const value = completed.?;
        if (stack.items.len == 0) {
            assert(result == null);
            result = value;
            continue;
        }
        const top = &stack.items[stack.items.len - 1];
        switch (top.kind) {
            .object => {
                const key = top.pending_key.?;
                top.pending_key = null;
                try top.members.append(arena, .{ .key = key, .value = value });
            },
            .array => try top.elements.append(arena, value),
        }
    }

    return result orelse error.Malformed;
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
pub fn writeValue(w: *WriteStream, root: Value) error{OutOfMemory}!void {
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
) error{OutOfMemory}!void {
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
