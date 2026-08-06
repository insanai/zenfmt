//! PDF object syntax (ZDS: pdf-reader).
//!
//! A byte lexer and a non-recursive object parser for the COS object
//! language: booleans, numbers, literal and hex strings, names with `#xx`
//! escapes, arrays, dictionaries, and `n g R` indirect references. Streams
//! and indirect-object framing (`obj`/`endobj`) are handled by the caller
//! (`xref.zig`), which owns file offsets; this file never touches them.

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{ OutOfMemory, Malformed, LimitExceeded };

pub const Ref = struct { num: u32, gen: u16 };

pub const DictEntry = struct { key: []const u8, value: Object };

pub const Dict = struct {
    entries: []const DictEntry = &.{},

    pub fn get(d: Dict, key: []const u8) ?Object {
        for (d.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

pub const Stream = struct {
    dict: Dict,
    /// Raw (still encoded) bytes, sliced from the file.
    raw: []const u8,
};

pub const Object = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    /// Decoded literal or hex string bytes.
    string: []const u8,
    /// Decoded name without the leading slash.
    name: []const u8,
    array: []const Object,
    dict: Dict,
    stream: Stream,
    ref: Ref,

    pub fn asInt(o: Object) ?i64 {
        return switch (o) {
            .integer => |v| v,
            .real => |v| if (v >= -9.007199254740992e15 and v <= 9.007199254740992e15)
                @intFromFloat(v)
            else
                null,
            else => null,
        };
    }

    pub fn asNumber(o: Object) ?f64 {
        return switch (o) {
            .integer => |v| @floatFromInt(v),
            .real => |v| v,
            else => null,
        };
    }

    pub fn asDict(o: Object) ?Dict {
        return switch (o) {
            .dict => |d| d,
            .stream => |s| s.dict,
            else => null,
        };
    }

    pub fn isName(o: Object, name: []const u8) bool {
        return switch (o) {
            .name => |n| std.mem.eql(u8, n, name),
            else => false,
        };
    }
};

pub fn isWhite(byte: u8) bool {
    return switch (byte) {
        0, '\t', '\n', 0x0c, '\r', ' ' => true,
        else => false,
    };
}

pub fn isDelimiter(byte: u8) bool {
    return switch (byte) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

pub const Token = union(enum) {
    integer: i64,
    real: f64,
    string: []const u8,
    name: []const u8,
    array_open,
    array_close,
    dict_open,
    dict_close,
    /// A bare keyword: `obj`, `endobj`, `stream`, `R`, `true`, content
    /// operators, and anything else regular. Slice into the input.
    keyword: []const u8,
    eof,
};

pub const Lexer = struct {
    bytes: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator, bytes: []const u8) Lexer {
        return .{ .arena = arena, .bytes = bytes };
    }

    pub fn skipWhite(x: *Lexer) void {
        const bytes = x.bytes;
        while (x.pos < bytes.len) {
            const byte = bytes[x.pos];
            if (isWhite(byte)) {
                x.pos += 1;
            } else if (byte == '%') {
                while (x.pos < bytes.len and bytes[x.pos] != '\n' and bytes[x.pos] != '\r') {
                    x.pos += 1;
                }
            } else {
                return;
            }
        }
    }

    pub fn next(x: *Lexer) Error!Token {
        x.skipWhite();
        const bytes = x.bytes;
        if (x.pos >= bytes.len) return .eof;
        const byte = bytes[x.pos];
        switch (byte) {
            '[' => {
                x.pos += 1;
                return .array_open;
            },
            ']' => {
                x.pos += 1;
                return .array_close;
            },
            '(' => return .{ .string = try x.literalString() },
            '/' => return .{ .name = try x.nameToken() },
            '<' => {
                if (x.pos + 1 < bytes.len and bytes[x.pos + 1] == '<') {
                    x.pos += 2;
                    return .dict_open;
                }
                return .{ .string = try x.hexString() };
            },
            '>' => {
                if (x.pos + 1 < bytes.len and bytes[x.pos + 1] == '>') {
                    x.pos += 2;
                    return .dict_close;
                }
                return error.Malformed;
            },
            ')', '{', '}' => {
                // `{`/`}` appear only in PostScript functions; a lone `)`
                // is an error. Consume so the caller always advances.
                x.pos += 1;
                return .{ .keyword = bytes[x.pos - 1 .. x.pos] };
            },
            else => {},
        }
        if (byte == '+' or byte == '-' or byte == '.' or std.ascii.isDigit(byte)) {
            return x.number();
        }
        // A keyword: regular characters until whitespace or delimiter.
        const start = x.pos;
        while (x.pos < bytes.len and !isWhite(bytes[x.pos]) and !isDelimiter(bytes[x.pos])) {
            x.pos += 1;
        }
        assert(x.pos > start);
        return .{ .keyword = bytes[start..x.pos] };
    }

    fn number(x: *Lexer) Error!Token {
        const bytes = x.bytes;
        const start = x.pos;
        var is_real = false;
        while (x.pos < bytes.len) : (x.pos += 1) {
            const c = bytes[x.pos];
            if (std.ascii.isDigit(c) or ((c == '+' or c == '-') and x.pos == start)) continue;
            if (c == '.') {
                is_real = true;
                continue;
            }
            break;
        }
        const text = bytes[start..x.pos];
        if (text.len == 0) return error.Malformed;
        if (!is_real) {
            if (std.fmt.parseInt(i64, text, 10)) |value| {
                return .{ .integer = value };
            } else |_| {
                is_real = true;
            }
        }
        const value = std.fmt.parseFloat(f64, text) catch {
            // `.`, `-.`, `4.`: pad into a parseable spelling.
            var buffer: [64]u8 = undefined;
            if (text.len + 2 > buffer.len) return error.Malformed;
            var n: usize = 0;
            for (text) |c| {
                if (c == '.' and n == 0) {
                    buffer[n] = '0';
                    n += 1;
                }
                buffer[n] = c;
                n += 1;
            }
            buffer[n] = '0';
            n += 1;
            return .{ .real = std.fmt.parseFloat(f64, buffer[0..n]) catch return error.Malformed };
        };
        return .{ .real = value };
    }

    /// `(...)` with balanced parentheses, backslash escapes, and `\ooo`.
    fn literalString(x: *Lexer) Error![]const u8 {
        const bytes = x.bytes;
        assert(bytes[x.pos] == '(');
        x.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        var depth: u32 = 1;
        while (x.pos < bytes.len) {
            const c = bytes[x.pos];
            x.pos += 1;
            switch (c) {
                '(' => {
                    depth += 1;
                    try out.append(x.arena, c);
                },
                ')' => {
                    depth -= 1;
                    if (depth == 0) return out.items;
                    try out.append(x.arena, c);
                },
                '\\' => {
                    if (x.pos >= bytes.len) return error.Malformed;
                    const e = bytes[x.pos];
                    x.pos += 1;
                    switch (e) {
                        'n' => try out.append(x.arena, '\n'),
                        'r' => try out.append(x.arena, '\r'),
                        't' => try out.append(x.arena, '\t'),
                        'b' => try out.append(x.arena, 0x08),
                        'f' => try out.append(x.arena, 0x0c),
                        '(', ')', '\\' => try out.append(x.arena, e),
                        '\r' => {
                            // Line continuation; swallow a following LF.
                            if (x.pos < bytes.len and bytes[x.pos] == '\n') x.pos += 1;
                        },
                        '\n' => {},
                        '0'...'7' => {
                            var value: u32 = e - '0';
                            var digits: u32 = 1;
                            while (digits < 3 and x.pos < bytes.len and
                                bytes[x.pos] >= '0' and bytes[x.pos] <= '7')
                            {
                                value = value * 8 + (bytes[x.pos] - '0');
                                x.pos += 1;
                                digits += 1;
                            }
                            try out.append(x.arena, @truncate(value));
                        },
                        else => try out.append(x.arena, e),
                    }
                },
                else => try out.append(x.arena, c),
            }
        }
        return error.Malformed;
    }

    /// `<48656C6C6F>`; an odd final digit is padded with zero per spec.
    fn hexString(x: *Lexer) Error![]const u8 {
        const bytes = x.bytes;
        assert(bytes[x.pos] == '<');
        x.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        var pending: ?u8 = null;
        while (x.pos < bytes.len) {
            const c = bytes[x.pos];
            x.pos += 1;
            if (c == '>') {
                if (pending) |high| try out.append(x.arena, high << 4);
                return out.items;
            }
            const digit = std.fmt.charToDigit(c, 16) catch {
                if (isWhite(c)) continue;
                return error.Malformed;
            };
            if (pending) |high| {
                try out.append(x.arena, (high << 4) | digit);
                pending = null;
            } else {
                pending = digit;
            }
        }
        return error.Malformed;
    }

    /// `/Name` with `#xx` escapes decoded.
    fn nameToken(x: *Lexer) Error![]const u8 {
        const bytes = x.bytes;
        assert(bytes[x.pos] == '/');
        x.pos += 1;
        const start = x.pos;
        var has_escape = false;
        while (x.pos < bytes.len and !isWhite(bytes[x.pos]) and !isDelimiter(bytes[x.pos])) {
            if (bytes[x.pos] == '#') has_escape = true;
            x.pos += 1;
        }
        const raw = bytes[start..x.pos];
        if (!has_escape) return raw;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '#' and i + 2 < raw.len) {
                const high = std.fmt.charToDigit(raw[i + 1], 16) catch null;
                const low = std.fmt.charToDigit(raw[i + 2], 16) catch null;
                if (high != null and low != null) {
                    try out.append(x.arena, (high.? << 4) | low.?);
                    i += 3;
                    continue;
                }
            }
            try out.append(x.arena, raw[i]);
            i += 1;
        }
        return out.items;
    }
};

