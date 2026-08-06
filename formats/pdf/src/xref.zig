//! PDF file structure (ZDS: pdf-reader).
//!
//! Header discovery, the `startxref` pointer, classic cross-reference
//! tables, cross-reference streams (`/Type /XRef` with `/W` field widths),
//! the `/Prev` trailer chain for incremental updates, hybrid `/XRefStm`
//! bridges, and compressed objects inside object streams (`/Type /ObjStm`).
//! Loaded objects are cached by number; reference resolution is bounded,
//! and an object that participates in its own loading (a `/Length` loop,
//! an object stream containing itself) is malformed, not a hang.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const objects = @import("objects.zig");
const streams = @import("streams.zig");

pub const Error = error{ OutOfMemory, Malformed, LimitExceeded };
pub const OpenError = Error || error{ Encrypted, NotPdf };

/// Cross-reference sections one file may chain; each incremental update
/// adds one, and real files rarely exceed a handful.
const max_xref_sections = 64;
/// Reference indirection bound: `a -> b -> c` chains longer than this are
/// loops in practice.
const max_indirection = 32;
/// Objects admitted from all cross-reference sections combined.
const max_objects = 1 << 21;

const Where = union(enum) {
    offset: u64,
    in_stream: struct { container: u32, index: u32 },
};

