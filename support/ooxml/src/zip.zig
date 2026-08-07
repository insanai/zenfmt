//! Central-directory ZIP reading (ZDS 0002, The container).
//!
//! The reader works from the central directory at the end of the archive.
//! It never walks local file headers to discover entries — the parsing
//! mode ZIP-confusion attacks exploit — and it never expands an entry it
//! was not asked for. Three rules have no override: hostile entry names
//! reject the archive, encrypted entries are refused, and only `stored`
//! and `deflate` are accepted.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");

pub const Error = error{
    OutOfMemory,
    /// Not a ZIP archive, or one too broken to trust.
    Malformed,
    /// An entry name that is absolute, contains `..` or a backslash or a
    /// NUL: evidence of a file built to confuse a consumer.
    HostileEntryName,
    /// Encrypted entries are never read.
    EncryptedEntry,
    /// A compression method other than stored or deflate.
    UnsupportedMethod,
    /// A named resource limit was hit; the caller reports which.
    LimitExceeded,
};

pub const Entry = struct {
    name: []const u8,
    compressed_size: u64,
    uncompressed_size: u64,
    method: Method,
    /// Offset of the entry's local header.
    header_offset: u64,
};

pub const Method = enum(u16) {
    stored = 0,
    deflate = 8,
    _,
};

/// Where archive bytes come from: a whole-input slice, or a file handle
/// windowed by bounded positional reads (ZDS 0013, Core Contract Repairs).
/// The file path never holds the archive in memory: the EOCD tail, the
/// central directory, and one entry's compressed payload at a time.
pub const Source = union(enum) {
    bytes: []const u8,
    file: File,

    pub const File = struct {
        io: std.Io,
        handle: std.Io.File,
        size: u64,
    };

    fn len(source: Source) u64 {
        return switch (source) {
            .bytes => |bytes| bytes.len,
            .file => |file| file.size,
        };
    }

    /// Reads exactly `buffer.len` bytes at `offset` into `buffer` for file
    /// sources; returns the equivalent subslice for byte sources. The
    /// caller has already bounds-checked the window against `len`.
    fn window(source: Source, offset: u64, buffer: []u8) Error![]const u8 {
        assert(offset + buffer.len <= source.len());
        switch (source) {
            .bytes => |bytes| {
                const start = std.math.cast(usize, offset) orelse return error.Malformed;
                return bytes[start..][0..buffer.len];
            },
            .file => |file| {
                const read = file.handle.readPositionalAll(file.io, buffer, offset) catch
                    return error.Malformed;
                if (read != buffer.len) return error.Malformed;
                return buffer;
            },
        }
    }
};

/// The central directory of a hostile archive may claim absurd sizes; a
/// directory beyond this is refused before any window is allocated. 4096
/// maximal entries fit comfortably.
const max_directory_bytes: u64 = 64 * 1024 * 1024;

