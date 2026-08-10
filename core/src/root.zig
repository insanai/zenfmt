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
const adjacent_manifest = @import("adjacent_manifest.zig");
const artifact_render = @import("artifact_render.zig");
const bundle_validation = @import("bundle_validation.zig");

const options_mod = @import("options.zig");
const preservation = @import("preservation.zig");
const publication = @import("publication.zig");
const resource_output = @import("resource_output.zig");
const stream_output = @import("stream_output.zig");

pub const ast = @import("ast.zig");
pub const payload = @import("payload.zig");
pub const schema = @import("schema.zig");
pub const facets = @import("facets.zig");
pub const resources = @import("resources.zig");
pub const metadata = @import("metadata.zig");
pub const builder = @import("builder.zig");
pub const limits = @import("limits.zig");
pub const report = @import("report.zig");
pub const json = @import("json.zig");
pub const manifest = @import("manifest.zig");
pub const plugin = @import("plugin.zig");
pub const host = @import("host.zig");
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

pub const InputSpec = options_mod.InputSpec;
pub const OutputSpec = options_mod.OutputSpec;
pub const ConvertOptions = options_mod.ConvertOptions;
pub const Status = options_mod.Status;

const oom_reports = [_]Report{report.out_of_memory};

fn outOfMemoryConversion(
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    stream: Conversion.StreamState,
) Conversion {
    arena.deinit();
    const empty = std.heap.ArenaAllocator.init(gpa);
    return .{
        .status = .failed,
        .reports = &oom_reports,
        .manifest_json = null,
        .exit_class = .conversion,
        .stream = stream,
        .arena_state = empty.state,
    };
}

/// An embedded artifact resource file, as planned for path or memory
/// publication.
pub const ResourceFile = resource_output.File;

