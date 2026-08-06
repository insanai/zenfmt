//! `zenfmt_cfb`: Compound File Binary reading (MS-CFB), the container
//! under the legacy binary Office formats (`.doc`, `.xls`, `.ppt`).
//!
//! The same discipline as the ZIP reader: parse the directory, read only
//! the streams asked for, bound every chain walk so a crafted cyclic FAT
//! is a refusal rather than a hang, and enforce the byte limits while
//! copying. Shared legacy text helpers (cp1252, UTF-16LE) live here too,
//! because every CFB-hosted format needs them.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");

pub const Error = error{
    OutOfMemory,
    /// Not a compound file, or one too broken to trust.
    Malformed,
    /// A named resource limit was hit; the caller reports which.
    LimitExceeded,
};

const header_len = 512;
const dir_entry_len = 128;
const mini_sector_len = 64;

const free_sect: u32 = 0xFFFFFFFF;
const end_of_chain: u32 = 0xFFFFFFFE;
const fat_sect: u32 = 0xFFFFFFFD;
const dif_sect: u32 = 0xFFFFFFFC;
const no_stream: u32 = 0xFFFFFFFF;

pub const ObjectType = enum(u8) {
    unknown = 0,
    storage = 1,
    stream = 2,
    root = 5,
    _,
};

pub const Entry = struct {
    /// Directory entry name, decoded from UTF-16LE to UTF-8.
    name: []const u8,
    object_type: ObjectType,
    start_sector: u32,
    size: u64,
};

