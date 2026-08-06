//! `zenfmt_core`: the format-blind conversion engine (ZDS 0002).
//!
//! Core owns the AST, the builder and emitter, the validator, reports,
//! limits, metadata, the artifact manifest, the plugin contracts, and the
//! `Bundle` constructor. It contains no identifier from any file format
//! specification; formats are separate libraries composed into bundles, and
//! the engine learns them only as descriptor tables.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

pub const ast = @import("ast.zig");
pub const payload = @import("payload.zig");
pub const metadata = @import("metadata.zig");
pub const builder = @import("builder.zig");
pub const limits = @import("limits.zig");
pub const report = @import("report.zig");
pub const json = @import("json.zig");
pub const manifest = @import("manifest.zig");
pub const plugin = @import("plugin.zig");
pub const pipeline = @import("pipeline.zig");
pub const filters = @import("filters.zig");

pub const Limits = limits.Limits;
pub const Document = ast.Document;
pub const BlockTag = ast.BlockTag;
pub const InlineTag = ast.InlineTag;
pub const BlockIndex = ast.BlockIndex;
pub const InlineIndex = ast.InlineIndex;
pub const Attrs = ast.Attrs;
pub const BlockView = payload.BlockView;
pub const InlineView = payload.InlineView;
pub const Emitter = builder.Emitter;
pub const AttrOptions = builder.AttrOptions;
pub const Report = report.Report;
pub const Reports = report.Reports;
pub const Reader = plugin.Reader;
pub const Writer = plugin.Writer;
pub const ReadContext = plugin.ReadContext;
pub const WriteContext = plugin.WriteContext;
pub const ReadError = plugin.ReadError;
pub const WriteError = plugin.WriteError;
pub const Pipeline = pipeline.Pipeline;
pub const Filter = pipeline.Filter;
pub const FilterContext = pipeline.FilterContext;
pub const FilterAction = pipeline.FilterAction;
pub const FilterError = pipeline.FilterError;

// ------------------------------------------------------------- options

pub const InputSpec = union(enum) {
    path: []const u8,
    bytes: Bytes,

    pub const Bytes = struct {
        /// Display name for reports and the manifest.
        name: []const u8,
        data: []const u8,
    };
};

pub const OutputSpec = union(enum) {
    /// Written atomically, with `<path>.zenfmt.json` beside it.
    path: []const u8,
    /// Streamed; the manifest is only returned in `Conversion`.
    writer: *Io.Writer,
};

pub const ConvertOptions = struct {
    input: InputSpec,
    output: OutputSpec,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    limits: Limits = .{},
    /// Replace existing artifact and manifest paths.
    overwrite: bool = false,
    /// Treat warnings as failure, before any output is committed.
    strict: bool = false,
    /// The filter pipeline to run between reading and writing; stages run
    /// in declaration order and the tree is validated after each.
    pipeline: ?*const Pipeline = null,
};

pub const Status = enum(u8) { success, failed };

const oom_reports = [_]Report{report.out_of_memory};

/// The result of a conversion. Never an error union: expected failures are
/// `.status == .failed` with structured reports, so the explanation is not
/// discarded at the exact moment an embedding application needs it.
pub const Conversion = struct {
    status: Status,
    reports: []const Report,
    /// The canonical manifest JSON. On path output it was also written
    /// beside the artifact; on stream output this is the only copy.
    manifest_json: ?[]const u8,
    exit_class: report.ExitClass,
    arena_state: std.heap.ArenaAllocator.State,

    pub fn deinit(c: *Conversion, gpa: std.mem.Allocator) void {
        var arena = c.arena_state.promote(gpa);
        arena.deinit();
        c.* = undefined;
    }

    pub fn renderReports(
        c: *const Conversion,
        out: *Io.Writer,
        options: report.RenderOptions,
    ) Io.Writer.Error!void {
        try report.renderText(c.reports, out, options);
    }
};

const RunError = error{ OutOfMemory, Failed };

// -------------------------------------------------------------- bundle

