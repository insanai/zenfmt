//! In-process stage benchmark (ZDS 0013, Core Contract Repairs): where a
//! conversion's time goes, measured through the library's public seams
//! without new core API.
//!
//! Two configurations run per corpus file, in one process, medians of N.
//! "read" converts through a probe writer that emits nothing, so it prices
//! input resolution, the reader, tree building, validation, and the
//! manifest. "full" uses a timed wrapper around the ordinary Markdown
//! writer. The wrapper directly measures writer-callback time; "lowering"
//! is the saturating residual full - read - writer, which also contains the
//! small writer setup and finalization difference. Derived values are named
//! in the output and never presented as direct measurements.
//!
//! Inputs are pre-read into memory so both configurations price the same
//! bytes; disk time is excluded from every column. Results are written to
//! `benchmarks/results/stages.json`; numbers are never edited by hand.

const std = @import("std");
const Io = std.Io;
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");

const default_iterations = 5;
const max_iterations = 128;
const max_corpus_files = 64;
const max_input_bytes = 512 * 1024 * 1024;
const corpus_dir = "benchmarks/corpus";
const out_path = "benchmarks/results/stages.json";

const Options = struct {
    iterations: u32 = default_iterations,
    file: ?[]const u8 = null,
    version: []const u8 = "unknown",
    revision: []const u8 = "unknown",
};

/// The probe writer: covers nothing, emits nothing, costs nothing. A
/// conversion through it performs every stage except rendering.
fn writeNothing(ctx: *core.WriteContext) core.WriteError!void {
    _ = ctx;
}

const probe_writer = core.Writer(.{
    .id = "ai.insan.zenfmt.stage-probe",
    .format = "probe",
    .extensions = &.{"probe"},
    .write = writeNothing,
});

const markdown_writer = zenfmt.Default.writers[0];

const WriterTiming = struct {
    io: Io,
    elapsed_ns: u64 = 0,
};

var active_writer_timing: ?*WriterTiming = null;

fn writeTimedMarkdown(ctx: *core.WriteContext) core.WriteError!void {
    const timing = active_writer_timing.?;
    const started = Io.Clock.Timestamp.now(timing.io, .awake);
    defer {
        const elapsed = started.durationTo(Io.Clock.Timestamp.now(timing.io, .awake));
        timing.elapsed_ns = @intCast(@max(elapsed.raw.nanoseconds, 0));
    }
    try markdown_writer.write(ctx);
}

const timed_markdown_writer = core.Writer(.{
    .id = markdown_writer.id,
    .format = markdown_writer.format,
    .extensions = markdown_writer.extensions,
    .data_version = markdown_writer.data_version,
    .write = writeTimedMarkdown,
    .capabilities = markdown_writer.capabilities,
});

/// The default readers with the probe writer in place of Markdown.
const ProbeBundle = core.Bundle(.{
    .readers = zenfmt.Default.readers,
    .writers = .{probe_writer},
});

const TimedBundle = core.Bundle(.{
    .readers = zenfmt.Default.readers,
    .writers = .{timed_markdown_writer},
});

const StageResult = struct {
    name: []const u8,
    size: u64,
    read_ns: u64,
    writer_ns: u64,
    full_ns: u64,
    memory_ns: u64,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var options: Options = .{};
    parseArgs(init.minimal.args, &options) catch {
        std.debug.print(
            "benchmark-stages: expected --file NAME, --iterations N " ++
                "(1..{d}), --version VERSION, and/or --revision SHA\n" ++
                "hint: zig build benchmark-stages -- --file data.csv " ++
                "--iterations 25\n",
            .{max_iterations},
        );
        return 2;
    };

    const names = try corpusFiles(gpa, io);
    defer gpa.free(names);
    if (names.len == 0) {
        std.debug.print(
            "benchmark-stages: no corpus files in {s}; run benchmarks/fetch_corpus.sh first\n",
            .{corpus_dir},
        );
        return 1;
    }

    var results: std.ArrayList(StageResult) = .empty;
    defer results.deinit(gpa);
    for (names) |name| {
        if (options.file) |selected| {
            if (!std.mem.eql(u8, selected, name)) continue;
        }
        const result = try stageFile(gpa, io, name, options.iterations);
        try results.append(gpa, result);
        std.debug.print("done {s}\n", .{name});
    }
    if (results.items.len == 0) {
        std.debug.print(
            "benchmark-stages: `{s}` is not a corpus file\n" ++
                "hint: choose a file under {s}, or omit --file for all files\n",
            .{ options.file.?, corpus_dir },
        );
        return 2;
    }

    var machine: std.Io.Writer.Allocating = .init(gpa);
    defer machine.deinit();
    try renderJson(
        &machine.writer,
        results.items,
        options.iterations,
        options.version,
        options.revision,
    );
    Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = machine.written() }) catch |err| {
        std.debug.print("benchmark-stages: cannot write {s}: {t}\n", .{ out_path, err });
        return 1;
    };
    std.debug.print("written to {s}\n", .{out_path});
    return 0;
}

fn parseArgs(args: std.process.Args, options: *Options) !void {
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next();
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file")) {
            options.file = iterator.next() orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--version")) {
            options.version = iterator.next() orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--revision")) {
            options.revision = iterator.next() orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            const text_value = iterator.next() orelse return error.InvalidArgument;
            options.iterations = try std.fmt.parseInt(u32, text_value, 10);
            if (options.iterations == 0 or options.iterations > max_iterations) {
                return error.InvalidArgument;
            }
        } else {
            return error.InvalidArgument;
        }
    }
}

