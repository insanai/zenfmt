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
const lowering = @import("lowering.zig");
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
    /// The whole input in memory: bytes inputs, and file inputs slurped
    /// for `.bytes`-mode readers.
    bytes: []const u8,
    /// A file handle for `.seekable` readers (ZDS 0013, Core Contract
    /// Repairs): the reader windows what it needs instead of the engine
    /// holding the whole input.
    file: InputFile,

    pub const InputFile = struct {
        io: std.Io,
        handle: std.Io.File,
        size: u64,
    };
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
    /// Cache for `inputBytes`: a file-backed input is slurped at most
    /// once into the arena.
    slurped: ?[]const u8 = null,

    pub const OwnPluginData = struct {
        version: i64,
        /// Canonical JSON bytes, arena-owned.
        data: []const u8,
    };

    /// The whole input as bytes. Bytes inputs return their slice; a
    /// file-backed input is read once into the arena and cached. Readers
    /// that genuinely need random access should window through
    /// `ctx.input.file` instead; this is the shim for parsers that work
    /// from one slice (CFB, PDF).
    pub fn inputBytes(ctx: *ReadContext) ReadError![]const u8 {
        switch (ctx.input) {
            .bytes => |bytes| return bytes,
            .file => |file| {
                if (ctx.slurped) |bytes| return bytes;
                assert(file.size <= ctx.limits.max_input_bytes);
                const size = std.math.cast(usize, file.size) orelse return error.LimitExceeded;
                const bytes = try ctx.gpa.alloc(u8, size);
                const read = file.handle.readPositionalAll(file.io, bytes, 0) catch
                    return error.Malformed;
                if (read != size) return error.Malformed;
                ctx.slurped = bytes;
                return bytes;
            },
        }
    }
};

pub const WriteContext = struct {
    /// The lowering plan accumulator (ZDS 0013), present when the writer
    /// declares capabilities; emission sites record rule hits through it.
    plan: ?*lowering.Plan = null,
    gpa: std.mem.Allocator,
    doc: *const ast.Document,
    out: *std.Io.Writer,
    reports: *report.Reports,
    limits: limits_mod.Limits,
    /// The input's verified adjacent manifest, when one was loaded, so a
    /// writer can recover preservation data its own reader saved (ZDS
    /// 0013, manifest schema v2).
    manifest_in: ?*const manifest.Loaded = null,

    /// The namespace owned by `id` in the input's manifest, when present.
    pub fn preservation(ctx: *const WriteContext, id: []const u8) ?manifest.PluginEntry {
        const loaded = ctx.manifest_in orelse return null;
        for (loaded.plugins) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }
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
    /// The writer's declared capabilities (ZDS 0013). When present, the
    /// engine builds a lowering plan, prices its loss, and gates graded
    /// strict before anything is committed.
    capabilities: ?*const lowering.Capabilities = null,
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
    capabilities: ?*const lowering.Capabilities = null,
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
        .capabilities = options.capabilities,
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
