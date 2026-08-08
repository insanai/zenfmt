//! Documentation drift tests (ZDS 0013, Core Contract Repairs): the book's
//! reference chapter must agree with the compiler's truth. Every report
//! code literal in the source appears in the catalog, every cataloged code
//! exists in the source, and every named limit is documented. A new code
//! or limit fails here until chapter 8 records it.

const std = @import("std");
const testing = std.testing;
const core = @import("zenfmt_core");

const reference_path = "docs/book/08_reference.typ";
const source_roots = [_][]const u8{ "core", "support", "formats", "src" };

fn collectSourceCodes(
    arena: std.mem.Allocator,
    io: std.Io,
) !std.StringArrayHashMapUnmanaged(void) {
    var codes: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (source_roots) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            if (std.mem.endsWith(u8, entry.basename, "_test.zig")) continue;
            const bytes = try entry.dir.readFileAlloc(io, entry.basename, arena, .limited(4 * 1024 * 1024));
            try collectCodesFrom(arena, bytes, &codes);
        }
    }
    return codes;
}

/// Report-code literals are spelled `.code = "family.kebab-name"`.
fn collectCodesFrom(
    arena: std.mem.Allocator,
    bytes: []const u8,
    codes: *std.StringArrayHashMapUnmanaged(void),
) !void {
    const needle = ".code = \"";
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, index, needle)) |found| {
        const start = found + needle.len;
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '"') orelse break;
        const code = bytes[start..end];
        index = end;
        if (std.mem.indexOfScalar(u8, code, '.') == null) continue;
        // The `test.` family is reserved for synthetic codes inside test
        // blocks; it never reaches users and is not cataloged.
        if (std.mem.startsWith(u8, code, "test.")) continue;
        try codes.put(arena, code, {});
    }
}

/// Cataloged codes appear in the chapter as \[`family.kebab-name`\] rows.
fn collectBookCodes(
    arena: std.mem.Allocator,
    bytes: []const u8,
) !std.StringArrayHashMapUnmanaged(void) {
    var codes: std.StringArrayHashMapUnmanaged(void) = .empty;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, index, "[`")) |found| {
        const start = found + 2;
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '`') orelse break;
        const token = bytes[start..end];
        index = end;
        if (!isReportCode(token)) continue;
        try codes.put(arena, token, {});
    }
    return codes;
}

fn isReportCode(token: []const u8) bool {
    if (token.len == 0) return false;
    var dots: usize = 0;
    for (token) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-', '_' => {},
        '.' => dots += 1,
        else => return false,
    };
    // Exactly one dot separates family from name; flags and limits never
    // match this shape, and file names are excluded by their extensions.
    if (dots != 1 or token[0] == '.' or token[token.len - 1] == '.') return false;
    const file_extensions = [_][]const u8{ ".xml", ".zig", ".json", ".typ", ".md", ".rels", ".txt", ".bin", ".html", ".opf" };
    for (file_extensions) |extension| {
        if (std.mem.endsWith(u8, token, extension)) return false;
    }
    return true;
}

test "every report code in the source is cataloged in chapter 8, and vice versa" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const book = try std.Io.Dir.cwd().readFileAlloc(io, reference_path, arena, .limited(1 << 20));
    var source_codes = try collectSourceCodes(arena, io);
    var book_codes = try collectBookCodes(arena, book);

    var missing_from_book: usize = 0;
    for (source_codes.keys()) |code| {
        if (book_codes.contains(code)) continue;
        missing_from_book += 1;
        std.debug.print("report code missing from chapter 8: {s}\n", .{code});
    }
    var missing_from_source: usize = 0;
    for (book_codes.keys()) |code| {
        if (source_codes.contains(code)) continue;
        missing_from_source += 1;
        std.debug.print("chapter 8 catalogs a code no source emits: {s}\n", .{code});
    }
    try testing.expectEqual(@as(usize, 0), missing_from_book);
    try testing.expectEqual(@as(usize, 0), missing_from_source);
}

test "every named limit is documented in chapter 8" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const book = try std.Io.Dir.cwd().readFileAlloc(io, reference_path, arena, .limited(1 << 20));
    var missing: usize = 0;
    inline for (@typeInfo(core.Limits).@"struct".fields) |field| {
        if (std.mem.indexOf(u8, book, "`" ++ field.name ++ "`") == null) {
            missing += 1;
            std.debug.print("limit missing from chapter 8: {s}\n", .{field.name});
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "the README's release claim matches build.zig.zon" {
    // The version appears in one hand-written place. Every other surface
    // derives it, so this is the only one that can drift — and a README
    // announcing the wrong release is the first thing a visitor reads.
    const gpa = testing.allocator;
    const readme = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "README.md",
        gpa,
        .limited(1 << 20),
    );
    defer gpa.free(readme);

    const version = @import("zenfmt").version;
    const claim = try std.fmt.allocPrint(gpa, "Current release: {s}.", .{version});
    defer gpa.free(claim);
    if (std.mem.indexOf(u8, readme, claim) == null) {
        std.debug.print(
            "README.md does not state \"{s}\"; build.zig.zon says {s}\n",
            .{ claim, version },
        );
        return error.ReadmeVersionDrift;
    }
}