/// Turns comptime tuples of plugin descriptors into a conversion engine.
/// The umbrella library assembles the default bundle; applications can
/// assemble smaller ones. Descriptor mistakes are compile errors here, not
/// runtime surprises.
pub fn Bundle(comptime spec: anytype) type {
    const reader_array = comptime descriptorArray(plugin.ReaderDescriptor, spec.readers);
    const writer_array = comptime descriptorArray(plugin.WriterDescriptor, spec.writers);
    comptime validateBundle(&reader_array, &writer_array);

    return struct {
        pub const readers: []const plugin.ReaderDescriptor = &reader_array;
        pub const writers: []const plugin.WriterDescriptor = &writer_array;
        pub const default_output_format = writer_array[0].format;

        pub fn convert(gpa: std.mem.Allocator, io: Io, options: ConvertOptions) Conversion {
            var arena_instance = std.heap.ArenaAllocator.init(gpa);
            const arena = arena_instance.allocator();
            var reports = report.Reports.init(arena, options.limits);

            const manifest_json = run(arena, io, options, &reports) catch |err| switch (err) {
                error.OutOfMemory => {
                    arena_instance.deinit();
                    const empty = std.heap.ArenaAllocator.init(gpa);
                    return .{
                        .status = .failed,
                        .reports = &oom_reports,
                        .manifest_json = null,
                        .exit_class = .conversion,
                        .arena_state = empty.state,
                    };
                },
                error.Failed => {
                    assert(reports.hasErrors());
                    const final = reports.finalize() catch &oom_reports;
                    return .{
                        .status = .failed,
                        .reports = final,
                        .manifest_json = null,
                        .exit_class = reports.worstExitClass(),
                        .arena_state = arena_instance.state,
                    };
                },
            };

            const final = reports.finalize() catch &oom_reports;
            return .{
                .status = .success,
                .reports = final,
                .manifest_json = manifest_json,
                .exit_class = .conversion,
                .arena_state = arena_instance.state,
            };
        }

        fn run(
            arena: std.mem.Allocator,
            io: Io,
            options: ConvertOptions,
            reports: *Reports,
        ) RunError![]const u8 {
            const input = try resolveInput(arena, io, options, reports);
            const from = try resolveFrom(arena, options, input, reports, readers);
            const to = options.to orelse default_output_format;

            inline for (reader_array) |reader_descriptor| {
                if (std.mem.eql(u8, reader_descriptor.format, from)) {
                    inline for (writer_array) |writer_descriptor| {
                        if (std.mem.eql(u8, writer_descriptor.format, to)) {
                            return convertStatic(
                                reader_descriptor,
                                writer_descriptor,
                                arena,
                                io,
                                options,
                                input,
                                reports,
                            );
                        }
                    }
                    try reportUnknownFormat(arena, reports, to, .output, writerFormats(), input);
                    return error.Failed;
                }
            }
            try reportUnknownFormat(arena, reports, from, .input, readerFormats(), input);
            return error.Failed;
        }

        fn convertStatic(
            comptime reader_descriptor: plugin.ReaderDescriptor,
            comptime writer_descriptor: plugin.WriterDescriptor,
            arena: std.mem.Allocator,
            io: Io,
            options: ConvertOptions,
            input: ResolvedInput,
            reports: *Reports,
        ) RunError![]const u8 {
            const loaded = loadAdjacentManifest(arena, io, options, input, reports);

            // Read.
            const store = try arena.create(ast.Store);
            store.* = .{};
            var tree_builder = builder.Builder.init(arena, store, options.limits);
            var read_context: plugin.ReadContext = .{
                .gpa = arena,
                .out = .{ .builder = &tree_builder },
                .input = .{ .bytes = input.bytes },
                .input_name = input.name,
                .reports = reports,
                .manifest_in = if (loaded) |*value| value else null,
                .limits = options.limits,
            };
            reader_descriptor.read(&read_context) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed, error.DepthLimitExceeded, error.LimitExceeded => {
                    try ensureFailureReported(arena, reports, err, input);
                    return error.Failed;
                },
            };
            const own_plugin_data = read_context.own_plugin_data;
            var doc = tree_builder.finish() catch return error.OutOfMemory;
            doc.plugin_data = try carryPluginData(arena, store, loaded);

            ast.validate(&doc, options.limits) catch {
                try reports.add(invalidTreeReport(reader_descriptor.id));
                return error.Failed;
            };

            // Transform. Each stage validates its output; a filter that
            // produces an impossible tree fails at its own stage.
            if (options.pipeline) |stages| {
                doc = stages.run(arena, doc, reports, options.limits) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidDocument => {
                        try reports.add(invalidTreeReport("core.pipeline"));
                        return error.Failed;
                    },
                    error.DepthLimitExceeded => {
                        try reports.add(invalidTreeReport("core.pipeline"));
                        return error.Failed;
                    },
                };
            }

            // Write, digest, and commit.
            return emit(
                writer_descriptor,
                reader_descriptor,
                arena,
                io,
                options,
                input,
                doc,
                loaded,
                own_plugin_data,
                reports,
            );
        }

        fn emit(
            comptime writer_descriptor: plugin.WriterDescriptor,
            comptime reader_descriptor: plugin.ReaderDescriptor,
            arena: std.mem.Allocator,
            io: Io,
            options: ConvertOptions,
            input: ResolvedInput,
            doc: Document,
            loaded: ?manifest.Loaded,
            own_plugin_data: ?plugin.ReadContext.OwnPluginData,
            reports: *Reports,
        ) RunError![]const u8 {
            const Blake3 = std.crypto.hash.Blake3;

            var atomic: ?Io.File.Atomic = null;
            defer if (atomic) |*af| af.deinit(io);
            var file_buffer: [8 * 1024]u8 = undefined;
            var file_writer: Io.File.Writer = undefined;
            var hash_buffer: [4 * 1024]u8 = undefined;

            const artifact_name = switch (options.output) {
                .path => |path| std.fs.path.basename(path),
                .writer => "stdout",
            };
            const underlying: *Io.Writer = switch (options.output) {
                .writer => |stream| stream,
                .path => |path| blk: {
                    atomic = Io.Dir.cwd().createFileAtomic(io, path, .{
                        .replace = options.overwrite,
                    }) catch |err| {
                        try reports.add(try pathFailure(arena, "create the output file", path, err));
                        return error.Failed;
                    };
                    file_writer = atomic.?.file.writerStreaming(io, &file_buffer);
                    break :blk &file_writer.interface;
                },
            };

            var hashed = Io.Writer.Hashed(Blake3).initHasher(underlying, Blake3.init(.{}), &hash_buffer);
            var write_context: plugin.WriteContext = .{
                .gpa = arena,
                .doc = &doc,
                .out = &hashed.writer,
                .reports = reports,
                .limits = options.limits,
            };
            writer_descriptor.write(&write_context) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.WriteFailed => {
                    try reports.add(try pathFailure(arena, "write the output", artifact_name, err));
                    return error.Failed;
                },
            };
            flushOutput(&hashed.writer, &file_writer, options) catch |err| {
                try reports.add(try pathFailure(arena, "flush the output", artifact_name, err));
                return error.Failed;
            };
            const artifact_digest = manifest.digestHexFromHasher(&hashed.hasher);

            // Strict mode fails before anything is committed.
            if (options.strict and reports.worst() != null and reports.worst() != .note) {
                try reports.add(strictReport(input.name));
                return error.Failed;
            }

            // The manifest: metadata, reports so far, and carried data.
            var meta_stream = json.WriteStream.init(arena);
            try metadata.writeMetaMap(arena, &doc, doc.meta, &meta_stream);
            const meta_json = try meta_stream.toOwnedSlice();
            const manifest_json = try manifest.encode(arena, .{
                .source = .{
                    .name = input.name,
                    .format = reader_descriptor.format,
                    .digest_hex = manifest.digestHex(input.bytes),
                    .plugin_id = reader_descriptor.id,
                },
                .artifact = .{
                    .name = artifact_name,
                    .format = writer_descriptor.format,
                    .digest_hex = artifact_digest,
                    .plugin_id = writer_descriptor.id,
                },
                .document_metadata = meta_json,
                .reports = try reports.finalize(),
                .plugins = try mergePluginData(
                    arena,
                    if (loaded) |value| value.plugins else &.{},
                    reader_descriptor.id,
                    own_plugin_data,
                ),
            });

            // Commit: artifact first, then its manifest.
            if (options.output == .path) {
                const path = options.output.path;
                const manifest_path = try std.fmt.allocPrint(arena, "{s}.zenfmt.json", .{path});
                var manifest_atomic = Io.Dir.cwd().createFileAtomic(io, manifest_path, .{
                    .replace = options.overwrite,
                }) catch |err| {
                    try reports.add(try pathFailure(arena, "create the manifest file", manifest_path, err));
                    return error.Failed;
                };
                defer manifest_atomic.deinit(io);
                manifest_atomic.file.writeStreamingAll(io, manifest_json) catch |err| {
                    try reports.add(try pathFailure(arena, "write the manifest", manifest_path, err));
                    return error.Failed;
                };

                materialize(&atomic.?, io, options.overwrite) catch |err| {
                    try reports.add(try commitFailure(arena, path, input, options, err));
                    return error.Failed;
                };
                materialize(&manifest_atomic, io, options.overwrite) catch |err| {
                    try reports.add(try commitFailure(arena, manifest_path, input, options, err));
                    return error.Failed;
                };
            }
            return manifest_json;
        }

        fn readerFormats() []const []const u8 {
            const static = comptime blk: {
                var names: [reader_array.len][]const u8 = undefined;
                for (&reader_array, 0..) |descriptor, i| names[i] = descriptor.format;
                const copy = names;
                break :blk copy;
            };
            return &static;
        }

        fn writerFormats() []const []const u8 {
            const static = comptime blk: {
                var names: [writer_array.len][]const u8 = undefined;
                for (&writer_array, 0..) |descriptor, i| names[i] = descriptor.format;
                const copy = names;
                break :blk copy;
            };
            return &static;
        }

        fn resolveFrom(
            arena: std.mem.Allocator,
            options: ConvertOptions,
            input: ResolvedInput,
            reports: *Reports,
            comptime descriptors: []const plugin.ReaderDescriptor,
        ) RunError![]const u8 {
            if (options.from) |from| return from;

            if (extensionOf(input.name)) |extension| {
                inline for (descriptors) |descriptor| {
                    for (descriptor.extensions) |known| {
                        if (std.ascii.eqlIgnoreCase(extension, known)) return descriptor.format;
                    }
                }
            }
            switch (sniff(input.bytes)) {
                .docx => return "docx",
                .xlsx => return "xlsx",
                .pptx => return "pptx",
                .odt => return "odt",
                .zip => return "docx",
                .rtf => return "rtf",
                .pdf => {
                    try reports.add(pdfReport(input.name));
                    return error.Failed;
                },
                .none => {},
            }
            try reportUndetectable(arena, reports, input, readerFormats());
            return error.Failed;
        }

        /// The primary extension of the selected writer, for CLI-derived
        /// output paths.
        pub fn primaryExtension(format: []const u8) ?[]const u8 {
            inline for (writer_array) |descriptor| {
                if (std.mem.eql(u8, descriptor.format, format)) {
                    return descriptor.extensions[0];
                }
            }
            return null;
        }
    };
}

