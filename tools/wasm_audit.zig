//! The WebAssembly section auditor (ZDS 0015, Target decision).
//!
//! The browser module's security claim is that it holds no host authority:
//! no filesystem, no network, no clock, no randomness, no threads. On
//! `wasm32-freestanding` that claim has a precise, checkable form — the
//! module's import table is empty — and this tool checks it by parsing the
//! binary's sections.
//!
//! It parses rather than greps because a textual dump is not a security
//! boundary: it would depend on an external tool's formatting, and a name
//! containing a newline or a quote could hide an entry from a line-oriented
//! check. Reading the binary means an import is either in the table or it is
//! not.
//!
//! Every read is bounded and every offset is checked, because this tool's
//! whole job is to be trustworthy about a file it did not produce.

const std = @import("std");
const exports = @import("zenfmt_wasm_exports");

const Section = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    data_count = 12,
    _,
};

const ExportKind = enum(u8) {
    function = 0,
    table = 1,
    memory = 2,
    global = 3,
    _,
};

const Error = error{
    NotWasm,
    UnsupportedVersion,
    Truncated,
    MalformedLeb,
    SectionOverrun,
    DuplicateSection,
};

/// A bounds-checked cursor over the module bytes.
const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(cursor: *Cursor, len: usize) Error![]const u8 {
        if (len > cursor.bytes.len - cursor.offset) return error.Truncated;
        const slice = cursor.bytes[cursor.offset..][0..len];
        cursor.offset += len;
        return slice;
    }

    fn byte(cursor: *Cursor) Error!u8 {
        const slice = try cursor.take(1);
        return slice[0];
    }

    /// Unsigned LEB128, bounded to five bytes so a crafted module cannot make
    /// this loop forever.
    fn leb(cursor: *Cursor) Error!u32 {
        var value: u32 = 0;
        var shift: u5 = 0;
        for (0..5) |_| {
            const b = try cursor.byte();
            value |= @as(u32, b & 0x7f) << shift;
            if (b & 0x80 == 0) return value;
            shift = std.math.add(u5, shift, 7) catch return error.MalformedLeb;
        }
        return error.MalformedLeb;
    }

    fn name(cursor: *Cursor) Error![]const u8 {
        const len = try cursor.leb();
        return cursor.take(len);
    }

    fn atEnd(cursor: *const Cursor) bool {
        return cursor.offset >= cursor.bytes.len;
    }
};

const Findings = struct {
    imports: std.ArrayList([]const u8) = .empty,
    functions: std.ArrayList([]const u8) = .empty,
    memories: std.ArrayList([]const u8) = .empty,
    others: std.ArrayList([]const u8) = .empty,
    custom_sections: std.ArrayList([]const u8) = .empty,
    memory_max_pages: ?u32 = null,
    stack_pointer_init: ?u32 = null,
    first_data_offset: ?u32 = null,
    section_sizes: std.ArrayList(SectionSize) = .empty,

    const SectionSize = struct { id: u8, bytes: u32 };
};

pub fn main(init: std.process.Init) !u8 {
    var arena_instance = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const io = init.io;

    var iterator = std.process.Args.Iterator.init(init.minimal.args);
    defer iterator.deinit();
    _ = iterator.next();

    var path: ?[]const u8 = null;
    var expected_max_pages: ?u32 = null;
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--max-memory-pages")) {
            const value = iterator.next() orelse return usage();
            expected_max_pages = std.fmt.parseInt(u32, value, 10) catch return usage();
        } else if (path == null) {
            path = try arena.dupe(u8, arg);
        } else {
            return usage();
        }
    }
    const module_path = path orelse return usage();

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        module_path,
        arena,
        .limited(256 * 1024 * 1024),
    ) catch |err| {
        std.debug.print("wasm-audit: cannot read {s}: {s}\n", .{
            module_path,
            @errorName(err),
        });
        return 2;
    };

    var findings: Findings = .{};
    parse(arena, bytes, &findings) catch |err| {
        std.debug.print("wasm-audit: {s} is not a module this tool can read: {s}\n", .{
            module_path,
            @errorName(err),
        });
        return 2;
    };

    return report(module_path, &findings, expected_max_pages);
}

fn usage() u8 {
    std.debug.print("usage: wasm-audit <module.wasm> [--max-memory-pages N]\n", .{});
    return 2;
}

