//! Input resolution and content detection (ZDS 0013, Core Contract
//! Repairs): byte inputs are sliced, path inputs open a file handle whose
//! digest is streamed once, and detection weighs extension against content
//! signatures. The engine slurps a file only when a `.bytes` reader or the
//! sniffer genuinely needs the whole input.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const root = @import("root.zig");
const plugin = @import("plugin.zig");
const manifest = @import("manifest.zig");

const Reports = @import("report.zig").Reports;
const RunError = error{ OutOfMemory, Failed };
const ConvertOptions = root.ConvertOptions;
const inputTooLarge = @import("engine_reports.zig").inputTooLarge;
const pathFailure = @import("engine_reports.zig").pathFailure;

pub const ResolvedInput = struct {
    /// Bytes for byte inputs; an open file handle for path inputs, so a
    /// seekable reader windows the file instead of the engine slurping it
    /// (ZDS 0013, Core Contract Repairs).
    source: plugin.Input,
    /// Display name: a basename, never an absolute path.
    name: []const u8,
    path: ?[]const u8,
    /// The source digest, computed once: from the slice, or by streaming
    /// the file.
    digest_hex: manifest.DigestHex,
    /// Slurp cache for detection and `.bytes`-mode readers.
    slurped: ?[]const u8 = null,

    pub fn deinit(input: *ResolvedInput, io: Io) void {
        switch (input.source) {
            .bytes => {},
            .file => |file| file.handle.close(io),
        }
        input.* = undefined;
    }
};

pub fn resolveInput(
    arena: std.mem.Allocator,
    io: Io,
    options: ConvertOptions,
    reports: *Reports,
) RunError!ResolvedInput {
    switch (options.input) {
        .bytes => |input| {
            if (input.data.len > options.limits.max_input_bytes) {
                try reports.add(inputTooLarge(input.name, options.limits));
                return error.Failed;
            }
            return .{
                .source = .{ .bytes = input.data },
                .name = input.name,
                .path = null,
                .digest_hex = manifest.digestHex(input.data),
            };
        },
        .path => |path| {
            const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
                try reports.add(try pathFailure(arena, "open the input file", path, err));
                return error.Failed;
            };
            errdefer file.close(io);
            const size = file.length(io) catch |err| {
                try reports.add(try pathFailure(arena, "stat the input file", path, err));
                return error.Failed;
            };
            if (size > options.limits.max_input_bytes) {
                try reports.add(inputTooLarge(path, options.limits));
                return error.Failed;
            }
            const digest_hex = streamDigest(io, file, size) catch |err| {
                try reports.add(try pathFailure(arena, "read the input file", path, err));
                return error.Failed;
            };
            return .{
                .source = .{ .file = .{ .io = io, .handle = file, .size = size } },
                .name = std.fs.path.basename(path),
                .path = path,
                .digest_hex = digest_hex,
            };
        },
    }
}

/// BLAKE3 of a file's contents by bounded positional reads; the file never
/// lives in memory whole.
fn streamDigest(io: Io, file: Io.File, size: u64) !manifest.DigestHex {
    var hasher = std.crypto.hash.Blake3.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const want: usize = @intCast(@min(size - offset, buffer.len));
        const read = try file.readPositionalAll(io, buffer[0..want], offset);
        if (read == 0) break;
        hasher.update(buffer[0..read]);
        offset += read;
    }
    return manifest.digestHexFromHasher(&hasher);
}

/// The whole input as bytes, slurped at most once, for detection and for
/// readers declared `.bytes`.
pub fn inputAllBytes(
    arena: std.mem.Allocator,
    input: *ResolvedInput,
    reports: *Reports,
) RunError![]const u8 {
    switch (input.source) {
        .bytes => |bytes| return bytes,
        .file => |file| {
            if (input.slurped) |bytes| return bytes;
            const size = std.math.cast(usize, file.size) orelse return error.OutOfMemory;
            const bytes = try arena.alloc(u8, size);
            const read = file.handle.readPositionalAll(file.io, bytes, 0) catch |err| {
                try reports.add(try pathFailure(arena, "read the input file", input.name, err));
                return error.Failed;
            };
            if (read != size) {
                try reports.add(try pathFailure(arena, "read the input file", input.name, error.Unexpected));
                return error.Failed;
            }
            input.slurped = bytes;
            return bytes;
        },
    }
}