fn descriptorArray(comptime T: type, comptime tuple: anytype) [tuple.len]T {
    var array: [tuple.len]T = undefined;
    for (0..tuple.len) |i| array[i] = tuple[i];
    return array;
}

fn validateBundle(
    comptime readers: []const plugin.ReaderDescriptor,
    comptime writers: []const plugin.WriterDescriptor,
) void {
    if (writers.len == 0) {
        @compileError("a bundle needs at least one writer: the first " ++
            "writer's format is the bundle's default output format.");
    }
    for (readers, 0..) |a, i| {
        for (readers[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.format, b.format)) {
                @compileError("two readers claim the format `" ++ a.format ++
                    "`. Each format has at most one reader per bundle; " ++
                    "remove one of the two descriptors from this bundle.");
            }
            for (a.extensions) |ae| for (b.extensions) |be| {
                if (std.mem.eql(u8, ae, be)) {
                    @compileError("readers `" ++ a.format ++ "` and `" ++
                        b.format ++ "` both claim the extension `." ++ ae ++
                        "`. Extension detection must be unambiguous; " ++
                        "remove the extension from one descriptor.");
                }
            };
        }
    }
    for (writers, 0..) |a, i| {
        for (writers[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.format, b.format)) {
                @compileError("two writers claim the format `" ++ a.format ++
                    "`. Each format has at most one writer per bundle.");
            }
        }
    }
    // A reader and writer for the same format share one manifest namespace.
    for (readers) |r| for (writers) |w| {
        if (std.mem.eql(u8, r.format, w.format) and !std.mem.eql(u8, r.id, w.id)) {
            @compileError("the reader and writer for format `" ++ r.format ++
                "` use different plugin ids (`" ++ r.id ++ "` and `" ++
                w.id ++ "`). Both halves of one format share one " ++
                "preservation-data namespace, so they must share one id.");
        }
    };
}