fn stageFile(
    gpa: std.mem.Allocator,
    io: Io,
    name: []const u8,
    iterations: u32,
) !StageResult {
    std.debug.assert(name.len > 0);
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ corpus_dir, name });
    defer gpa.free(path);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_input_bytes));
    defer gpa.free(bytes);

    // Warm-up once per configuration, then median of N.
    _ = try timeConvert(ProbeBundle, gpa, io, name, bytes, null);
    var warm_timing: WriterTiming = .{ .io = io };
    _ = try timeConvert(TimedBundle, gpa, io, name, bytes, &warm_timing);
    _ = try timeMemoryConvert(gpa, io, name, bytes);

    var read_samples: [max_iterations]u64 = undefined;
    var writer_samples: [max_iterations]u64 = undefined;
    var full_samples: [max_iterations]u64 = undefined;
    var memory_samples: [max_iterations]u64 = undefined;
    var index: u32 = 0;
    while (index < iterations) : (index += 1) {
        read_samples[index] = try timeConvert(ProbeBundle, gpa, io, name, bytes, null);
        var timing: WriterTiming = .{ .io = io };
        full_samples[index] = try timeConvert(TimedBundle, gpa, io, name, bytes, &timing);
        writer_samples[index] = timing.elapsed_ns;
        memory_samples[index] = try timeMemoryConvert(gpa, io, name, bytes);
    }
    std.debug.assert(index == iterations);

    return .{
        .name = try gpa.dupe(u8, name),
        .size = bytes.len,
        .read_ns = median(read_samples[0..iterations]),
        .writer_ns = median(writer_samples[0..iterations]),
        .full_ns = median(full_samples[0..iterations]),
        .memory_ns = median(memory_samples[0..iterations]),
    };
}

/// The in-process memory-publication profile (ZDS 0014): the complete
/// ensemble — artifact bytes, embedded resources, digests, and manifest —
/// staged in conversion-owned memory through the default bundle. This is
/// the native baseline the installed wheel's warm memory calls are
/// compared against.
fn timeMemoryConvert(
    gpa: std.mem.Allocator,
    io: Io,
    name: []const u8,
    bytes: []const u8,
) !u64 {
    const started = Io.Clock.Timestamp.now(io, .awake);
    var conversion = zenfmt.convert(gpa, io, .{
        .input = .{ .bytes = .{ .name = name, .data = bytes } },
        .output = .{ .memory = .{ .artifact_name = "artifact.md" } },
    });
    const elapsed = started.durationTo(Io.Clock.Timestamp.now(io, .awake));
    defer conversion.deinit(gpa);
    if (conversion.status != .success) {
        std.debug.print("benchmark-stages: {s} failed to convert\n", .{name});
        return error.ConversionFailed;
    }
    std.debug.assert(conversion.ensemble != null);
    return @intCast(@max(elapsed.raw.nanoseconds, 0));
}

fn timeConvert(
    comptime Bundle: type,
    gpa: std.mem.Allocator,
    io: Io,
    name: []const u8,
    bytes: []const u8,
    writer_timing: ?*WriterTiming,
) !u64 {
    var discard_buffer: [8 * 1024]u8 = undefined;
    var discarding = Io.Writer.Discarding.init(&discard_buffer);
    const started = Io.Clock.Timestamp.now(io, .awake);
    std.debug.assert(active_writer_timing == null);
    active_writer_timing = writer_timing;
    defer active_writer_timing = null;
    var conversion = Bundle.convert(gpa, io, .{
        .input = .{ .bytes = .{ .name = name, .data = bytes } },
        .output = .{ .writer = &discarding.writer },
    });
    const elapsed = started.durationTo(Io.Clock.Timestamp.now(io, .awake));
    defer conversion.deinit(gpa);
    if (conversion.status != .success) {
        std.debug.print("benchmark-stages: {s} failed to convert\n", .{name});
        return error.ConversionFailed;
    }
    return @intCast(@max(elapsed.raw.nanoseconds, 0));
}

fn median(samples: []u64) u64 {
    std.debug.assert(samples.len >= 1);
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

fn corpusFiles(gpa: std.mem.Allocator, io: Io) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    var dir = Io.Dir.cwd().openDir(io, corpus_dir, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.endsWith(u8, entry.name, ".part")) continue;
        if (list.items.len == max_corpus_files) break;
        try list.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    return list.toOwnedSlice(gpa);
}

/// `stages.json`: read, writer, and full are measured. Lowering is the
/// residual and named in `derived` so no consumer mistakes it.
fn renderJson(
    writer: *std.Io.Writer,
    results: []const StageResult,
    iterations: u32,
    version: []const u8,
    revision: []const u8,
) !void {
    try writer.print(
        "{{\"version\":\"{s}\",\"git_revision\":\"{s}\"," ++
            "\"derived\":[\"lowering_ms\"],\"iterations\":{d},\"files\":[",
        .{ version, revision, iterations },
    );
    for (results, 0..) |result, index| {
        for (result.name) |byte| std.debug.assert(byte >= 0x20 and byte != '"' and byte != '\\');
        if (index > 0) try writer.writeAll(",");
        const lowering_ns = (result.full_ns -| result.read_ns) -| result.writer_ns;
        try writer.print(
            "{{\"name\":\"{s}\",\"size\":{d},\"read_ms\":{d:.3}," ++
                "\"lowering_ms\":{d:.3},\"writer_ms\":{d:.3}," ++
                "\"full_ms\":{d:.3},\"memory_ms\":{d:.3}}}",
            .{
                result.name,
                result.size,
                @as(f64, @floatFromInt(result.read_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(lowering_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(result.writer_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(result.full_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(result.memory_ns)) / std.time.ns_per_ms,
            },
        );
    }
    try writer.writeAll("]}\n");
}