fn parse(arena: std.mem.Allocator, bytes: []const u8, out: *Findings) !void {
    var cursor: Cursor = .{ .bytes = bytes };
    const magic = try cursor.take(4);
    if (!std.mem.eql(u8, magic, "\x00asm")) return error.NotWasm;
    const version = try cursor.take(4);
    if (!std.mem.eql(u8, version, "\x01\x00\x00\x00")) return error.UnsupportedVersion;

    var seen = std.AutoHashMap(u8, void).init(arena);
    while (!cursor.atEnd()) {
        const id = try cursor.byte();
        const size = try cursor.leb();
        const body = try cursor.take(size);
        try out.section_sizes.append(arena, .{ .id = id, .bytes = size });

        if (id != @intFromEnum(Section.custom)) {
            if (seen.contains(id)) return error.DuplicateSection;
            try seen.put(id, {});
        }

        var section: Cursor = .{ .bytes = body };
        switch (@as(Section, @enumFromInt(id))) {
            .custom => try out.custom_sections.append(arena, try section.name()),
            .import => try readImports(arena, &section, out),
            .memory => try readMemory(&section, out),
            .global => try readGlobals(&section, out),
            .@"export" => try readExports(arena, &section, out),
            .data => try readData(&section, out),
            else => {},
        }
    }
}

fn readImports(arena: std.mem.Allocator, section: *Cursor, out: *Findings) !void {
    const count = try section.leb();
    for (0..count) |_| {
        const module = try section.name();
        const field = try section.name();
        try out.imports.append(
            arena,
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ module, field }),
        );
        // Skip the descriptor; its shape varies by kind and the audit only
        // needs to know that an import exists at all.
        const kind = try section.byte();
        switch (@as(ExportKind, @enumFromInt(kind))) {
            .function => _ = try section.leb(),
            .table => {
                _ = try section.byte();
                try skipLimits(section);
            },
            .memory => try skipLimits(section),
            .global => {
                _ = try section.byte();
                _ = try section.byte();
            },
            _ => return error.SectionOverrun,
        }
    }
}

fn skipLimits(section: *Cursor) !void {
    const flags = try section.byte();
    _ = try section.leb();
    if (flags & 0x01 != 0) _ = try section.leb();
}

fn readMemory(section: *Cursor, out: *Findings) !void {
    const count = try section.leb();
    for (0..count) |_| {
        const flags = try section.byte();
        _ = try section.leb();
        if (flags & 0x01 != 0) out.memory_max_pages = try section.leb();
    }
}

/// Locates `__stack_pointer`'s initial value: the first mutable i32 global
/// with a constant initializer. WebAssembly has no guard page, so knowing the
/// stack sits below the data segments is what makes an overflow trap rather
/// than quietly overwrite static data.
fn readGlobals(section: *Cursor, out: *Findings) !void {
    const count = try section.leb();
    for (0..count) |_| {
        const value_type = try section.byte();
        const mutable = try section.byte();
        const opcode = try section.byte();
        if (opcode == 0x41) {
            const value = try signedLeb(section);
            if (out.stack_pointer_init == null and value_type == 0x7f and mutable == 1) {
                out.stack_pointer_init = @bitCast(value);
            }
        } else {
            // Any other initializer form: skip to the end marker.
            while ((try section.byte()) != 0x0b) {}
            continue;
        }
        _ = try section.byte(); // end
    }
}

fn signedLeb(section: *Cursor) !i32 {
    var value: i32 = 0;
    var shift: u5 = 0;
    for (0..5) |_| {
        const b = try section.byte();
        value |= @as(i32, @intCast(b & 0x7f)) << shift;
        if (b & 0x80 == 0) {
            if (shift < 31 and (b & 0x40) != 0) {
                value |= @as(i32, -1) << (shift + 7);
            }
            return value;
        }
        shift = std.math.add(u5, shift, 7) catch return error.MalformedLeb;
    }
    return error.MalformedLeb;
}

fn readData(section: *Cursor, out: *Findings) !void {
    const count = try section.leb();
    if (count == 0) return;
    const flags = try section.leb();
    if (flags != 0) return;
    const opcode = try section.byte();
    if (opcode != 0x41) return;
    const offset = try signedLeb(section);
    out.first_data_offset = @bitCast(offset);
}

fn readExports(arena: std.mem.Allocator, section: *Cursor, out: *Findings) !void {
    const count = try section.leb();
    for (0..count) |_| {
        const name = try section.name();
        const kind = try section.byte();
        _ = try section.leb();
        switch (@as(ExportKind, @enumFromInt(kind))) {
            .function => try out.functions.append(arena, name),
            .memory => try out.memories.append(arena, name),
            else => try out.others.append(arena, name),
        }
    }
}