pub const Sniffed = enum {
    none,
    zip,
    docx,
    xlsx,
    xlsb,
    pptx,
    odt,
    ods,
    odp,
    epub,
    rtf,
    pdf,
    doc,
    xls,
    ppt,
};

/// Content signatures. A ZIP container's specific format comes from its
/// characteristic part names, which appear verbatim in the archive's
/// central directory — no extraction needed to detect. A CFB container's
/// comes from its directory entry names, stored as UTF-16LE.
pub fn sniff(bytes: []const u8) Sniffed {
    if (std.mem.startsWith(u8, bytes, "PK\x03\x04")) {
        if (std.mem.indexOf(u8, bytes, "word/document.xml") != null) return .docx;
        if (std.mem.indexOf(u8, bytes, "xl/workbook.bin") != null) return .xlsb;
        if (std.mem.indexOf(u8, bytes, "xl/workbook.xml") != null) return .xlsx;
        if (std.mem.indexOf(u8, bytes, "ppt/presentation.xml") != null) return .pptx;
        if (std.mem.indexOf(u8, bytes, "application/epub+zip") != null) return .epub;
        if (std.mem.indexOf(u8, bytes, "application/vnd.oasis.opendocument.text") != null) {
            return .odt;
        }
        if (std.mem.indexOf(u8, bytes, "application/vnd.oasis.opendocument.spreadsheet") != null) {
            return .ods;
        }
        if (std.mem.indexOf(u8, bytes, "application/vnd.oasis.opendocument.presentation") != null) {
            return .odp;
        }
        return .zip;
    }
    if (std.mem.startsWith(u8, bytes, "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1")) {
        if (std.mem.indexOf(u8, bytes, comptime utf16le("WordDocument")) != null) return .doc;
        if (std.mem.indexOf(u8, bytes, comptime utf16le("PowerPoint Document")) != null) {
            return .ppt;
        }
        if (std.mem.indexOf(u8, bytes, comptime utf16le("Workbook")) != null) return .xls;
        if (std.mem.indexOf(u8, bytes, comptime utf16le("Book")) != null) return .xls;
        return .doc;
    }
    if (std.mem.startsWith(u8, bytes, "{\\rtf")) return .rtf;
    if (std.mem.startsWith(u8, bytes, "%PDF")) return .pdf;
    return .none;
}

/// The UTF-16LE spelling of an ASCII stream name, as it appears in a CFB
/// directory sector.
fn utf16le(comptime ascii: []const u8) []const u8 {
    var expanded: [ascii.len * 2]u8 = undefined;
    for (ascii, 0..) |byte, i| {
        expanded[i * 2] = byte;
        expanded[i * 2 + 1] = 0;
    }
    const frozen = expanded;
    return &frozen;
}

pub fn extensionOf(name: []const u8) ?[]const u8 {
    const index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (index + 1 >= name.len) return null;
    return name[index + 1 ..];
}

test "sniffing recognizes the container signatures" {
    try std.testing.expectEqual(Sniffed.zip, sniff("PK\x03\x04rest"));
    try std.testing.expectEqual(Sniffed.rtf, sniff("{\\rtf1..."));
    try std.testing.expectEqual(Sniffed.pdf, sniff("%PDF-1.7"));
    try std.testing.expectEqual(Sniffed.none, sniff("hello"));
    try std.testing.expectEqual(Sniffed.xlsb, sniff("PK\x03\x04..xl/workbook.bin.."));
    try std.testing.expectEqual(Sniffed.epub, sniff("PK\x03\x04..application/epub+zip.."));
    try std.testing.expectEqual(
        Sniffed.ods,
        sniff("PK\x03\x04..application/vnd.oasis.opendocument.spreadsheet.."),
    );
    try std.testing.expectEqual(
        Sniffed.odp,
        sniff("PK\x03\x04..application/vnd.oasis.opendocument.presentation.."),
    );

    const cfb_magic = "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1";
    try std.testing.expectEqual(
        Sniffed.doc,
        sniff(cfb_magic ++ "..W\x00o\x00r\x00d\x00D\x00o\x00c\x00u\x00m\x00e\x00n\x00t\x00.."),
    );
    try std.testing.expectEqual(
        Sniffed.xls,
        sniff(cfb_magic ++ "..W\x00o\x00r\x00k\x00b\x00o\x00o\x00k\x00.."),
    );
    try std.testing.expectEqual(Sniffed.doc, sniff(cfb_magic ++ "..opaque.."));
}
