//! The plugin contract (ZDS 0002, The Plugin Contract).
//!
//! A plugin exports one descriptor produced by a comptime constructor. The
//! constructor validates ids, formats, extensions, and callbacks where the
//! plugin is defined, so a registry mistake is a compile error pointing at
//! the plugin rather than at router internals. Descriptor `@compileError`
//! messages follow the four-question diagnostic structure in miniature:
//! what is wrong, where, and what to change.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const builder = @import("builder.zig");
const report = @import("report.zig");
const manifest = @import("manifest.zig");
const limits_mod = @import("limits.zig");

pub const InputMode = enum(u8) {
    /// The whole input as bytes; works from a pipe.
    bytes,
    /// The reader needs random access — a ZIP central directory. Piped
    /// input spills to a temporary file.
    seekable,
};

pub const Input = union(enum) {
    bytes: []const u8,
};

pub const ReadError = error{
    OutOfMemory,
    DepthLimitExceeded,
    /// The input is not a well-formed instance of the declared format. The
    /// reader reports the specifics before returning this.
    Malformed,
    /// A named resource limit was hit; the report carries the override.
    LimitExceeded,
};

pub const WriteError = error{
    OutOfMemory,
    WriteFailed,
};

pub const ReadContext = struct {
    /// The conversion arena. Nothing allocated from it is individually
    /// freed, and nothing outlives the conversion.
    gpa: std.mem.Allocator,
    out: builder.Emitter,
    input: Input,
    /// Display name of the input, for report contexts.
    input_name: []const u8,
    reports: *report.Reports,
    /// Present only after the engine verified the adjacent manifest digest.
    manifest_in: ?*const manifest.Loaded,
    limits: limits_mod.Limits,
    /// Preservation data this reader wants carried in the manifest under
    /// its own plugin id: canonical JSON plus its schema version. The
    /// engine writes it; the reader never touches another namespace.
    own_plugin_data: ?OwnPluginData = null,

    pub const OwnPluginData = struct {
        version: i64,
        /// Canonical JSON bytes, arena-owned.
        data: []const u8,
    };
};

pub const WriteContext = struct {
    gpa: std.mem.Allocator,
    doc: *const ast.Document,
    out: *std.Io.Writer,
    reports: *report.Reports,
    limits: limits_mod.Limits,
};

pub const ReaderDescriptor = struct {
    id: []const u8,
    format: []const u8,
    extensions: []const []const u8,
    input: InputMode,
    /// Plugin-data schema version; 0 when the plugin carries none.
    data_version: u32,
    read: *const fn (ctx: *ReadContext) ReadError!void,
};

pub const WriterDescriptor = struct {
    id: []const u8,
    format: []const u8,
    extensions: []const []const u8,
    data_version: u32,
    write: *const fn (ctx: *WriteContext) WriteError!void,
};

pub const ReaderOptions = struct {
    /// Reverse-DNS, shared by the reader and writer of one format library.
    id: []const u8,
    /// Lowercase format name the CLI resolves: "docx".
    format: []const u8,
    /// Lowercase file extensions, primary first, without dots.
    extensions: []const []const u8,
    input: InputMode = .bytes,
    data_version: u32 = 0,
    read: *const fn (ctx: *ReadContext) ReadError!void,
};

pub const WriterOptions = struct {
    id: []const u8,
    format: []const u8,
    extensions: []const []const u8,
    data_version: u32 = 0,
    write: *const fn (ctx: *WriteContext) WriteError!void,
};

pub fn Reader(comptime options: ReaderOptions) ReaderDescriptor {
    comptime validateCommon(options.id, options.format, options.extensions);
    return .{
        .id = options.id,
        .format = options.format,
        .extensions = options.extensions,
        .input = options.input,
        .data_version = options.data_version,
        .read = options.read,
    };
}

pub fn Writer(comptime options: WriterOptions) WriterDescriptor {
    comptime validateCommon(options.id, options.format, options.extensions);
    return .{
        .id = options.id,
        .format = options.format,
        .extensions = options.extensions,
        .data_version = options.data_version,
        .write = options.write,
    };
}

fn validateCommon(
    comptime id: []const u8,
    comptime format: []const u8,
    comptime extensions: []const []const u8,
) void {
    if (!validPluginId(id)) {
        @compileError("plugin id `" ++ id ++ "` is not valid. A plugin id " ++
            "is reverse-DNS ASCII — lowercase letters, digits, hyphens, " ++
            "and at least one dot, as in `ai.insan.zenfmt.docx`. Change " ++
            "the `.id` field of this descriptor.");
    }
    if (!validFormatName(format)) {
        @compileError("format name `" ++ format ++ "` is not valid. A " ++
            "format name is lowercase ASCII letters, digits, and hyphens, " ++
            "as in `markdown`. Change the `.format` field of this " ++
            "descriptor.");
    }
    if (extensions.len == 0) {
        @compileError("format `" ++ format ++ "` declares no extensions. " ++
            "List at least one lowercase extension without the dot, " ++
            "primary first, in the `.extensions` field; it drives format " ++
            "detection and derived output paths.");
    }
    for (extensions) |extension| {
        if (!validFormatName(extension)) {
            @compileError("extension `" ++ extension ++ "` of format `" ++
                format ++ "` is not valid. Extensions are lowercase ASCII " ++
                "without the leading dot, as in `docx`.");
        }
    }
}

pub fn validPluginId(id: []const u8) bool {
    if (id.len == 0 or id[0] == '.' or id[id.len - 1] == '.') return false;
    var has_dot = false;
    for (id) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-' => {},
        '.' => has_dot = true,
        else => return false,
    };
    return has_dot;
}

pub fn validFormatName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "id and format validation" {
    try testing.expect(validPluginId("ai.insan.zenfmt.docx"));
    try testing.expect(!validPluginId("zenfmt"));
    try testing.expect(!validPluginId("Ai.Insan"));
    try testing.expect(!validPluginId(".leading"));
    try testing.expect(!validPluginId("trailing."));
    try testing.expect(validFormatName("markdown"));
    try testing.expect(validFormatName("commonmark-x"));
    try testing.expect(!validFormatName("Markdown"));
    try testing.expect(!validFormatName(""));
}

test "a descriptor constructs at comptime" {
    const Hooks = struct {
        fn read(ctx: *ReadContext) ReadError!void {
            _ = ctx;
        }
    };
    const descriptor = comptime Reader(.{
        .id = "ai.insan.zenfmt.example",
        .format = "example",
        .extensions = &.{"ex"},
        .read = Hooks.read,
    });
    try testing.expectEqualStrings("example", descriptor.format);
    try testing.expectEqual(InputMode.bytes, descriptor.input);
}