// --------------------------------------------------- engine mechanics

pub const ResolvedInput = struct {
    bytes: []const u8,
    /// Display name: a basename, never an absolute path.
    name: []const u8,
    path: ?[]const u8,
};

fn resolveInput(
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
            return .{ .bytes = input.data, .name = input.name, .path = null };
        },
        .path => |path| {
            const bytes = Io.Dir.cwd().readFileAlloc(
                io,
                path,
                arena,
                .limited(options.limits.max_input_bytes + 1),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.StreamTooLong => {
                    try reports.add(inputTooLarge(path, options.limits));
                    return error.Failed;
                },
                else => {
                    try reports.add(try pathFailure(arena, "read the input file", path, err));
                    return error.Failed;
                },
            };
            return .{
                .bytes = bytes,
                .name = std.fs.path.basename(path),
                .path = path,
            };
        },
    }
}

/// Reads and verifies `<input>.zenfmt.json`. Missing is normal; malformed,
/// oversized, or digest-mismatched is a warning and the data is ignored.
fn loadAdjacentManifest(
    arena: std.mem.Allocator,
    io: Io,
    options: ConvertOptions,
    input: ResolvedInput,
    reports: *Reports,
) ?manifest.Loaded {
    const path = input.path orelse return null;
    const manifest_path = std.fmt.allocPrint(arena, "{s}.zenfmt.json", .{path}) catch return null;
    const bytes = Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        arena,
        .limited(options.limits.max_manifest_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            reports.add(staleManifest(manifest_path, path)) catch {};
            return null;
        },
    };

    const loaded = manifest.load(arena, bytes, options.limits) catch {
        reports.add(staleManifest(manifest_path, path)) catch {};
        return null;
    };
    const actual = manifest.digestHex(input.bytes);
    if (!std.mem.eql(u8, &loaded.artifact_digest_hex, &actual)) {
        reports.add(staleManifest(manifest_path, path)) catch {};
        return null;
    }
    return loaded;
}