pub const Cfb = struct {
    bytes: []const u8,
    sector_size: u32,
    mini_cutoff: u32,
    fat: []const u32,
    minifat: []const u32,
    entries: []const Entry,
    /// The root entry's stream, holding every mini-sector.
    mini_stream: []const u8,
    total_read: u64 = 0,

    pub fn open(arena: std.mem.Allocator, bytes: []const u8, limits: core.Limits) Error!Cfb {
        if (bytes.len < header_len) return error.Malformed;
        if (!std.mem.eql(u8, bytes[0..8], "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"))
            return error.Malformed;
        const sector_shift = readInt(u16, bytes[30..32]);
        if (sector_shift != 9 and sector_shift != 12) return error.Malformed;
        const sector_size = @as(u32, 1) << @intCast(sector_shift);
        if (readInt(u16, bytes[32..34]) != 6) return error.Malformed;
        const mini_cutoff = readInt(u32, bytes[56..60]);

        var cfb: Cfb = .{
            .bytes = bytes,
            .sector_size = sector_size,
            .mini_cutoff = mini_cutoff,
            .fat = &.{},
            .minifat = &.{},
            .entries = &.{},
            .mini_stream = &.{},
        };
        cfb.fat = try cfb.readFat(arena);
        cfb.entries = try cfb.readDirectory(arena, readInt(u32, bytes[48..52]), limits);
        cfb.minifat = try cfb.readMiniFat(arena);
        // The mini stream is the root entry's own stream.
        for (cfb.entries) |*entry| {
            if (entry.object_type == .root) {
                cfb.mini_stream = try cfb.readChain(arena, entry.start_sector, entry.size);
                break;
            }
        }
        return cfb;
    }

    pub fn find(cfb: *const Cfb, name: []const u8) ?*const Entry {
        for (cfb.entries) |*entry| {
            if (entry.object_type != .stream) continue;
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// Reads one stream under the limits. Streams below the cutoff live in
    /// the mini stream and follow the mini-FAT; the rest follow the FAT.
    pub fn readStream(
        cfb: *Cfb,
        arena: std.mem.Allocator,
        entry: *const Entry,
        limits: core.Limits,
    ) Error![]const u8 {
        if (entry.size > limits.max_entry_uncompressed) return error.LimitExceeded;
        if (cfb.total_read +| entry.size > limits.max_total_uncompressed)
            return error.LimitExceeded;
        const data = if (entry.object_type != .root and entry.size < cfb.mini_cutoff)
            try cfb.readMiniChain(arena, entry.start_sector, entry.size)
        else
            try cfb.readChain(arena, entry.start_sector, entry.size);
        cfb.total_read += data.len;
        return data;
    }

    /// Sectors the file can hold; every chain walk is bounded by it, so a
    /// FAT cycle exhausts the bound and refuses instead of spinning.
    fn sectorCount(cfb: *const Cfb) u32 {
        const body = cfb.bytes.len -| header_len;
        return @intCast((body + cfb.sector_size - 1) / cfb.sector_size);
    }

    fn sectorBytes(cfb: *const Cfb, index: u32) Error![]const u8 {
        const offset = header_len + @as(u64, index) * cfb.sector_size;
        if (offset >= cfb.bytes.len) return error.Malformed;
        const end = @min(offset + cfb.sector_size, cfb.bytes.len);
        return cfb.bytes[@intCast(offset)..@intCast(end)];
    }

    /// The FAT sector list comes from the header DIFAT array and then the
    /// DIFAT sector chain, both bounded.
    fn readFat(cfb: *const Cfb, arena: std.mem.Allocator) Error![]const u32 {
        const ids_per_sector = cfb.sector_size / 4;
        var fat_sectors: std.ArrayList(u32) = .empty;
        defer fat_sectors.deinit(arena);

        for (0..109) |i| {
            const id = readInt(u32, cfb.bytes[76 + i * 4 ..][0..4]);
            if (id >= dif_sect) break;
            try fat_sectors.append(arena, id);
        }
        var difat = readInt(u32, cfb.bytes[68..72]);
        var difat_steps: u32 = 0;
        const bound = cfb.sectorCount() + 1;
        while (difat < dif_sect) {
            difat_steps += 1;
            if (difat_steps > bound) return error.Malformed;
            const sector = try cfb.sectorBytes(difat);
            if (sector.len < cfb.sector_size) return error.Malformed;
            for (0..ids_per_sector - 1) |i| {
                const id = readInt(u32, sector[i * 4 ..][0..4]);
                if (id >= dif_sect) continue;
                try fat_sectors.append(arena, id);
            }
            difat = readInt(u32, sector[(ids_per_sector - 1) * 4 ..][0..4]);
        }

        const fat = try arena.alloc(u32, fat_sectors.items.len * ids_per_sector);
        for (fat_sectors.items, 0..) |id, i| {
            const sector = try cfb.sectorBytes(id);
            if (sector.len < cfb.sector_size) return error.Malformed;
            for (0..ids_per_sector) |j| {
                fat[i * ids_per_sector + j] = readInt(u32, sector[j * 4 ..][0..4]);
            }
        }
        return fat;
    }

    fn readMiniFat(cfb: *const Cfb, arena: std.mem.Allocator) Error![]const u32 {
        const declared = readInt(u32, cfb.bytes[64..68]);
        if (declared == 0) return &.{};
        const ids_per_sector = cfb.sector_size / 4;
        var minifat: std.ArrayList(u32) = .empty;
        var sector = readInt(u32, cfb.bytes[60..64]);
        var steps: u32 = 0;
        const bound = @min(declared, cfb.sectorCount() + 1);
        while (sector < dif_sect) {
            steps += 1;
            if (steps > bound) break;
            const data = try cfb.sectorBytes(sector);
            for (0..@min(ids_per_sector, data.len / 4)) |i| {
                try minifat.append(arena, readInt(u32, data[i * 4 ..][0..4]));
            }
            sector = cfb.fatNext(sector);
        }
        return minifat.items;
    }

    fn fatNext(cfb: *const Cfb, sector: u32) u32 {
        if (sector >= cfb.fat.len) return end_of_chain;
        return cfb.fat[sector];
    }

    fn readChain(
        cfb: *const Cfb,
        arena: std.mem.Allocator,
        start: u32,
        size: u64,
    ) Error![]const u8 {
        const total = std.math.cast(usize, size) orelse return error.Malformed;
        var out = try arena.alloc(u8, total);
        var written: usize = 0;
        var sector = start;
        var steps: u32 = 0;
        const bound = cfb.sectorCount() + 1;
        while (written < total) {
            if (sector >= dif_sect) return error.Malformed;
            steps += 1;
            if (steps > bound) return error.Malformed;
            const data = try cfb.sectorBytes(sector);
            const take = @min(data.len, total - written);
            @memcpy(out[written..][0..take], data[0..take]);
            written += take;
            sector = cfb.fatNext(sector);
        }
        return out;
    }

    fn readMiniChain(
        cfb: *const Cfb,
        arena: std.mem.Allocator,
        start: u32,
        size: u64,
    ) Error![]const u8 {
        const total = std.math.cast(usize, size) orelse return error.Malformed;
        var out = try arena.alloc(u8, total);
        var written: usize = 0;
        var sector = start;
        var steps: usize = 0;
        const bound = cfb.minifat.len + 1;
        while (written < total) {
            if (sector >= dif_sect) return error.Malformed;
            steps += 1;
            if (steps > bound) return error.Malformed;
            const offset = @as(u64, sector) * mini_sector_len;
            if (offset >= cfb.mini_stream.len) return error.Malformed;
            const end = @min(offset + mini_sector_len, cfb.mini_stream.len);
            const data = cfb.mini_stream[@intCast(offset)..@intCast(end)];
            const take = @min(data.len, total - written);
            @memcpy(out[written..][0..take], data[0..take]);
            written += take;
            sector = if (sector < cfb.minifat.len) cfb.minifat[sector] else end_of_chain;
        }
        return out;
    }

    fn readDirectory(
        cfb: *const Cfb,
        arena: std.mem.Allocator,
        first_sector: u32,
        limits: core.Limits,
    ) Error![]const Entry {
        var entries: std.ArrayList(Entry) = .empty;
        var sector = first_sector;
        var steps: u32 = 0;
        const bound = cfb.sectorCount() + 1;
        while (sector < dif_sect) {
            steps += 1;
            if (steps > bound) return error.Malformed;
            const data = try cfb.sectorBytes(sector);
            var offset: usize = 0;
            while (offset + dir_entry_len <= data.len) : (offset += dir_entry_len) {
                const raw = data[offset..][0..dir_entry_len];
                const name_bytes = readInt(u16, raw[64..66]);
                if (name_bytes < 2 or name_bytes > 64 or name_bytes % 2 != 0) continue;
                const object_type: ObjectType = @enumFromInt(raw[66]);
                switch (object_type) {
                    .storage, .stream, .root => {},
                    else => continue,
                }
                if (entries.items.len >= limits.max_archive_entries)
                    return error.LimitExceeded;
                var name: std.ArrayList(u8) = .empty;
                try utf16LeToUtf8(arena, &name, raw[0 .. name_bytes - 2]);
                const size = if (readInt(u16, cfb.bytes[26..28]) == 3)
                    readInt(u32, raw[120..124])
                else
                    readInt(u64, raw[120..128]);
                try entries.append(arena, .{
                    .name = name.items,
                    .object_type = object_type,
                    .start_sector = readInt(u32, raw[116..120]),
                    .size = size,
                });
            }
            sector = cfb.fatNext(sector);
        }
        return entries.items;
    }
};

fn readInt(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    return std.mem.readInt(T, bytes, .little);
}

// ------------------------------------------------------ legacy encodings

/// Windows-1252, the 8-bit encoding of compressed legacy Office text.
pub fn cp1252ToUnicode(byte: u8) u21 {
    if (byte < 0x80) return byte;
    const high = [_]u21{
        0x20ac, 0x81,   0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
        0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8d,   0x017d, 0x8f,
        0x90,   0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
        0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x9d,   0x017e, 0x0178,
    };
    if (byte < 0xa0) return high[byte - 0x80];
    return byte;
}

/// Appends UTF-16LE bytes (possibly unaligned, possibly odd-tailed) as
/// UTF-8. Unpaired surrogates become U+FFFD; the text survives.
pub fn utf16LeToUtf8(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bytes: []const u8,
) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i + 1 < bytes.len) {
        var code: u21 = readInt(u16, bytes[i..][0..2]);
        i += 2;
        if (code >= 0xD800 and code <= 0xDBFF and i + 1 < bytes.len) {
            const low = readInt(u16, bytes[i..][0..2]);
            if (low >= 0xDC00 and low <= 0xDFFF) {
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                i += 2;
            } else {
                code = 0xFFFD;
            }
        } else if (code >= 0xD800 and code <= 0xDFFF) {
            code = 0xFFFD;
        }
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code, &encoded) catch blk: {
            encoded[0] = 0xEF;
            encoded[1] = 0xBF;
            encoded[2] = 0xBD;
            break :blk 3;
        };
        try out.appendSlice(arena, encoded[0..length]);
    }
}