fn report(path: []const u8, out: *Findings, expected_max_pages: ?u32) u8 {
    var failures: u32 = 0;

    // The import allowlist is empty. Any import at all is a failure, and the
    // offending entry is named so the cause is obvious rather than a hunt.
    for (out.imports.items) |name| {
        std.debug.print("wasm-audit: module imports '{s}'; the allowlist is empty\n", .{name});
        failures += 1;
    }

    for (out.functions.items) |name| {
        if (!listed(name)) {
            std.debug.print("wasm-audit: unexpected export '{s}'\n", .{name});
            failures += 1;
        }
    }
    for (exports.exported_names) |expected| {
        if (!present(out.functions.items, expected)) {
            std.debug.print("wasm-audit: missing export '{s}'\n", .{expected});
            failures += 1;
        }
    }
    if (!present(out.memories.items, exports.exported_memory)) {
        std.debug.print("wasm-audit: the module does not export its memory\n", .{});
        failures += 1;
    }
    for (out.others.items) |name| {
        std.debug.print("wasm-audit: unexpected non-function export '{s}'\n", .{name});
        failures += 1;
    }

    // A stripped module carries no name or debug sections: symbol names are
    // not something to serve to every visitor.
    for (out.custom_sections.items) |name| {
        if (std.mem.eql(u8, name, "name") or std.mem.startsWith(u8, name, ".debug")) {
            std.debug.print("wasm-audit: module is not stripped: custom section '{s}'\n", .{name});
            failures += 1;
        }
    }

    if (out.memory_max_pages) |pages| {
        if (expected_max_pages) |want| {
            if (pages != want) {
                std.debug.print(
                    "wasm-audit: memory maximum is {d} pages, expected {d}\n",
                    .{ pages, want },
                );
                failures += 1;
            }
        }
    } else {
        std.debug.print(
            "wasm-audit: memory has no maximum; exhaustion would end the tab " ++
                "instead of failing an allocation\n",
            .{},
        );
        failures += 1;
    }

    if (out.stack_pointer_init) |stack| {
        if (out.first_data_offset) |data| {
            if (stack > data) {
                std.debug.print(
                    "wasm-audit: the stack starts at {d}, above the first data " ++
                        "segment at {d}; an overflow would overwrite static data\n",
                    .{ stack, data },
                );
                failures += 1;
            }
        }
    }

    if (failures == 0) {
        std.debug.print(
            "wasm-audit: {s} — 0 imports, {d} exports, memory capped at {d} pages\n",
            .{ path, out.functions.items.len, out.memory_max_pages orelse 0 },
        );
        return 0;
    }
    std.debug.print("wasm-audit: {d} problem(s) in {s}\n", .{ failures, path });
    return 1;
}

fn listed(name: []const u8) bool {
    for (exports.exported_names) |expected| {
        if (std.mem.eql(u8, name, expected)) return true;
    }
    return false;
}

fn present(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

const testing = std.testing;

fn parseForTest(bytes: []const u8) !Findings {
    var findings: Findings = .{};
    try parse(testing.allocator, bytes, &findings);
    return findings;
}

test "a file that is not WebAssembly is refused" {
    try testing.expectError(error.NotWasm, parseForTest("not a module"));
    try testing.expectError(error.Truncated, parseForTest("\x00as"));
}

test "an unsupported binary version is refused" {
    try testing.expectError(
        error.UnsupportedVersion,
        parseForTest("\x00asm\x09\x00\x00\x00"),
    );
}

test "a section claiming more bytes than the file holds is refused" {
    // Header, then section id 1 with a length far past the end.
    try testing.expectError(
        error.Truncated,
        parseForTest("\x00asm\x01\x00\x00\x00\x01\xff\x01"),
    );
}

test "an unterminated LEB128 is refused rather than looped on" {
    var cursor: Cursor = .{ .bytes = "\xff\xff\xff\xff\xff\xff" };
    try testing.expectError(error.MalformedLeb, cursor.leb());
}

test "a duplicate non-custom section is refused" {
    // Two empty type sections.
    try testing.expectError(
        error.DuplicateSection,
        parseForTest("\x00asm\x01\x00\x00\x00\x01\x01\x00\x01\x01\x00"),
    );
}

test "an empty module parses and has no imports or exports" {
    var findings = try parseForTest("\x00asm\x01\x00\x00\x00");
    defer findings.imports.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), findings.imports.items.len);
    try testing.expectEqual(@as(usize, 0), findings.functions.items.len);
}