pub const File = struct {
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: core.Limits,
    entries: std.AutoHashMapUnmanaged(u32, Where) = .empty,
    cache: std.AutoHashMapUnmanaged(u32, objects.Object) = .empty,
    /// Decoded object-stream payloads, keyed by container number.
    objstm_cache: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// Objects currently being loaded; re-entry is a reference loop.
    loading: std.AutoHashMapUnmanaged(u32, void) = .empty,
    trailer: objects.Dict = .{},
    /// Filter names met and refused while decoding streams; the reader
    /// reports them once each.
    unsupported_filter: ?[]const u8 = null,

    pub fn open(arena: std.mem.Allocator, bytes: []const u8, limits: core.Limits) OpenError!File {
        var file: File = .{ .arena = arena, .bytes = bytes, .limits = limits };
        if (findHeader(bytes) == null) return error.NotPdf;
        const start = findStartXref(bytes) orelse return error.Malformed;
        try file.loadSections(start);
        if (file.trailer.get("Encrypt") != null) return error.Encrypted;
        return file;
    }

    /// Walks the `/Prev` chain, newest section first. First sighting of an
    /// object number wins, which is exactly the incremental-update rule.
    fn loadSections(file: *File, first_offset: u64) Error!void {
        var offset = first_offset;
        var sections: u32 = 0;
        while (sections < max_xref_sections) : (sections += 1) {
            const next = try file.loadSection(offset) orelse return;
            offset = next;
        }
        return error.LimitExceeded;
    }

    /// Returns the `/Prev` offset when the section chains onward.
    fn loadSection(file: *File, offset: u64) Error!?u64 {
        const pos = std.math.cast(usize, offset) orelse return error.Malformed;
        if (pos >= file.bytes.len) return error.Malformed;
        var lexer = objects.Lexer.init(file.arena, file.bytes);
        lexer.pos = pos;
        const token = try lexer.next();
        if (token == .keyword and std.mem.eql(u8, token.keyword, "xref")) {
            return try file.loadClassicSection(&lexer);
        }
        // Otherwise this must be a cross-reference stream object.
        lexer.pos = pos;
        const loaded = try file.parseIndirectAt(&lexer);
        if (loaded.object != .stream) return error.Malformed;
        return try file.loadStreamSection(loaded.object.stream);
    }

    fn loadClassicSection(file: *File, lexer: *objects.Lexer) Error!?u64 {
        // Subsections: `start count` pairs, then 20-byte entries.
        var subsections: u32 = 0;
        while (subsections < max_xref_sections * 64) : (subsections += 1) {
            lexer.skipWhite();
            const save = lexer.pos;
            const token = try lexer.next();
            if (token == .keyword and std.mem.eql(u8, token.keyword, "trailer")) break;
            if (token != .integer) return error.Malformed;
            const start_num = std.math.cast(u32, token.integer) orelse return error.Malformed;
            const count_token = try lexer.next();
            if (count_token != .integer) return error.Malformed;
            const count = std.math.cast(u32, count_token.integer) orelse return error.Malformed;
            _ = save;
            lexer.skipWhite();
            try file.readClassicEntries(lexer, start_num, count);
        }
        var parser: objects.Parser = .{
            .lexer = lexer,
            .arena = file.arena,
            .max_depth = file.limits.max_depth,
        };
        const trailer_obj = try parser.parseObject();
        const trailer = trailer_obj.asDict() orelse return error.Malformed;
        try file.adoptTrailer(trailer);
        // Hybrid files bridge to a cross-reference stream for the same
        // section; its entries fill numbers the table calls free.
        if (trailer.get("XRefStm")) |bridge| {
            if (bridge.asInt()) |bridge_offset| {
                if (bridge_offset > 0) _ = file.loadSection(@intCast(bridge_offset)) catch {};
            }
        }
        return prevOffset(trailer);
    }

    fn readClassicEntries(
        file: *File,
        lexer: *objects.Lexer,
        start_num: u32,
        count: u32,
    ) Error!void {
        if (count > max_objects) return error.LimitExceeded;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            lexer.skipWhite();
            if (lexer.pos + 18 > lexer.bytes.len) return error.Malformed;
            const entry = lexer.bytes[lexer.pos..][0..18];
            lexer.pos += 18;
            const offset = std.fmt.parseInt(u64, std.mem.trim(u8, entry[0..10], " "), 10) catch
                return error.Malformed;
            const kind = entry[17];
            if (kind == 'n') {
                try file.admit(start_num + i, .{ .offset = offset });
            } else if (kind != 'f') {
                return error.Malformed;
            }
        }
    }

    fn loadStreamSection(file: *File, stream: objects.Stream) Error!?u64 {
        const dict = stream.dict;
        const data = try file.decodeStream(stream);
        const w = dict.get("W") orelse return error.Malformed;
        if (w != .array or w.array.len < 3) return error.Malformed;
        var widths: [3]u32 = undefined;
        var row_len: u32 = 0;
        for (0..3) |i| {
            const width = w.array[i].asInt() orelse return error.Malformed;
            widths[i] = std.math.cast(u32, width) orelse return error.Malformed;
            if (widths[i] > 8) return error.Malformed;
            row_len += widths[i];
        }
        if (row_len == 0) return error.Malformed;

        const size = (dict.get("Size") orelse return error.Malformed).asInt() orelse
            return error.Malformed;
        var index_pairs: [max_xref_sections][2]u64 = undefined;
        var pair_count: usize = 0;
        if (dict.get("Index")) |index_obj| {
            if (index_obj != .array or index_obj.array.len % 2 != 0) return error.Malformed;
            if (index_obj.array.len / 2 > max_xref_sections) return error.LimitExceeded;
            var i: usize = 0;
            while (i < index_obj.array.len) : (i += 2) {
                const first = index_obj.array[i].asInt() orelse return error.Malformed;
                const count = index_obj.array[i + 1].asInt() orelse return error.Malformed;
                if (first < 0 or count < 0) return error.Malformed;
                index_pairs[pair_count] = .{ @intCast(first), @intCast(count) };
                pair_count += 1;
            }
        } else {
            if (size < 0) return error.Malformed;
            index_pairs[0] = .{ 0, @intCast(size) };
            pair_count = 1;
        }

        var row: usize = 0;
        for (index_pairs[0..pair_count]) |pair| {
            const first: u64 = pair[0];
            const count: u64 = pair[1];
            if (count > max_objects) return error.LimitExceeded;
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                const at = row * row_len;
                row += 1;
                if (at + row_len > data.len) return error.Malformed;
                const kind = readField(data[at..], 0, widths, 1);
                const second = readField(data[at..], widths[0], widths, widths[1]);
                const third = readField(data[at..], widths[0] + widths[1], widths, widths[2]);
                const num = std.math.cast(u32, first + i) orelse return error.Malformed;
                switch (kind) {
                    1 => try file.admit(num, .{ .offset = second }),
                    2 => try file.admit(num, .{ .in_stream = .{
                        .container = std.math.cast(u32, second) orelse return error.Malformed,
                        .index = std.math.cast(u32, third) orelse return error.Malformed,
                    } }),
                    else => {},
                }
            }
        }
        try file.adoptTrailer(dict);
        return prevOffset(dict);
    }

    fn admit(file: *File, num: u32, where: Where) Error!void {
        if (file.entries.count() >= max_objects) return error.LimitExceeded;
        const slot = try file.entries.getOrPut(file.arena, num);
        if (!slot.found_existing) slot.value_ptr.* = where;
    }

    /// The newest trailer wins per key; older sections only fill gaps
    /// (`/Root` may live in the original trailer of an updated file).
    fn adoptTrailer(file: *File, trailer: objects.Dict) Error!void {
        if (file.trailer.entries.len == 0) {
            file.trailer = trailer;
            return;
        }
        for (trailer.entries) |entry| {
            if (file.trailer.get(entry.key) == null) {
                var merged: std.ArrayList(objects.DictEntry) = .empty;
                try merged.appendSlice(file.arena, file.trailer.entries);
                try merged.append(file.arena, entry);
                file.trailer = .{ .entries = try merged.toOwnedSlice(file.arena) };
            }
        }
    }

    // -------------------------------------------------------- object load

    pub fn get(file: *File, num: u32) Error!objects.Object {
        if (file.cache.get(num)) |cached| return cached;
        const where = file.entries.get(num) orelse return .null;
        if (file.loading.contains(num)) return error.Malformed;
        try file.loading.put(file.arena, num, {});
        defer _ = file.loading.remove(num);

        const object = switch (where) {
            .offset => |offset| blk: {
                const pos = std.math.cast(usize, offset) orelse return error.Malformed;
                if (pos >= file.bytes.len) return error.Malformed;
                var lexer = objects.Lexer.init(file.arena, file.bytes);
                lexer.pos = pos;
                const loaded = try file.parseIndirectAt(&lexer);
                if (loaded.num != num) return error.Malformed;
                break :blk loaded.object;
            },
            .in_stream => |place| try file.loadFromObjectStream(place.container, place.index),
        };
        try file.cache.put(file.arena, num, object);
        return object;
    }

    /// Follows reference chains to a direct object, bounded.
    pub fn resolve(file: *File, start: objects.Object) Error!objects.Object {
        var object = start;
        var hops: u32 = 0;
        while (object == .ref) : (hops += 1) {
            if (hops >= max_indirection) return error.Malformed;
            object = try file.get(object.ref.num);
        }
        return object;
    }

    /// `dict.get` plus resolution, the everyday accessor.
    pub fn dictGet(file: *File, dict: objects.Dict, key: []const u8) Error!?objects.Object {
        const value = dict.get(key) orelse return null;
        const resolved = try file.resolve(value);
        return if (resolved == .null) null else resolved;
    }

    /// Decodes a stream's bytes through its filter chain. An unsupported
    /// filter records the name and yields empty data.
    pub fn decodeStream(file: *File, stream: objects.Stream) Error![]const u8 {
        const result = streams.decode(file.arena, stream.dict, stream.raw, file.limits) catch |err|
            switch (err) {
                error.UnsupportedFilter => unreachable,
                else => |narrow| return narrow,
            };
        if (result.unsupported) |name| {
            file.unsupported_filter = name;
            return &.{};
        }
        return result.data;
    }

    const Indirect = struct { num: u32, object: objects.Object };

    /// Parses `N G obj <object> [stream ... endstream] endobj` at the
    /// lexer's position.
    fn parseIndirectAt(file: *File, lexer: *objects.Lexer) Error!Indirect {
        const num_token = try lexer.next();
        const gen_token = try lexer.next();
        const obj_token = try lexer.next();
        if (num_token != .integer or gen_token != .integer) return error.Malformed;
        if (obj_token != .keyword or !std.mem.eql(u8, obj_token.keyword, "obj")) {
            return error.Malformed;
        }
        const num = std.math.cast(u32, num_token.integer) orelse return error.Malformed;
        var parser: objects.Parser = .{
            .lexer = lexer,
            .arena = file.arena,
            .max_depth = file.limits.max_depth,
        };
        var object = try parser.parseObject();

        const save = lexer.pos;
        const after = lexer.next() catch return .{ .num = num, .object = object };
        if (after == .keyword and std.mem.eql(u8, after.keyword, "stream")) {
            const dict = object.asDict() orelse return error.Malformed;
            object = .{ .stream = try file.sliceStream(lexer, dict) };
        } else {
            lexer.pos = save;
        }
        return .{ .num = num, .object = object };
    }

    /// After the `stream` keyword: skip its EOL, slice `/Length` bytes,
    /// and fall back to scanning for `endstream` when the length is
    /// missing or lies.
    fn sliceStream(file: *File, lexer: *objects.Lexer, dict: objects.Dict) Error!objects.Stream {
        const bytes = file.bytes;
        var start = lexer.pos;
        if (start < bytes.len and bytes[start] == '\r') start += 1;
        if (start < bytes.len and bytes[start] == '\n') start += 1;

        var length: ?usize = null;
        if (dict.get("Length")) |length_obj| {
            const resolved = file.resolve(length_obj) catch null;
            if (resolved) |value| {
                if (value.asInt()) |n| {
                    if (n >= 0) length = std.math.cast(usize, n);
                }
            }
        }
        if (length) |n| {
            if (start + n <= bytes.len) {
                const tail = bytes[start + n ..];
                var t: usize = 0;
                while (t < 4 and t < tail.len and objects.isWhite(tail[t])) t += 1;
                if (std.mem.startsWith(u8, tail[t..], "endstream")) {
                    lexer.pos = start + n + t + "endstream".len;
                    return .{ .dict = dict, .raw = bytes[start..][0..n] };
                }
            }
        }
        // The declared length was wrong: trust the marker instead.
        const end = std.mem.indexOfPos(u8, bytes, start, "endstream") orelse
            return error.Malformed;
        lexer.pos = end + "endstream".len;
        var stop = end;
        if (stop > start and bytes[stop - 1] == '\n') stop -= 1;
        if (stop > start and bytes[stop - 1] == '\r') stop -= 1;
        return .{ .dict = dict, .raw = bytes[start..stop] };
    }

    fn loadFromObjectStream(file: *File, container: u32, index: u32) Error!objects.Object {
        const data = blk: {
            if (file.objstm_cache.get(container)) |cached| break :blk cached;
            const container_obj = try file.get(container);
            if (container_obj != .stream) return error.Malformed;
            const decoded = try file.decodeStream(container_obj.stream);
            try file.objstm_cache.put(file.arena, container, decoded);
            break :blk decoded;
        };
        const container_obj = try file.get(container);
        if (container_obj != .stream) return error.Malformed;
        const dict = container_obj.stream.dict;
        const n = (dict.get("N") orelse return error.Malformed).asInt() orelse
            return error.Malformed;
        const first = (dict.get("First") orelse return error.Malformed).asInt() orelse
            return error.Malformed;
        if (n < 0 or first < 0 or index >= n) return error.Malformed;

        // Header: N pairs of `num offset`.
        var lexer = objects.Lexer.init(file.arena, data);
        var object_offset: ?u64 = null;
        var i: i64 = 0;
        while (i < n) : (i += 1) {
            const num_token = try lexer.next();
            const off_token = try lexer.next();
            if (num_token != .integer or off_token != .integer) return error.Malformed;
            if (i == index) {
                if (off_token.integer < 0) return error.Malformed;
                object_offset = @intCast(off_token.integer);
            }
        }
        const relative = object_offset orelse return error.Malformed;
        const at = std.math.cast(usize, @as(u64, @intCast(first)) + relative) orelse
            return error.Malformed;
        if (at >= data.len) return error.Malformed;
        var object_lexer = objects.Lexer.init(file.arena, data);
        object_lexer.pos = at;
        var parser: objects.Parser = .{
            .lexer = &object_lexer,
            .arena = file.arena,
            .max_depth = file.limits.max_depth,
        };
        return parser.parseObject();
    }
};

