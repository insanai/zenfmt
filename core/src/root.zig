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
pub const schema = @import("schema.zig");
pub const facets = @import("facets.zig");
pub const metadata = @import("metadata.zig");
pub const builder = @import("builder.zig");
pub const limits = @import("limits.zig");
pub const report = @import("report.zig");
pub const json = @import("json.zig");
pub const manifest = @import("manifest.zig");
pub const plugin = @import("plugin.zig");
pub const pipeline = @import("pipeline.zig");
pub const filters = @import("filters.zig");
pub const lowering = @import("lowering.zig");
const detect = @import("detect.zig");

pub const Limits = limits.Limits;
pub const Document = ast.Document;
pub const EntityId = ast.EntityId;
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
pub const Strictness = lowering.Strictness;
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
    /// The graded strict predicate (ZDS 0013): refuse the conversion,
    /// before anything is committed, when the priced loss crosses the
    /// grade. `.content` is bare `--strict`.
    strict: lowering.Strictness = .off,
    /// Serialize full facet rows into the manifest instead of the default
    /// digest-and-count summaries (ZDS 0013, manifest schema v2).
    preserve_facets: bool = false,
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
    /// What the caller's stream received (ZDS 0013, Core Contract
    /// Repairs): `.none` for path output, otherwise whether the stream got
    /// nothing, a partial prefix, or the complete artifact. A failed
    /// streamed conversion is thereby distinguishable from an empty
    /// document.
    stream: StreamState,
    arena_state: std.heap.ArenaAllocator.State,

    pub const StreamState = enum(u8) { none, untouched, partial, complete };

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
            var stream: Conversion.StreamState = switch (options.output) {
                .writer => .untouched,
                .path => .none,
            };

            const manifest_json = run(arena, io, options, &reports, &stream) catch |err| switch (err) {
                error.OutOfMemory => {
                    arena_instance.deinit();
                    const empty = std.heap.ArenaAllocator.init(gpa);
                    return .{
                        .status = .failed,
                        .reports = &oom_reports,
                        .manifest_json = null,
                        .exit_class = .conversion,
                        .stream = stream,
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
                        .stream = stream,
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
                .stream = stream,
                .arena_state = arena_instance.state,
            };
        }

        fn run(
            arena: std.mem.Allocator,
            io: Io,
            options: ConvertOptions,
            reports: *Reports,
            stream: *Conversion.StreamState,
        ) RunError![]const u8 {
            var input = try resolveInput(arena, io, options, reports);
            defer input.deinit(io);
            const from = try resolveFrom(arena, options, &input, reports, readers);
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
                                &input,
                                reports,
                                stream,
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
            input: *ResolvedInput,
            reports: *Reports,
            stream: *Conversion.StreamState,
        ) RunError![]const u8 {
            const loaded = loadAdjacentManifest(arena, io, options, input, reports);

            // Read.
            const store = try arena.create(ast.Store);
            store.* = .{};
            var tree_builder = builder.Builder.init(arena, store, options.limits);
            var read_context: plugin.ReadContext = .{
                .gpa = arena,
                .out = .{ .builder = &tree_builder },
                .input = switch (reader_descriptor.input) {
                    .seekable => input.source,
                    .bytes => .{ .bytes = try inputAllBytes(arena, input, reports) },
                },
                .input_name = input.name,
                .reports = reports,
                .manifest_in = if (loaded) |*value| value else null,
                .limits = options.limits,
            };
            reader_descriptor.read(&read_context) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed, error.DepthLimitExceeded, error.LimitExceeded => {
                    try ensureFailureReported(arena, reports, err, input.*);
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
                    error.LimitExceeded => {
                        try ensureFailureReported(arena, reports, error.LimitExceeded, input.*);
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
                stream,
            );
        }

        fn emit(
            comptime writer_descriptor: plugin.WriterDescriptor,
            comptime reader_descriptor: plugin.ReaderDescriptor,
            arena: std.mem.Allocator,
            io: Io,
            options: ConvertOptions,
            input: *ResolvedInput,
            doc: Document,
            loaded: ?manifest.Loaded,
            own_plugin_data: ?plugin.ReadContext.OwnPluginData,
            reports: *Reports,
            stream: *Conversion.StreamState,
        ) RunError![]const u8 {
            const Blake3 = std.crypto.hash.Blake3;

            // Media extraction happens only for path output: the plan names
            // the files and rewrites matching image URLs before the writer
            // runs, so the artifact references what will be committed.
            const media_plan: []const MediaPlanFile = switch (options.output) {
                .path => |path| try planResources(arena, path, doc),
                .writer => &.{},
            };

            const artifact_name = switch (options.output) {
                .path => |path| std.fs.path.basename(path),
                .writer => "stdout",
            };

            // The lowering plan (ZDS 0013): with a capability-declaring
            // writer, degradations land as priced rule hits. Graded strict
            // is a plan predicate gated by a dry run into a discarding
            // writer, so a refused conversion never creates the output.
            var plan_storage: ?lowering.Plan = null;
            if (writer_descriptor.capabilities) |caps| {
                if (lowering.findRefused(caps, &doc)) |tag_name| {
                    try reports.add(try refusedConstructReport(arena, writer_descriptor.format, tag_name));
                    return error.Failed;
                }
                plan_storage = try lowering.Plan.init(arena, caps.rules);
                if (options.strict != .off) {
                    var dry_plan = try lowering.Plan.init(arena, caps.rules);
                    var discard_buffer: [512]u8 = undefined;
                    var discarding = Io.Writer.Discarding.init(&discard_buffer);
                    var dry_context: plugin.WriteContext = .{
                        .plan = &dry_plan,
                        .gpa = arena,
                        .doc = &doc,
                        .out = &discarding.writer,
                        .reports = reports,
                        .limits = options.limits,
                        .manifest_in = if (loaded) |*value| value else null,
                    };
                    writer_descriptor.write(&dry_context) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.WriteFailed => {
                            try reports.add(try pathFailure(arena, "plan the output", artifact_name, err));
                            return error.Failed;
                        },
                    };
                    const total = lowering.addCost(dry_plan.cost(), lowering.reportedCost(reports));
                    if (options.strict.refuses(total)) {
                        dry_plan.flush(reports, options.limits) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.LimitExceeded => {
                                try ensureFailureReported(arena, reports, error.LimitExceeded, input.*);
                                return error.Failed;
                            },
                        };
                        try reports.add(strictReport(input.name, options.strict));
                        return error.Failed;
                    }
                }
            }

            var atomic: ?Io.File.Atomic = null;
            defer if (atomic) |*af| af.deinit(io);
            var file_buffer: [8 * 1024]u8 = undefined;
            var file_writer: Io.File.Writer = undefined;
            var hash_buffer: [4 * 1024]u8 = undefined;

            const underlying: *Io.Writer = switch (options.output) {
                .writer => |caller_stream| caller_stream,
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
                .plan = if (plan_storage) |*plan| plan else null,
                .gpa = arena,
                .doc = &doc,
                .out = &hashed.writer,
                .reports = reports,
                .limits = options.limits,
                .manifest_in = if (loaded) |*value| value else null,
            };
            if (options.output == .writer) stream.* = .partial;
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
            if (options.output == .writer) stream.* = .complete;
            const artifact_digest = manifest.digestHexFromHasher(&hashed.hasher);

            // The plan's aggregated loss reports land before the manifest
            // encodes, in first-hit order, exactly where the writer's
            // per-occurrence notes used to.
            if (plan_storage) |*plan| {
                plan.flush(reports, options.limits) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.LimitExceeded => {
                        try ensureFailureReported(arena, reports, error.LimitExceeded, input.*);
                        return error.Failed;
                    },
                };
            }

            // A writer without a capability declaration falls back to the
            // pre-plan strict rule: any report above a note refuses before
            // anything is committed.
            if (writer_descriptor.capabilities == null and options.strict != .off and
                reports.worst() != null and reports.worst() != .note)
            {
                try reports.add(strictReport(input.name, options.strict));
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
                    .digest_hex = input.digest_hex,
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
                .media = blk: {
                    const entries = try arena.alloc(manifest.MediaFile, media_plan.len);
                    for (media_plan, entries) |planned, *entry| {
                        entry.* = .{
                            .path = planned.rel_path,
                            .digest_hex = planned.digest_hex,
                        };
                    }
                    break :blk entries;
                },
                .facets = try manifest.facetEntries(
                    arena,
                    &doc,
                    if (writer_descriptor.capabilities) |caps| caps.facets else &.{},
                    options.preserve_facets,
                ),
            });

            // Commit: artifact first, then its media, then its manifest.
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
                    try reports.add(try commitFailure(arena, path, input.*, options, err));
                    return error.Failed;
                };
                // Media files belong to the artifact just committed; they
                // replace unconditionally under its `<stem>_media` directory.
                if (media_plan.len > 0) {
                    const dir_path = std.fs.path.dirname(media_plan[0].disk_path) orelse ".";
                    Io.Dir.cwd().createDirPath(io, dir_path) catch |err| {
                        try reports.add(try pathFailure(arena, "create the media directory", dir_path, err));
                        return error.Failed;
                    };
                    for (media_plan) |planned| {
                        Io.Dir.cwd().writeFile(io, .{
                            .sub_path = planned.disk_path,
                            .data = planned.bytes,
                        }) catch |err| {
                            try reports.add(try pathFailure(
                                arena,
                                "write a media file",
                                planned.disk_path,
                                err,
                            ));
                            return error.Failed;
                        };
                    }
                }
                materialize(&manifest_atomic, io, options.overwrite) catch |err| {
                    try reports.add(try commitFailure(arena, manifest_path, input.*, options, err));
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

        /// Detection weighs both kinds of evidence (ZDS 0013, Core
        /// Contract Repairs): when the file extension and the content
        /// signature disagree, content routes and a note names both
        /// findings, so `report.docx` holding RTF parses as RTF instead of
        /// failing confusingly.
        fn resolveFrom(
            arena: std.mem.Allocator,
            options: ConvertOptions,
            input: *ResolvedInput,
            reports: *Reports,
            comptime descriptors: []const plugin.ReaderDescriptor,
        ) RunError![]const u8 {
            if (options.from) |from| return from;

            const from_extension: ?[]const u8 = blk: {
                const extension = extensionOf(input.name) orelse break :blk null;
                inline for (descriptors) |descriptor| {
                    for (descriptor.extensions) |known| {
                        if (std.ascii.eqlIgnoreCase(extension, known)) break :blk descriptor.format;
                    }
                }
                break :blk null;
            };
            // A file input with a recognized extension routes without
            // sniffing, so the file is never slurped just to be doubted;
            // the extension-mismatch note applies to byte inputs and to
            // files whose extension resolves nothing.
            if (input.source == .file) {
                if (from_extension) |by_name| return by_name;
            }
            const sniff_bytes = try inputAllBytes(arena, input, reports);
            const from_content: ?[]const u8 = switch (sniff(sniff_bytes)) {
                .docx => "docx",
                .xlsx => "xlsx",
                .xlsb => "xlsb",
                .pptx => "pptx",
                .odt => "odt",
                .ods => "ods",
                .odp => "odp",
                .epub => "epub",
                .zip => "docx",
                .rtf => "rtf",
                .pdf => "pdf",
                .doc => "doc",
                .xls => "xls",
                .ppt => "ppt",
                .none => null,
            };

            if (from_extension) |by_name| {
                const by_bytes = from_content orelse return by_name;
                if (std.mem.eql(u8, by_name, by_bytes)) return by_name;
                // A bare ZIP signature is a weak hint, not a content
                // finding: any OOXML extension outranks it.
                if (sniff(sniff_bytes) == .zip) return by_name;
                try reports.add(try extensionMismatch(arena, input.name, by_name, by_bytes));
                return by_bytes;
            }
            if (from_content) |by_bytes| return by_bytes;
            try reportUndetectable(arena, reports, input.*, readerFormats());
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
    // The duplicate checks are quadratic in descriptors and extensions; the
    // default comptime quota does not survive a twenty-format bundle.
    @setEvalBranchQuota(1_000_000);
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

pub const ResolvedInput = detect.ResolvedInput;
const resolveInput = detect.resolveInput;
const inputAllBytes = detect.inputAllBytes;
const Sniffed = detect.Sniffed;
const sniff = detect.sniff;
const extensionOf = detect.extensionOf;

/// Reads and verifies `<input>.zenfmt.json`. Missing is normal; malformed,
/// oversized, or digest-mismatched is a warning and the data is ignored.
fn loadAdjacentManifest(
    arena: std.mem.Allocator,
    io: Io,
    options: ConvertOptions,
    input: *ResolvedInput,
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
    const actual = input.digest_hex;
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

// ---------------------------------------------------------------- media

const MediaPlanFile = struct {
    /// The URL written into the artifact, relative to its directory.
    rel_path: []const u8,
    /// Where the bytes land on disk.
    disk_path: []const u8,
    bytes: []const u8,
    digest_hex: manifest.DigestHex,
};

/// Names one file per registered media entry, rewrites every image whose
/// URL equals the entry's source to the planned relative path, and returns
/// the write plan. Runs before the writer so the artifact references the
/// files the commit step will create.
fn planResources(
    arena: std.mem.Allocator,
    output_path: []const u8,
    doc: Document,
) error{OutOfMemory}![]const MediaPlanFile {
    // `Document` exposes the store as const so plugins cannot mutate it;
    // the engine allocated every store a document can reference, and this
    // rewrite is the engine's own commit step.
    const store: *ast.Store = @constCast(doc.store);
    if (store.resources.items.len == 0) return &.{};

    const base = std.fs.path.basename(output_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    const parent = std.fs.path.dirname(output_path);

    var plan: std.ArrayList(MediaPlanFile) = .empty;
    const media_count = store.resources.items.len;
    var index: u32 = 0;
    while (index < media_count) : (index += 1) {
        const entry = store.resources.items[index];
        if (entry.bytes.len == 0) continue;
        const source = store.textSlice(entry.source);
        const bytes = store.resource_bytes.items[entry.bytes.start..][0..entry.bytes.len];
        const extension = mediaExtension(store.textSlice(entry.mime));
        const rel_path = try std.fmt.allocPrint(
            arena,
            "{s}_media/image-{d}.{s}",
            .{ stem, plan.items.len + 1, extension },
        );
        const disk_path = if (parent) |value|
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ value, rel_path })
        else
            rel_path;

        // Rewrite in place: image targets are side-table rows the engine
        // owns, and the new URL text appends to the shared pool.
        const url_range: ast.ByteRange = .{
            .start = @intCast(store.text.items.len),
            .len = @intCast(rel_path.len),
        };
        try store.text.appendSlice(arena, rel_path);
        const tags = store.inlines.items(.tag);
        const payloads = store.inlines.items(.payload);
        for (tags, payloads) |tag, payload_index| {
            if (tag != .image) continue;
            const target = &store.targets.items[payload_index];
            if (std.mem.eql(u8, store.textSlice(target.url), source)) {
                target.url = url_range;
            }
        }

        try plan.append(arena, .{
            .rel_path = rel_path,
            .disk_path = disk_path,
            .bytes = bytes,
            .digest_hex = entry.digest_hex,
        });
    }
    return plan.items;
}

/// File extension for a media MIME type; unknown types keep raw bytes
/// under a neutral extension rather than guessing.
fn mediaExtension(mime: []const u8) []const u8 {
    const table = [_]struct { mime: []const u8, extension: []const u8 }{
        .{ .mime = "image/jpeg", .extension = "jpg" },
        .{ .mime = "image/png", .extension = "png" },
        .{ .mime = "image/gif", .extension = "gif" },
        .{ .mime = "image/jp2", .extension = "jp2" },
        .{ .mime = "image/jpx", .extension = "jpf" },
        .{ .mime = "image/tiff", .extension = "tif" },
        .{ .mime = "image/bmp", .extension = "bmp" },
        .{ .mime = "image/svg+xml", .extension = "svg" },
        .{ .mime = "image/webp", .extension = "webp" },
        .{ .mime = "image/emf", .extension = "emf" },
        .{ .mime = "image/wmf", .extension = "wmf" },
    };
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(row.mime, mime)) return row.extension;
    }
    return "bin";
}

fn materialize(atomic: *Io.File.Atomic, io: Io, overwrite: bool) !void {
    if (overwrite) {
        try atomic.replace(io);
    } else {
        try atomic.link(io);
    }
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
const inputTooLarge = engine_reports.inputTooLarge;
const staleManifest = engine_reports.staleManifest;
const invalidTreeReport = engine_reports.invalidTreeReport;
const refusedConstructReport = engine_reports.refusedConstructReport;
const extensionMismatch = engine_reports.extensionMismatch;
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
    _ = detect;
    _ = schema;
    _ = facets;
    _ = lowering;
    _ = filters;
}

test "edit distance suggests the nearest format" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("docs", "docx"));
    const known = [_][]const u8{ "docx", "markdown", "text" };
    try std.testing.expectEqualStrings("docx", closestFormat("docs", &known).?);
    try std.testing.expectEqual(@as(?[]const u8, null), closestFormat("zzzzz", &known));
}