// ---------------------------------------------------------- test builder

/// Builds a minimal version-3 compound file for the format tests: mini
/// stream for small streams, FAT chains for large ones, one FAT sector.
pub fn buildFile(
    gpa: std.mem.Allocator,
    streams: []const struct { name: []const u8, data: []const u8 },
) ![]u8 {
    const sector = 512;
    var large_start = try gpa.alloc(u32, streams.len);
    defer gpa.free(large_start);
    var mini_start = try gpa.alloc(u32, streams.len);
    defer gpa.free(mini_start);

    // Data sectors for the large streams come first.
    var sectors: std.ArrayList([sector]u8) = .empty;
    defer sectors.deinit(gpa);
    var fat: std.ArrayList(u32) = .empty;
    defer fat.deinit(gpa);
    for (streams, 0..) |stream, i| {
        large_start[i] = no_stream;
        if (stream.data.len < 4096) continue;
        large_start[i] = @intCast(sectors.items.len);
        try appendChained(gpa, &sectors, &fat, stream.data, sector);
    }

    // The mini stream: 64-byte slots, chained in the mini FAT.
    var mini_data: std.ArrayList(u8) = .empty;
    defer mini_data.deinit(gpa);
    var minifat: std.ArrayList(u32) = .empty;
    defer minifat.deinit(gpa);
    for (streams, 0..) |stream, i| {
        mini_start[i] = no_stream;
        if (stream.data.len >= 4096) continue;
        mini_start[i] = @intCast(minifat.items.len);
        const slots = @max((stream.data.len + mini_sector_len - 1) / mini_sector_len, 1);
        for (0..slots) |slot| {
            const next: u32 = if (slot + 1 < slots)
                @intCast(minifat.items.len + 1)
            else
                end_of_chain;
            try minifat.append(gpa, next);
        }
        try mini_data.appendSlice(gpa, stream.data);
        try mini_data.appendNTimes(gpa, 0, slots * mini_sector_len - stream.data.len);
    }
    const mini_container_start: u32 = @intCast(sectors.items.len);
    try appendChained(gpa, &sectors, &fat, mini_data.items, sector);

    var minifat_sector: u32 = end_of_chain;
    if (minifat.items.len > 0) {
        minifat_sector = @intCast(sectors.items.len);
        try sectors.append(gpa, @splat(0xFF));
        try fat.append(gpa, end_of_chain);
        for (minifat.items, 0..) |value, i| {
            std.mem.writeInt(u32, sectors.items[minifat_sector][i * 4 ..][0..4], value, .little);
        }
    }

    // Directory: the root plus one entry per stream, four per sector.
    const dir_start: u32 = @intCast(sectors.items.len);
    const dir_count = 1 + streams.len;
    const dir_sectors = (dir_count + 3) / 4;
    for (0..dir_sectors) |i| {
        try sectors.append(gpa, @splat(0));
        try fat.append(gpa, if (i + 1 < dir_sectors) @intCast(sectors.items.len) else end_of_chain);
    }
    writeDirEntry(
        dirSlot(sectors.items[dir_start..], 0),
        "Root Entry",
        .root,
        if (mini_data.items.len > 0) mini_container_start else end_of_chain,
        mini_data.items.len,
        if (streams.len > 0) 1 else no_stream,
        no_stream,
    );
    for (streams, 0..) |stream, i| {
        const start = if (stream.data.len < 4096) mini_start[i] else large_start[i];
        writeDirEntry(
            dirSlot(sectors.items[dir_start..], i + 1),
            stream.name,
            .stream,
            if (stream.data.len == 0) end_of_chain else start,
            stream.data.len,
            no_stream,
            if (i + 1 < streams.len) @intCast(i + 2) else no_stream,
        );
    }

    const fat_sector_index: u32 = @intCast(sectors.items.len);
    try sectors.append(gpa, @splat(0xFF));
    try fat.append(gpa, fat_sect);
    assert(fat.items.len <= sector / 4);
    for (fat.items, 0..) |value, i| {
        std.mem.writeInt(u32, sectors.items[fat_sector_index][i * 4 ..][0..4], value, .little);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendNTimes(gpa, 0, header_len);
    const header = out.items[0..header_len];
    @memcpy(header[0..8], "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1");
    std.mem.writeInt(u16, header[24..26], 0x003E, .little); // minor version
    std.mem.writeInt(u16, header[26..28], 3, .little); // major version
    std.mem.writeInt(u16, header[28..30], 0xFFFE, .little); // byte order
    std.mem.writeInt(u16, header[30..32], 9, .little); // sector shift
    std.mem.writeInt(u16, header[32..34], 6, .little); // mini sector shift
    std.mem.writeInt(u32, header[44..48], 1, .little); // FAT sector count
    std.mem.writeInt(u32, header[48..52], dir_start, .little);
    std.mem.writeInt(u32, header[56..60], 4096, .little); // mini cutoff
    std.mem.writeInt(u32, header[60..64], minifat_sector, .little);
    const minifat_count: u32 = if (minifat.items.len > 0) 1 else 0;
    std.mem.writeInt(u32, header[64..68], minifat_count, .little);
    std.mem.writeInt(u32, header[68..72], end_of_chain, .little); // no DIFAT chain
    @memset(header[76..header_len], 0xFF);
    std.mem.writeInt(u32, header[76..80], fat_sector_index, .little);
    for (sectors.items) |*data| try out.appendSlice(gpa, data);
    return out.toOwnedSlice(gpa);
}

fn appendChained(
    gpa: std.mem.Allocator,
    sectors: *std.ArrayList([512]u8),
    fat: *std.ArrayList(u32),
    data: []const u8,
    comptime sector: usize,
) !void {
    if (data.len == 0) return;
    const count = (data.len + sector - 1) / sector;
    for (0..count) |i| {
        var chunk: [sector]u8 = @splat(0);
        const from = i * sector;
        const take = @min(sector, data.len - from);
        @memcpy(chunk[0..take], data[from..][0..take]);
        try sectors.append(gpa, chunk);
        const next: u32 = if (i + 1 < count) @intCast(sectors.items.len) else end_of_chain;
        try fat.append(gpa, next);
    }
}

fn dirSlot(sectors: [][512]u8, index: usize) *[dir_entry_len]u8 {
    return sectors[index / 4][(index % 4) * dir_entry_len ..][0..dir_entry_len];
}

fn writeDirEntry(
    raw: *[dir_entry_len]u8,
    name: []const u8,
    object_type: ObjectType,
    start: u32,
    size: usize,
    child: u32,
    right: u32,
) void {
    assert(name.len <= 31);
    @memset(raw, 0);
    for (name, 0..) |byte, i| {
        std.mem.writeInt(u16, raw[i * 2 ..][0..2], byte, .little);
    }
    std.mem.writeInt(u16, raw[64..66], @intCast((name.len + 1) * 2), .little);
    raw[66] = @intFromEnum(object_type);
    raw[67] = 1; // black
    std.mem.writeInt(u32, raw[68..72], no_stream, .little); // left sibling
    std.mem.writeInt(u32, raw[72..76], right, .little);
    std.mem.writeInt(u32, raw[76..80], child, .little);
    std.mem.writeInt(u32, raw[116..120], start, .little);
    std.mem.writeInt(u64, raw[120..128], size, .little);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "open and read mini and regular streams" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big = try arena.alloc(u8, 5000);
    for (big, 0..) |*byte, i| byte.* = @intCast(i % 251);
    const bytes = try buildFile(arena, &.{
        .{ .name = "WordDocument", .data = "small stream body" },
        .{ .name = "1Table", .data = big },
    });
    var cfb = try Cfb.open(arena, bytes, .{});
    const small_entry = cfb.find("WordDocument").?;
    try testing.expectEqualStrings(
        "small stream body",
        try cfb.readStream(arena, small_entry, .{}),
    );
    const big_entry = cfb.find("1Table").?;
    try testing.expectEqualSlices(u8, big, try cfb.readStream(arena, big_entry, .{}));
    try testing.expectEqual(@as(?*const Entry, null), cfb.find("Workbook"));
}

test "a cyclic FAT chain refuses instead of spinning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big = try arena.alloc(u8, 5000);
    @memset(big, 'z');
    const bytes = try buildFile(arena, &.{
        .{ .name = "Workbook", .data = big },
    });
    var cfb = try Cfb.open(arena, bytes, .{});
    // Point the first FAT entry back at itself and claim a stream longer
    // than the file: the walk hits the sector-count bound and refuses.
    const fat = try arena.dupe(u32, cfb.fat);
    fat[0] = 0;
    cfb.fat = fat;
    const lying: Entry = .{
        .name = "Workbook",
        .object_type = .stream,
        .start_sector = 0,
        .size = bytes.len * 2,
    };
    try testing.expectError(error.Malformed, cfb.readStream(arena, &lying, .{}));
}

test "truncated and hostile files are refusals, not crashes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.Malformed, Cfb.open(arena, "\xd0\xcf\x11\xe0 nope", .{}));
    const bytes = try buildFile(arena, &.{
        .{ .name = "WordDocument", .data = "body" },
    });
    try testing.expectError(error.Malformed, Cfb.open(arena, bytes[0..300], .{}));

    var cfb = try Cfb.open(arena, bytes, .{});
    const entry = cfb.find("WordDocument").?;
    try testing.expectError(error.LimitExceeded, cfb.readStream(arena, entry, .{
        .max_entry_uncompressed = 2,
    }));
}

test "legacy encodings" {
    try testing.expectEqual(@as(u21, 0x20ac), cp1252ToUnicode(0x80));
    try testing.expectEqual(@as(u21, 0xe9), cp1252ToUnicode(0xe9));
    try testing.expectEqual(@as(u21, 'A'), cp1252ToUnicode('A'));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try utf16LeToUtf8(arena, &out, "Z\x00i\x00g\x00 \x00\x3d\xd8\x80\xde");
    try testing.expectEqualStrings("Zig \u{1F680}", out.items);
}