fn prevOffset(trailer: objects.Dict) ?u64 {
    const prev = trailer.get("Prev") orelse return null;
    const value = prev.asInt() orelse return null;
    if (value <= 0) return null;
    return @intCast(value);
}

fn readField(row: []const u8, at: u32, widths: [3]u32, width: u32) u64 {
    _ = widths;
    // A zero-width first field defaults to type 1 per spec.
    if (width == 0) return 1;
    var value: u64 = 0;
    for (row[at..][0..width]) |byte| value = (value << 8) | byte;
    return value;
}

/// `%PDF-` may sit up to 1 KiB into the file (spec allows junk before it).
fn findHeader(bytes: []const u8) ?usize {
    const window = bytes[0..@min(bytes.len, 1024)];
    return std.mem.indexOf(u8, window, "%PDF-");
}

fn findStartXref(bytes: []const u8) ?u64 {
    const window_start = bytes.len - @min(bytes.len, 2048);
    const window = bytes[window_start..];
    const at = std.mem.lastIndexOf(u8, window, "startxref") orelse return null;
    var i = window_start + at + "startxref".len;
    while (i < bytes.len and objects.isWhite(bytes[i])) i += 1;
    const start = i;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u64, bytes[start..i], 10) catch null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const testpdf = @import("testpdf.zig");