/// Carried namespaces plus the reading plugin's own data, its id replacing
/// any carried value for the same namespace, all sorted by id for the
/// canonical envelope.
fn mergePluginData(
    arena: std.mem.Allocator,
    carried: []const manifest.PluginEntry,
    reader_id: []const u8,
    own: ?plugin.ReadContext.OwnPluginData,
) error{OutOfMemory}![]const manifest.PluginEntry {
    var merged: std.ArrayList(manifest.PluginEntry) = .empty;
    for (carried) |entry| {
        if (own != null and std.mem.eql(u8, entry.id, reader_id)) continue;
        try merged.append(arena, entry);
    }
    if (own) |value| {
        try merged.append(arena, .{
            .id = reader_id,
            .version = value.version,
            .data = value.data,
        });
    }
    std.mem.sort(manifest.PluginEntry, merged.items, {}, pluginEntryLessThan);
    return merged.items;
}

fn pluginEntryLessThan(_: void, lhs: manifest.PluginEntry, rhs: manifest.PluginEntry) bool {
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

/// Appends carried namespaces to the store and returns the document's
/// plugin-data range.
fn carryPluginData(
    arena: std.mem.Allocator,
    store: *ast.Store,
    loaded: ?manifest.Loaded,
) error{OutOfMemory}!ast.PluginDataRange {
    const value = loaded orelse return .empty;
    const start: u32 = @intCast(store.plugin_namespaces.items.len);
    for (value.plugins) |entry| {
        const id_start: u32 = @intCast(store.text.items.len);
        try store.text.appendSlice(arena, entry.id);
        const json_start: u32 = @intCast(store.raw.items.len);
        try store.raw.appendSlice(arena, entry.data);
        try store.plugin_namespaces.append(arena, .{
            .id = .{ .start = id_start, .len = @intCast(entry.id.len) },
            .version = @intCast(@max(entry.version, 0)),
            .json = .{ .start = json_start, .len = @intCast(entry.data.len) },
        });
    }
    return .{ .start = start, .len = @intCast(value.plugins.len) };
}

fn flushOutput(
    hashed_writer: *Io.Writer,
    file_writer: *Io.File.Writer,
    options: ConvertOptions,
) error{WriteFailed}!void {
    try hashed_writer.flush();
    if (options.output == .path) try file_writer.interface.flush();
}

fn materialize(atomic: *Io.File.Atomic, io: Io, overwrite: bool) !void {
    if (overwrite) {
        try atomic.replace(io);
    } else {
        try atomic.link(io);
    }
}

const Sniffed = enum { none, zip, docx, xlsx, pptx, odt, rtf, pdf };

/// Content signatures. A ZIP container's specific format comes from its
/// characteristic part names, which appear verbatim in the archive's
/// central directory — no extraction needed to detect.
fn sniff(bytes: []const u8) Sniffed {
    if (std.mem.startsWith(u8, bytes, "PK\x03\x04")) {
        if (std.mem.indexOf(u8, bytes, "word/document.xml") != null) return .docx;
        if (std.mem.indexOf(u8, bytes, "xl/workbook.xml") != null) return .xlsx;
        if (std.mem.indexOf(u8, bytes, "ppt/presentation.xml") != null) return .pptx;
        if (std.mem.indexOf(u8, bytes, "application/vnd.oasis.opendocument.text") != null) {
            return .odt;
        }
        return .zip;
    }
    if (std.mem.startsWith(u8, bytes, "{\\rtf")) return .rtf;
    if (std.mem.startsWith(u8, bytes, "%PDF")) return .pdf;
    return .none;
}

fn extensionOf(name: []const u8) ?[]const u8 {
    const index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (index + 1 >= name.len) return null;
    return name[index + 1 ..];
}

/// Bounded Levenshtein distance for did-you-mean suggestions.
pub fn editDistance(a: []const u8, b: []const u8) usize {
    const cap = 32;
    if (a.len > cap or b.len > cap) return cap;
    var previous: [cap + 1]usize = undefined;
    var current: [cap + 1]usize = undefined;
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |a_byte, i| {
        current[0] = i + 1;
        for (b, 0..) |b_byte, j| {
            const substitution = previous[j] + @intFromBool(a_byte != b_byte);
            current[j + 1] = @min(@min(current[j] + 1, previous[j + 1] + 1), substitution);
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

pub fn closestFormat(name: []const u8, known: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (known) |candidate| {
        const distance = editDistance(name, candidate);
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    return best;
}

// The engine's own report constructors live in `engine_reports.zig`.
const engine_reports = @import("engine_reports.zig");
const FormatRole = engine_reports.FormatRole;
const reportUnknownFormat = engine_reports.reportUnknownFormat;
const reportUndetectable = engine_reports.reportUndetectable;
const pdfReport = engine_reports.pdfReport;
const inputTooLarge = engine_reports.inputTooLarge;
const staleManifest = engine_reports.staleManifest;
const invalidTreeReport = engine_reports.invalidTreeReport;
const strictReport = engine_reports.strictReport;
const pathFailure = engine_reports.pathFailure;
const commitFailure = engine_reports.commitFailure;
const ensureFailureReported = engine_reports.ensureFailureReported;

// ---------------------------------------------------------------- tests

test {
    _ = ast;
    _ = payload;
    _ = metadata;
    _ = builder;
    _ = limits;
    _ = report;
    _ = json;
    _ = manifest;
    _ = plugin;
    _ = pipeline;
    _ = @import("transform.zig");
    _ = filters;
}

test "edit distance suggests the nearest format" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("docs", "docx"));
    const known = [_][]const u8{ "docx", "markdown", "text" };
    try std.testing.expectEqualStrings("docx", closestFormat("docs", &known).?);
    try std.testing.expectEqual(@as(?[]const u8, null), closestFormat("zzzzz", &known));
}

test "sniffing recognizes the container signatures" {
    try std.testing.expectEqual(Sniffed.zip, sniff("PK\x03\x04rest"));
    try std.testing.expectEqual(Sniffed.rtf, sniff("{\\rtf1..."));
    try std.testing.expectEqual(Sniffed.pdf, sniff("%PDF-1.7"));
    try std.testing.expectEqual(Sniffed.none, sniff("hello"));
}
