//! The plugin contract (ZDS 0002, The Plugin Contract).
//!
//! A plugin exports one descriptor produced by a comptime constructor. The
//! constructor validates ids, formats, extensions, and callbacks where the
//! plugin is defined, so a registry mistake is a compile error pointing at
//! the plugin rather than at router internals. Descriptor `@compileError`
//! messages identify the declaration, explain the violated contract, and
//! give the exact type or field change needed; headings alone are not an
//! actionable diagnostic.

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
    /// The selected reader's entry from a digest-verified adjacent
    /// manifest. The engine performs namespace selection, so the plugin
    /// cannot inspect another plugin family's preservation data.
    preservation_in: ?manifest.PluginEntry = null,
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

    pub fn preservation(ctx: *const ReadContext) ?manifest.PluginEntry {
        return ctx.preservation_in;
    }

    pub fn preservationAs(
        ctx: *const ReadContext,
        comptime T: type,
        comptime decode: anytype,
    ) !?T {
        const entry = ctx.preservation() orelse return null;
        return try decode(ctx.gpa, entry.version, entry.data);
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
    /// This writer family's entry from the input's digest-verified adjacent
    /// manifest. Other namespaces are deliberately absent from the context.
    preservation_in: ?manifest.PluginEntry = null,

    /// This writer family's verified namespace from the input manifest.
    pub fn preservation(ctx: *const WriteContext) ?manifest.PluginEntry {
        return ctx.preservation_in;
    }

    /// Decodes this writer's namespace through its typed, plugin-owned
    /// codec. `decode` receives `(arena, schema_version, canonical_json)`.
    pub fn preservationAs(
        ctx: *const WriteContext,
        comptime T: type,
        comptime decode: anytype,
    ) !?T {
        const entry = ctx.preservation() orelse return null;
        return try decode(ctx.gpa, entry.version, entry.data);
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

/// What a writer's artifact bytes are: UTF-8 text or arbitrary binary.
/// Capability metadata reports it so an embedding can decode text output
/// without guessing an encoding (ZDS 0014).
pub const Emission = enum { utf8_text, binary };

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
    /// Whether the artifact is UTF-8 text or arbitrary bytes.
    emits: Emission = .utf8_text,
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
    emits: Emission = .utf8_text,
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
        .emits = options.emits,
    };
}

fn validateCommon(
    comptime id: []const u8,
    comptime format: []const u8,
    comptime extensions: []const []const u8,
) void {
    if (!validPluginId(id)) {
        @compileError(
            "INVALID PLUGIN ID\n\n" ++
                "What happened: `" ++ id ++ "` is not reverse-DNS ASCII.\n" ++
                "Where: This descriptor's `.id` field.\n" ++
                "What zenfmt did: Compilation stopped before registering " ++
                "an unstable namespace.\n" ++
                "What you can do: Use lowercase letters, digits, hyphens, " ++
                "and at least one dot, such as `ai.insan.zenfmt.docx`.\n",
        );
    }
    if (!validFormatName(format)) {
        @compileError(
            "INVALID FORMAT NAME\n\n" ++
                "What happened: `" ++ format ++ "` is not a lowercase format name.\n" ++
                "Where: This descriptor's `.format` field.\n" ++
                "What zenfmt did: Compilation stopped before CLI routing became ambiguous.\n" ++
                "What you can do: Use lowercase ASCII letters, digits, " ++
                "and hyphens, such as `markdown`.\n",
        );
    }
    if (extensions.len == 0) {
        @compileError(
            "FORMAT HAS NO EXTENSION\n\n" ++
                "What happened: `" ++ format ++ "` declares no file extension.\n" ++
                "Where: This descriptor's `.extensions` field.\n" ++
                "What zenfmt did: Compilation stopped because detection " ++
                "and output naming need a primary extension.\n" ++
                "What you can do: List at least one lowercase extension " ++
                "without its dot, primary first.\n",
        );
    }
    for (extensions) |extension| {
        if (!validFormatName(extension)) {
            @compileError(
                "INVALID FORMAT EXTENSION\n\n" ++
                    "What happened: `" ++ extension ++ "` is not a lowercase extension.\n" ++
                    "Where: The `.extensions` list for `" ++ format ++ "`.\n" ++
                    "What zenfmt did: Compilation stopped before file " ++
                    "detection used an invalid suffix.\n" ++
                    "What you can do: Use lowercase ASCII without a leading dot, such as `docx`.\n",
            );
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