/// One partially-built container on the explicit parse stack.
const Frame = struct {
    is_dict: bool,
    items: std.ArrayList(Object),
};

pub const Parser = struct {
    lexer: *Lexer,
    arena: std.mem.Allocator,
    max_depth: u32,

    /// Parses one complete object. `n g R` references are recognized both
    /// inside containers and at top level. Keywords other than `R`, `true`,
    /// `false`, and `null` terminate the parse with `error.Malformed` when
    /// an object is expected.
    pub fn parseObject(p: *Parser) Error!Object {
        var stack: std.ArrayList(Frame) = .empty;
        defer {
            for (stack.items) |*frame| frame.items.deinit(p.arena);
            stack.deinit(p.arena);
        }
        // Bounded: every loop iteration consumes at least one token, and
        // the lexer always advances.
        while (true) {
            const token = try self_next(p);
            const completed: ?Object = switch (token) {
                .eof => return error.Malformed,
                .array_open => {
                    if (stack.items.len >= p.max_depth) return error.LimitExceeded;
                    try stack.append(p.arena, .{ .is_dict = false, .items = .empty });
                    continue;
                },
                .dict_open => {
                    if (stack.items.len >= p.max_depth) return error.LimitExceeded;
                    try stack.append(p.arena, .{ .is_dict = true, .items = .empty });
                    continue;
                },
                .array_close => blk: {
                    if (stack.items.len == 0) return error.Malformed;
                    var frame = stack.pop().?;
                    if (frame.is_dict) return error.Malformed;
                    break :blk .{ .array = try frame.items.toOwnedSlice(p.arena) };
                },
                .dict_close => blk: {
                    if (stack.items.len == 0) return error.Malformed;
                    var frame = stack.pop().?;
                    defer frame.items.deinit(p.arena);
                    if (!frame.is_dict) return error.Malformed;
                    break :blk .{ .dict = try buildDict(p.arena, frame.items.items) };
                },
                .integer => |value| .{ .integer = value },
                .real => |value| .{ .real = value },
                .string => |value| .{ .string = value },
                .name => |value| .{ .name = value },
                .keyword => |word| blk: {
                    if (std.mem.eql(u8, word, "true")) break :blk .{ .boolean = true };
                    if (std.mem.eql(u8, word, "false")) break :blk .{ .boolean = false };
                    if (std.mem.eql(u8, word, "null")) break :blk .null;
                    if (std.mem.eql(u8, word, "R")) {
                        try reduceReference(p.arena, &stack);
                        continue;
                    }
                    return error.Malformed;
                },
            };
            const value = completed.?;
            if (stack.items.len == 0) return try p.maybeReference(value);
            try stack.items[stack.items.len - 1].items.append(p.arena, value);
        }
    }

    fn self_next(p: *Parser) Error!Token {
        return p.lexer.next();
    }

    /// At top level, `12 0 R` arrives as three tokens; peek non-destructively.
    fn maybeReference(p: *Parser, value: Object) Error!Object {
        if (value != .integer) return value;
        const num = std.math.cast(u32, value.integer) orelse return value;
        const saved = p.lexer.pos;
        const second = p.lexer.next() catch {
            p.lexer.pos = saved;
            return value;
        };
        if (second == .integer) {
            if (std.math.cast(u16, second.integer)) |gen| {
                const third = p.lexer.next() catch {
                    p.lexer.pos = saved;
                    return value;
                };
                if (third == .keyword and std.mem.eql(u8, third.keyword, "R")) {
                    return .{ .ref = .{ .num = num, .gen = gen } };
                }
            }
        }
        p.lexer.pos = saved;
        return value;
    }

    /// Inside a container, `R` folds the two preceding integers in place.
    fn reduceReference(arena: std.mem.Allocator, stack: *std.ArrayList(Frame)) Error!void {
        if (stack.items.len == 0) return error.Malformed;
        const items = &stack.items[stack.items.len - 1].items;
        if (items.items.len < 2) return error.Malformed;
        const gen_obj = items.items[items.items.len - 1];
        const num_obj = items.items[items.items.len - 2];
        if (gen_obj != .integer or num_obj != .integer) return error.Malformed;
        const num = std.math.cast(u32, num_obj.integer) orelse return error.Malformed;
        const gen = std.math.cast(u16, gen_obj.integer) orelse return error.Malformed;
        items.items.len -= 2;
        try items.append(arena, .{ .ref = .{ .num = num, .gen = gen } });
    }
};