/// The complete in-memory artifact ensemble of a successful `.memory`
/// conversion (ZDS 0014): artifact bytes plus every embedded resource, with
/// the same deterministic naming, target rewriting, and digests as path
/// publication. All bytes are arena-owned by the conversion.
pub const MemoryEnsemble = struct {
    artifact_name: []const u8,
    artifact: []const u8,
    resources: []const ResourceFile,
};

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
    /// The complete artifact ensemble; non-null only for a successful
    /// `.memory` conversion. Failure never populates it.
    ensemble: ?MemoryEnsemble = null,
    /// Canonical reader format id selected by the engine; set on success.
    source_format: ?[]const u8 = null,
    /// Canonical writer format id selected by the engine; set on success.
    output_format: ?[]const u8 = null,
    /// What the caller's stream received (ZDS 0013, Core Contract
    /// Repairs): `.none` for path output, otherwise whether the stream got
    /// nothing, a partial prefix, or the complete artifact. A failed
    /// streamed conversion is thereby distinguishable from an empty
    /// document.
    stream: StreamState,
    arena_state: std.heap.ArenaAllocator.State,

    pub const StreamState = stream_output.State;

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
///
/// `spec.host` selects the host authority (ZDS 0015). It defaults to `.host`,
/// so every existing caller is unaffected and `convert` keeps taking a
/// `std.Io`. A `.pure` bundle takes no host value at all and has no
/// filesystem code compiled into it.
pub fn Bundle(comptime spec: anytype) type {
    const reader_array = comptime bundle_validation.descriptorArray(
        plugin.ReaderDescriptor,
        spec.readers,
    );
    const writer_array = comptime bundle_validation.descriptorArray(
        plugin.WriterDescriptor,
        spec.writers,
    );
    comptime bundle_validation.validate(&reader_array, &writer_array);
    const mode: host.Mode = if (@hasField(@TypeOf(spec), "host"))
        spec.host
    else
        .host;

    return struct {
        pub const readers: []const plugin.ReaderDescriptor = &reader_array;
        pub const writers: []const plugin.WriterDescriptor = &writer_array;
        pub const default_output_format = writer_array[0].format;
        /// The host authority this bundle was built with.
        pub const host_mode: host.Mode = mode;

        const ReadResult = struct {
            doc: Document,
            own_plugin_data: ?plugin.ReadContext.OwnPluginData,
        };

        pub fn convert(
            gpa: std.mem.Allocator,
            io: host.Io(host_mode),
            options: ConvertOptions,
        ) Conversion {
            var arena_instance = std.heap.ArenaAllocator.init(gpa);
            const arena = arena_instance.allocator();
            const invalid_limit = options.limits.invalidField();
            var reports = report.Reports.init(
                arena,
                if (invalid_limit == null) options.limits else .{},
            );
            var stream: Conversion.StreamState = switch (options.output) {
                .writer => .untouched,
                .path, .memory => .none,
            };
            if (invalid_limit) |field| {
                const value = invalidLimitConfiguration(
                    arena,
                    @tagName(field),
                    options.limits.fieldValue(field),
                ) catch return outOfMemoryConversion(gpa, &arena_instance, stream);
                reports.add(value) catch {
                    return outOfMemoryConversion(gpa, &arena_instance, stream);
                };
                const final = reports.finalize() catch &oom_reports;
                return .{
                    .status = .failed,
                    .reports = final,
                    .manifest_json = null,
                    .exit_class = .limit,
                    .stream = stream,
                    .arena_state = arena_instance.state,
                };
            }

            var extra: SelectedOutput = .{};
            const manifest_json = run(
                arena,
                io,
                options,
                &reports,
                &stream,
                &extra,
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    return outOfMemoryConversion(gpa, &arena_instance, stream);
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
                .ensemble = extra.ensemble,
                .source_format = extra.source_format,
                .output_format = extra.output_format,
                .stream = stream,
                .arena_state = arena_instance.state,
            };
        }

        /// Success-only result data threaded out of the static conversion
        /// path: the selected format ids and, for `.memory` output, the
        /// staged ensemble.
        const SelectedOutput = struct {
            ensemble: ?MemoryEnsemble = null,
            source_format: ?[]const u8 = null,
            output_format: ?[]const u8 = null,
        };

        fn run(
            arena: std.mem.Allocator,
            io: host.Io(host_mode),
            options: ConvertOptions,
            reports: *Reports,
            stream: *Conversion.StreamState,
            extra: *SelectedOutput,
        ) RunError![]const u8 {
            // A pure bundle has no filesystem on either side. Refusing an
            // output path here, before any reader runs, is what keeps the
            // writer's path arm genuinely unreachable rather than merely
            // unlikely.
            if (host_mode == .pure) {
                switch (options.output) {
                    .path => |path| {
                        try reports.add(try hostIoUnavailable(arena, path));
                        return error.Failed;
                    },
                    .writer, .memory => {},
                }
            }
            var input = try resolveInput(host_mode, arena, io, options, reports);
            defer input.deinit(host_mode, io);
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
                                extra,
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
            io: host.Io(host_mode),
            options: ConvertOptions,
            input: *ResolvedInput,
            reports: *Reports,
            stream: *Conversion.StreamState,
            extra: *SelectedOutput,
        ) RunError![]const u8 {
            const adjacent = try adjacent_manifest.load(
                host_mode,
                arena,
                io,
                input.path,
                input.digest_hex,
                options.limits,
            );
            const loaded: ?manifest.Loaded = switch (adjacent) {
                .missing => null,
                .invalid => |invalid| blk: {
                    try reports.add(try staleManifest(
                        arena,
                        invalid,
                        input.name,
                    ));
                    break :blk null;
                },
                .loaded => |value| value,
            };
            var result = try readStatic(
                reader_descriptor,
                arena,
                options,
                input,
                loaded,
                reports,
            );
            result.doc = try runPipeline(
                arena,
                options,
                input.*,
                reader_descriptor.format,
                result.doc,
                reports,
            );
            return emit(
                writer_descriptor,
                reader_descriptor,
                arena,
                io,
                options,
                input,
                result.doc,
                loaded,
                result.own_plugin_data,
                reports,
                stream,
                extra,
            );
        }

        fn readStatic(
            comptime descriptor: plugin.ReaderDescriptor,
            arena: std.mem.Allocator,
            options: ConvertOptions,
            input: *ResolvedInput,
            loaded: ?manifest.Loaded,
            reports: *Reports,
        ) RunError!ReadResult {
            const store = try arena.create(ast.Store);
            store.* = .{};
            var tree_builder = builder.Builder.init(arena, store, options.limits);
            defer tree_builder.deinit();
            var read_context: plugin.ReadContext = .{
                .gpa = arena,
                .out = .{ .builder = &tree_builder },
                .input = switch (descriptor.input) {
                    .seekable => input.source,
                    .bytes => .{ .bytes = try inputAllBytes(arena, input, reports) },
                },
                .input_name = input.name,
                .reports = reports,
                .preservation_in = preservation.entry(
                    loaded,
                    descriptor.id,
                    descriptor.data_version,
                ),
                .limits = options.limits,
            };
            descriptor.read(&read_context) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Malformed, error.DepthLimitExceeded, error.LimitExceeded => {
                    try ensureFailureReported(
                        arena,
                        reports,
                        err,
                        input.*,
                        descriptor.format,
                    );
                    return error.Failed;
                },
            };
            const own_plugin_data = preservation.canonicalize(
                arena,
                descriptor,
                read_context.own_plugin_data,
                options.limits,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try reports.add(try invalidPreservationData(
                        arena,
                        descriptor.id,
                        descriptor.data_version,
                        err,
                    ));
                    return error.Failed;
                },
            };
            var doc = tree_builder.finish() catch return error.OutOfMemory;
            doc.plugin_data = try preservation.carry(arena, store, loaded);
            ast.validate(&doc, options.limits) catch {
                try reports.add(invalidTreeReport(descriptor.id));
                return error.Failed;
            };
            return .{ .doc = doc, .own_plugin_data = own_plugin_data };
        }

        fn runPipeline(
            arena: std.mem.Allocator,
            options: ConvertOptions,
            input: ResolvedInput,
            input_format: []const u8,
            initial: Document,
            reports: *Reports,
        ) RunError!Document {
            var doc = initial;
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
                        try ensureFailureReported(
                            arena,
                            reports,
                            error.LimitExceeded,
                            input,
                            input_format,
                        );
                        return error.Failed;
                    },
                };
            }
            return doc;
        }

        fn emit(
            comptime writer_descriptor: plugin.WriterDescriptor,
            comptime reader_descriptor: plugin.ReaderDescriptor,
            arena: std.mem.Allocator,
            io: host.Io(host_mode),
            options: ConvertOptions,
            input: *ResolvedInput,
            doc: Document,
            loaded: ?manifest.Loaded,
            own_plugin_data: ?plugin.ReadContext.OwnPluginData,
            reports: *Reports,
            stream: *Conversion.StreamState,
            extra: *SelectedOutput,
        ) RunError![]const u8 {
            const media_plan: []const resource_output.File = switch (options.output) {
                .path => |path| try resource_output.plan(arena, path, doc),
                .memory => |memory| try resource_output.plan(
                    arena,
                    memory.artifact_name,
                    doc,
                ),
                .writer => &.{},
            };
            const artifact_name = switch (options.output) {
                .path => |path| std.fs.path.basename(path),
                .memory => |memory| memory.artifact_name,
                .writer => "stdout",
            };
            var plan_storage = try preparePlan(
                writer_descriptor,
                arena,
                options,
                input.name,
                &doc,
                reports,
            );
            var atomic: ?host.Atomic(host_mode) = null;
            defer if (host_mode == .host) {
                if (atomic) |*af| af.deinit(io);
            };
            const rendered = try artifact_render.render(
                host_mode,
                writer_descriptor,
                arena,
                io,
                options,
                artifact_name,
                &doc,
                loaded,
                reports,
                stream,
                &plan_storage,
                &atomic,
            );
            const manifest_json = try buildManifestReported(
                reader_descriptor,
                writer_descriptor,
                arena,
                options,
                input,
                &doc,
                loaded,
                own_plugin_data,
                reports,
                media_plan,
                rendered.digest,
            );
            try publishPath(
                arena,
                io,
                options,
                input.*,
                manifest_json,
                media_plan,
                &atomic,
                reports,
            );
            extra.source_format = reader_descriptor.format;
            extra.output_format = writer_descriptor.format;
            if (options.output == .memory) {
                extra.ensemble = .{
                    .artifact_name = artifact_name,
                    .artifact = rendered.memory_bytes.?,
                    .resources = media_plan,
                };
            }
            return manifest_json;
        }

        fn buildManifestReported(
            comptime reader: plugin.ReaderDescriptor,
            comptime writer: plugin.WriterDescriptor,
            arena: std.mem.Allocator,
            options: ConvertOptions,
            input: *const ResolvedInput,
            doc: *const Document,
            loaded: ?manifest.Loaded,
            own_plugin_data: ?plugin.ReadContext.OwnPluginData,
            reports: *Reports,
            media_plan: []const resource_output.File,
            digest: manifest.DigestHex,
        ) RunError![]const u8 {
            return buildManifest(
                reader,
                writer,
                arena,
                options,
                input,
                doc,
                loaded,
                own_plugin_data,
                reports,
                media_plan,
                digest,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try reports.add(try invalidManifestEncoding(
                        arena,
                        writer.format,
                        err,
                    ));
                    return error.Failed;
                },
            };
        }

        fn preparePlan(
            comptime descriptor: plugin.WriterDescriptor,
            arena: std.mem.Allocator,
            options: ConvertOptions,
            input_name: []const u8,
            doc: *const Document,
            reports: *Reports,
        ) RunError!?lowering.Plan {
            const caps = descriptor.capabilities orelse {
                if (options.strict != .off) {
                    try reports.add(try strictNeedsCapabilities(
                        arena,
                        descriptor.format,
                        input_name,
                    ));
                    return error.Failed;
                }
                return null;
            };
            if (try lowering.findRefused(arena, caps, doc)) |tag_name| {
                try reports.add(try refusedConstructReport(
                    arena,
                    descriptor.format,
                    tag_name,
                    input_name,
                ));
                return error.Failed;
            }
            var plan = lowering.Plan.build(arena, caps, doc, options.limits) catch |err| {
                return planFailure(arena, descriptor.format, input_name, options, reports, err);
            };
            const prior = lowering.reportedCost(reports) catch {
                try reports.add(try invalidLoweringPlan(
                    arena,
                    descriptor.format,
                    error.CostOverflow,
                ));
                return error.Failed;
            };
            const total = lowering.addCost(plan.cost(), prior) catch {
                try reports.add(try invalidLoweringPlan(
                    arena,
                    descriptor.format,
                    error.CostOverflow,
                ));
                return error.Failed;
            };
            try plan.flush(reports);
            if (options.strict.refuses(total)) {
                try reports.add(strictReport(input_name, options.strict));
                return error.Failed;
            }
            return plan;
        }

        fn planFailure(
            arena: std.mem.Allocator,
            format: []const u8,
            input_name: []const u8,
            options: ConvertOptions,
            reports: *Reports,
            err: lowering.PlanError,
        ) RunError {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AlternativeLimitExceeded,
                error.WorkLimitExceeded,
                error.DepthLimitExceeded,
                => {
                    const value = loweringLimitReport(
                        arena,
                        input_name,
                        options.limits,
                        err,
                    ) catch return error.OutOfMemory;
                    reports.add(value) catch return error.OutOfMemory;
                },
                error.InvalidPlan, error.CostOverflow => {
                    const value = invalidLoweringPlan(arena, format, err) catch
                        return error.OutOfMemory;
                    reports.add(value) catch return error.OutOfMemory;
                },
            }
            return error.Failed;
        }

        fn buildManifest(
            comptime reader: plugin.ReaderDescriptor,
            comptime writer: plugin.WriterDescriptor,
            arena: std.mem.Allocator,
            options: ConvertOptions,
            input: *const ResolvedInput,
            doc: *const Document,
            loaded: ?manifest.Loaded,
            own_plugin_data: ?plugin.ReadContext.OwnPluginData,
            reports: *Reports,
            media_plan: []const resource_output.File,
            digest: manifest.DigestHex,
        ) json.WriteError![]const u8 {
            var meta_stream = json.WriteStream.init(arena);
            defer meta_stream.deinit();
            try metadata.writeMetaMap(arena, doc, doc.meta, &meta_stream);
            const meta_json = try meta_stream.toOwnedSlice();
            const media = switch (options.output) {
                .path, .memory => try resource_output.manifestEntries(
                    arena,
                    doc,
                    media_plan,
                ),
                .writer => &.{},
            };
            const consumed = if (writer.capabilities) |caps| caps.facets else &.{};
            return manifest.encode(arena, .{
                .source = .{
                    .name = input.name,
                    .format = reader.format,
                    .digest_hex = input.digest_hex,
                    .plugin_id = reader.id,
                },
                .artifact = .{
                    .name = switch (options.output) {
                        .path => |path| std.fs.path.basename(path),
                        .memory => |memory| memory.artifact_name,
                        .writer => "stdout",
                    },
                    .format = writer.format,
                    .digest_hex = digest,
                    .plugin_id = writer.id,
                },
                .document_metadata = meta_json,
                .reports = try reports.finalize(),
                .plugins = try preservation.merge(
                    arena,
                    if (loaded) |value| value.plugins else &.{},
                    reader.id,
                    own_plugin_data,
                ),
                .media = media,
                .facets = try manifest.facetEntries(
                    arena,
                    doc,
                    consumed,
                    options.preserve_facets,
                ),
            });
        }

        fn publishPath(
            arena: std.mem.Allocator,
            io: host.Io(host_mode),
            options: ConvertOptions,
            input: ResolvedInput,
            manifest_json: []const u8,
            media_plan: []const resource_output.File,
            atomic: *?host.Atomic(host_mode),
            reports: *Reports,
        ) RunError!void {
            // Publication is the engine's only write to the filesystem, so a
            // pure bundle does not compile it. The guard is comptime: the
            // body below is absent from that build rather than skipped in it.
            if (host_mode == .host) {
                const path = switch (options.output) {
                    .writer, .memory => return,
                    .path => |value| value,
                };
                var failure: publication.Failure = .{};
                publication.publish(
                    arena,
                    io,
                    &atomic.*.?,
                    path,
                    manifest_json,
                    media_plan,
                    options.overwrite,
                    &failure,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Failed => {
                        const value = switch (failure.kind) {
                            .destination_exists => try commitFailure(
                                arena,
                                failure.path,
                                input,
                                options,
                                failure.cause,
                            ),
                            .operation => try pathFailure(
                                arena,
                                failure.operation,
                                failure.path,
                                failure.cause,
                            ),
                        };
                        try reports.add(value);
                        return error.Failed;
                    },
                };
            }
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
            const from_content = sniffFormat(sniff_bytes);

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

// --------------------------------------------------- engine mechanics

/// Content sniffing for hosts that receive bare bytes (ZDS 0016, the
/// server's input-name fallback): the format id detection would infer from
/// content alone, or null when the bytes resemble nothing. The mapping is
/// the one detection itself uses, including the bare-ZIP default to `docx`.
pub fn sniffFormat(bytes: []const u8) ?[]const u8 {
    return switch (detect.sniff(bytes)) {
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
}

pub const ResolvedInput = detect.ResolvedInput;
const resolveInput = detect.resolveInput;
const inputAllBytes = detect.inputAllBytes;
const sniff = detect.sniff;
const extensionOf = detect.extensionOf;

// The engine's own report constructors live in `engine_reports.zig`.
const engine_reports = @import("engine_reports.zig");
const FormatRole = engine_reports.FormatRole;
const reportUnknownFormat = engine_reports.reportUnknownFormat;
const reportUndetectable = engine_reports.reportUndetectable;
const inputTooLarge = engine_reports.inputTooLarge;
const outputTooLarge = engine_reports.outputTooLarge;
const invalidLimitConfiguration = engine_reports.invalidLimitConfiguration;
const staleManifest = engine_reports.staleManifest;
const invalidTreeReport = engine_reports.invalidTreeReport;
const refusedConstructReport = engine_reports.refusedConstructReport;
const invalidLoweringPlan = engine_reports.invalidLoweringPlan;
const invalidManifestEncoding = engine_reports.invalidManifestEncoding;
const invalidPreservationData = engine_reports.invalidPreservationData;
const loweringLimitReport = engine_reports.loweringLimitReport;
const extensionMismatch = engine_reports.extensionMismatch;
const strictReport = engine_reports.strictReport;
const strictNeedsCapabilities = engine_reports.strictNeedsCapabilities;
const pathFailure = engine_reports.pathFailure;
const hostIoUnavailable = engine_reports.hostIoUnavailable;
const writerFailure = engine_reports.writerFailure;
const commitFailure = engine_reports.commitFailure;
const ensureFailureReported = engine_reports.ensureFailureReported;

// ---------------------------------------------------------------- tests

test {
    _ = @import("root_test.zig");
}