pub const Archive = struct {
    source: Source,
    entries: []const Entry,
    total_expanded: u64 = 0,

    /// Parses the central directory only. Entry names are validated here,
    /// so a hostile name rejects the archive before anything is read.
    pub fn open(arena: std.mem.Allocator, bytes: []const u8, limits: core.Limits) Error!Archive {
        return openSource(arena, .{ .bytes = bytes }, limits);
    }

    pub fn openSource(arena: std.mem.Allocator, source: Source, limits: core.Limits) Error!Archive {
        const eocd = try findEndRecordSource(arena, source);
        const entry_count = eocd.entry_count;
        if (entry_count > limits.max_archive_entries) return error.LimitExceeded;
        if (eocd.directory_size > max_directory_bytes) return error.Malformed;
        if (eocd.directory_offset + eocd.directory_size > source.len()) return error.Malformed;

        // The whole central directory as one bounded window; entry names
        // slice into it, and it stays alive in the arena for file sources.
        const directory_len = std.math.cast(usize, eocd.directory_size) orelse
            return error.Malformed;
        const directory = switch (source) {
            .bytes => |whole| blk: {
                const start = std.math.cast(usize, eocd.directory_offset) orelse
                    return error.Malformed;
                break :blk whole[start..][0..directory_len];
            },
            .file => blk: {
                const buffer = try arena.alloc(u8, directory_len);
                break :blk try source.window(eocd.directory_offset, buffer);
            },
        };

        var entries = try arena.alloc(Entry, entry_count);
        var pos: usize = 0;
        for (0..entry_count) |i| {
            if (pos + central_header_len > directory.len) return error.Malformed;
            const header = directory[pos..];
            if (!std.mem.eql(u8, header[0..4], "PK\x01\x02")) return error.Malformed;

            const flags = readInt(u16, header[8..10]);
            const method = readInt(u16, header[10..12]);
            const compressed = readInt(u32, header[20..24]);
            const uncompressed = readInt(u32, header[24..28]);
            const name_len = readInt(u16, header[28..30]);
            const extra_len = readInt(u16, header[30..32]);
            const comment_len = readInt(u16, header[32..34]);
            const header_offset = readInt(u32, header[42..46]);

            if (pos + central_header_len + name_len > directory.len) return error.Malformed;
            const name = directory[pos + central_header_len ..][0..name_len];
            if (name_len > limits.max_entry_name_bytes) return error.LimitExceeded;
            if (!entryNameSafe(name)) return error.HostileEntryName;
            if (flags & 0x0001 != 0) return error.EncryptedEntry;
            if (method != 0 and method != 8) return error.UnsupportedMethod;

            entries[i] = .{
                .name = name,
                .compressed_size = compressed,
                .uncompressed_size = uncompressed,
                .method = @enumFromInt(method),
                .header_offset = header_offset,
            };
            pos += central_header_len + name_len + extra_len + comment_len;
        }
        return .{ .source = source, .entries = entries };
    }

    pub fn find(archive: *const Archive, name: []const u8) ?*const Entry {
        for (archive.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// Extracts one entry under the limits: per-entry size, total size, and
    /// the compression-ratio bomb check, enforced while streaming rather
    /// than after expansion completes.
    pub fn extract(
        archive: *Archive,
        arena: std.mem.Allocator,
        entry: *const Entry,
        limits: core.Limits,
    ) Error![]const u8 {
        const data = try archive.entryData(arena, entry);

        if (entry.uncompressed_size > limits.max_entry_uncompressed) return error.LimitExceeded;
        // The declared sizes bound the budget; the streamed check below
        // holds even when the declaration lies.
        const ratio_budget = @max(entry.compressed_size, 64) * limits.max_compression_ratio;
        const budget = @min(
            @min(limits.max_entry_uncompressed, ratio_budget),
            limits.max_total_uncompressed - @min(archive.total_expanded, limits.max_total_uncompressed),
        );

        const expanded = switch (entry.method) {
            .stored => data,
            .deflate => try inflate(arena, data, budget),
            _ => unreachable,
        };
        if (expanded.len > budget) return error.LimitExceeded;
        archive.total_expanded += expanded.len;
        if (archive.total_expanded > limits.max_total_uncompressed) return error.LimitExceeded;
        return expanded;
    }

    /// The entry's compressed payload. Byte sources slice; file sources
    /// window the local header and then exactly the payload, so peak
    /// memory is one entry, never the archive.
    fn entryData(
        archive: *const Archive,
        arena: std.mem.Allocator,
        entry: *const Entry,
    ) Error![]const u8 {
        const source = archive.source;
        const offset = entry.header_offset;
        if (offset + local_header_len > source.len()) return error.Malformed;

        var header_buffer: [local_header_len]u8 = undefined;
        const header = try source.window(offset, &header_buffer);
        if (!std.mem.eql(u8, header[0..4], "PK\x03\x04")) return error.Malformed;
        const name_len = readInt(u16, header[26..28]);
        const extra_len = readInt(u16, header[28..30]);
        const data_start = offset + local_header_len + name_len + extra_len;
        const size = std.math.cast(usize, entry.compressed_size) orelse return error.Malformed;
        if (data_start + size > source.len()) return error.Malformed;

        switch (source) {
            .bytes => |bytes| {
                const start = std.math.cast(usize, data_start) orelse return error.Malformed;
                return bytes[start..][0..size];
            },
            .file => {
                const buffer = try arena.alloc(u8, size);
                return try source.window(data_start, buffer);
            },
        }
    }
};

const central_header_len = 46;
const local_header_len = 30;
const eocd_len = 22;

const EndRecord = struct {
    entry_count: u16,
    directory_size: u32,
    directory_offset: u32,
};

fn findEndRecord(bytes: []const u8) ?EndRecord {
    if (bytes.len < eocd_len) return null;
    // The EOCD sits at the end, possibly behind a comment up to 64 KiB.
    const scan_start = bytes.len - @min(bytes.len, eocd_len + 65535);
    var i = bytes.len - eocd_len + 1;
    while (i > scan_start) {
        i -= 1;
        if (std.mem.eql(u8, bytes[i..][0..4], "PK\x05\x06")) {
            const record = bytes[i..];
            return .{
                .entry_count = readInt(u16, record[10..12]),
                .directory_size = readInt(u32, record[12..16]),
                .directory_offset = readInt(u32, record[16..20]),
            };
        }
    }
    return null;
}

/// The end record from either source kind: byte sources scan in place;
/// file sources read one bounded tail window (comment plus record).
fn findEndRecordSource(arena: std.mem.Allocator, source: Source) Error!EndRecord {
    switch (source) {
        .bytes => |bytes| return findEndRecord(bytes) orelse error.Malformed,
        .file => {
            const size = source.len();
            if (size < eocd_len) return error.Malformed;
            const tail_len = std.math.cast(usize, @min(size, eocd_len + 65535)) orelse
                return error.Malformed;
            const buffer = try arena.alloc(u8, tail_len);
            const tail = try source.window(size - tail_len, buffer);
            return findEndRecord(tail) orelse error.Malformed;
        },
    }
}

fn readInt(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return std.mem.readInt(T, bytes, .little);
}

fn entryNameSafe(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn inflate(arena: std.mem.Allocator, data: []const u8, budget: u64) Error![]const u8 {
    var input = std.Io.Reader.fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, .raw, &window);
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

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Builds a stored-only ZIP in memory for the tests: local headers, then
/// the central directory, then the end record.
pub fn buildStoredArchive(
    gpa: std.mem.Allocator,
    files: []const struct { name: []const u8, data: []const u8 },
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var offsets = try gpa.alloc(u32, files.len);
    defer gpa.free(offsets);

    for (files, 0..) |file, i| {
        offsets[i] = @intCast(out.items.len);
        try out.appendSlice(gpa, "PK\x03\x04");
        try appendInt(&out, gpa, u16, 20); // version needed
        try appendInt(&out, gpa, u16, 0); // flags
        try appendInt(&out, gpa, u16, 0); // method: stored
        try appendInt(&out, gpa, u32, 0); // time/date
        try appendInt(&out, gpa, u32, std.hash.crc.Crc32.hash(file.data));
        try appendInt(&out, gpa, u32, @intCast(file.data.len));
        try appendInt(&out, gpa, u32, @intCast(file.data.len));
        try appendInt(&out, gpa, u16, @intCast(file.name.len));
        try appendInt(&out, gpa, u16, 0); // extra
        try out.appendSlice(gpa, file.name);
        try out.appendSlice(gpa, file.data);
    }

    const directory_offset: u32 = @intCast(out.items.len);
    for (files, 0..) |file, i| {
        try out.appendSlice(gpa, "PK\x01\x02");
        try appendInt(&out, gpa, u16, 20); // version made by
        try appendInt(&out, gpa, u16, 20); // version needed
        try appendInt(&out, gpa, u16, 0); // flags
        try appendInt(&out, gpa, u16, 0); // method
        try appendInt(&out, gpa, u32, 0); // time/date
        try appendInt(&out, gpa, u32, std.hash.crc.Crc32.hash(file.data));
        try appendInt(&out, gpa, u32, @intCast(file.data.len));
        try appendInt(&out, gpa, u32, @intCast(file.data.len));
        try appendInt(&out, gpa, u16, @intCast(file.name.len));
        try appendInt(&out, gpa, u16, 0); // extra
        try appendInt(&out, gpa, u16, 0); // comment
        try appendInt(&out, gpa, u16, 0); // disk
        try appendInt(&out, gpa, u16, 0); // internal attrs
        try appendInt(&out, gpa, u32, 0); // external attrs
        try appendInt(&out, gpa, u32, offsets[i]);
        try out.appendSlice(gpa, file.name);
    }
    const directory_size: u32 = @intCast(out.items.len - directory_offset);

    try out.appendSlice(gpa, "PK\x05\x06");
    try appendInt(&out, gpa, u16, 0); // disk
    try appendInt(&out, gpa, u16, 0); // directory disk
    try appendInt(&out, gpa, u16, @intCast(files.len));
    try appendInt(&out, gpa, u16, @intCast(files.len));
    try appendInt(&out, gpa, u32, directory_size);
    try appendInt(&out, gpa, u32, directory_offset);
    try appendInt(&out, gpa, u16, 0); // comment length
    return out.toOwnedSlice(gpa);
}

fn appendInt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try out.appendSlice(gpa, &buffer);
}

test "open and extract a stored archive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try buildStoredArchive(arena, &.{
        .{ .name = "word/document.xml", .data = "<doc/>" },
        .{ .name = "[Content_Types].xml", .data = "<types/>" },
    });
    var archive = try Archive.open(arena, bytes, .{});
    try testing.expectEqual(@as(usize, 2), archive.entries.len);
    const entry = archive.find("word/document.xml").?;
    const data = try archive.extract(arena, entry, .{});
    try testing.expectEqualStrings("<doc/>", data);
    try testing.expectEqual(@as(?*const Entry, null), archive.find("missing"));
}