test "a classic-xref file opens and objects load" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = testpdf.Builder.init(arena);
    _ = try doc.add("<< /Type /Catalog /Pages 2 0 R >>");
    _ = try doc.add("<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
    _ = try doc.add("<< /Type /Page /Parent 2 0 R >>");
    const bytes = try doc.finish(1);

    var file = try File.open(arena, bytes, .{});
    const root = (try file.dictGet(file.trailer, "Root")).?;
    try testing.expect(root.asDict().?.get("Pages") != null);
    const page = try file.get(3);
    try testing.expect(page.asDict().?.get("Parent").? == .ref);
}

test "reference loops are malformed, not hangs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = testpdf.Builder.init(arena);
    _ = try doc.add("<< /Type /Catalog /Pages 2 0 R >>");
    _ = try doc.add("2 0 R"); // Object 2 is a reference to itself.
    const bytes = try doc.finish(1);

    var file = try File.open(arena, bytes, .{});
    try testing.expectError(error.Malformed, file.resolve(.{ .ref = .{ .num = 2, .gen = 0 } }));
}

test "encrypted documents are refused at open" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var doc = testpdf.Builder.init(arena);
    _ = try doc.add("<< /Type /Catalog >>");
    _ = try doc.add("<< /Filter /Standard /V 1 >>");
    doc.extra_trailer = "/Encrypt 2 0 R";
    const bytes = try doc.finish(1);
    try testing.expectError(error.Encrypted, File.open(arena, bytes, .{}));
}