fn buildDict(arena: std.mem.Allocator, items: []const Object) Error!Dict {
    // Tolerant pairing: a key without a value, or a non-name key, drops
    // that pair rather than the document.
    var entries: std.ArrayList(DictEntry) = .empty;
    var i: usize = 0;
    while (i + 1 < items.len) {
        const key = items[i];
        const value = items[i + 1];
        i += 2;
        if (key != .name) continue;
        try entries.append(arena, .{ .key = key.name, .value = value });
    }
    return .{ .entries = try entries.toOwnedSlice(arena) };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn parseOne(arena: std.mem.Allocator, bytes: []const u8) Error!Object {
    var lexer = Lexer.init(arena, bytes);
    var parser: Parser = .{ .lexer = &lexer, .arena = arena, .max_depth = 64 };
    return parser.parseObject();
}

test "scalars, strings, and names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(@as(i64, -17), (try parseOne(arena, " -17 ")).integer);
    try testing.expectApproxEqAbs(@as(f64, 0.5), (try parseOne(arena, "+.5")).real, 1e-9);
    const s = try parseOne(arena, "(a\\(b\\)c\\101 \\n)");
    try testing.expectEqualStrings("a(b)cA \n", s.string);
    const hex = try parseOne(arena, "<48656C6C6F2>");
    try testing.expectEqualStrings("Hello ", hex.string);
    const name = try parseOne(arena, "/Adobe#20Green");
    try testing.expectEqualStrings("Adobe Green", name.name);
}

test "containers and references" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const obj = try parseOne(arena, "<< /Kids [1 0 R 2 0 R] /Count 2 >>");
    const kids = obj.dict.get("Kids").?.array;
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqual(@as(u32, 1), kids[0].ref.num);
    try testing.expectEqual(@as(i64, 2), obj.dict.get("Count").?.integer);

    const top_ref = try parseOne(arena, "12 0 R");
    try testing.expectEqual(@as(u32, 12), top_ref.ref.num);
}

test "depth limit bounds nesting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const deep = "[" ** 100 ++ "]" ** 100;
    var lexer = Lexer.init(arena, deep);
    var parser: Parser = .{ .lexer = &lexer, .arena = arena, .max_depth = 32 };
    try testing.expectError(error.LimitExceeded, parser.parseObject());
}