test "a file-backed source opens and extracts through bounded windows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const bytes = try buildStoredArchive(arena, &.{
        .{ .name = "word/document.xml", .data = "<doc/>" },
        .{ .name = "[Content_Types].xml", .data = "<types/>" },
    });

    const dir = ".zig-cache/tmp/zenfmt-zip-source";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};
    const path = dir ++ "/sample.zip";
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });

    const handle = try cwd.openFile(io, path, .{});
    defer handle.close(io);
    var archive = try Archive.openSource(arena, .{ .file = .{
        .io = io,
        .handle = handle,
        .size = bytes.len,
    } }, .{});
    try testing.expectEqual(@as(usize, 2), archive.entries.len);
    const entry = archive.find("word/document.xml").?;
    const data = try archive.extract(arena, entry, .{});
    try testing.expectEqualStrings("<doc/>", data);
}

test "hostile entry names reject the archive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const traversal = try buildStoredArchive(arena, &.{
        .{ .name = "../../etc/passwd", .data = "x" },
    });
    try testing.expectError(error.HostileEntryName, Archive.open(arena, traversal, .{}));

    const absolute = try buildStoredArchive(arena, &.{
        .{ .name = "/etc/passwd", .data = "x" },
    });
    try testing.expectError(error.HostileEntryName, Archive.open(arena, absolute, .{}));

    const backslash = try buildStoredArchive(arena, &.{
        .{ .name = "word\\document.xml", .data = "x" },
    });
    try testing.expectError(error.HostileEntryName, Archive.open(arena, backslash, .{}));
}

test "entry count and size limits are refusals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try buildStoredArchive(arena, &.{
        .{ .name = "a.xml", .data = "aaa" },
        .{ .name = "b.xml", .data = "bbb" },
    });
    try testing.expectError(error.LimitExceeded, Archive.open(arena, bytes, .{
        .max_archive_entries = 1,
    }));

    var archive = try Archive.open(arena, bytes, .{});
    const entry = archive.find("a.xml").?;
    try testing.expectError(error.LimitExceeded, archive.extract(arena, entry, .{
        .max_entry_uncompressed = 2,
    }));
}

test "truncated archives are malformed, not crashes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = try buildStoredArchive(arena, &.{
        .{ .name = "a.xml", .data = "content" },
    });
    try testing.expectError(error.Malformed, Archive.open(arena, bytes[0 .. bytes.len - 4], .{}));
    try testing.expectError(error.Malformed, Archive.open(arena, "PK\x03\x04 not a zip", .{}));
}
