//! In-process stage benchmark (ZDS 0013, Core Contract Repairs): where a
//! conversion's time goes, measured through the library's public seams
//! without new core API.
//!
//! Two configurations run per corpus file, in one process, medians of N:
//! "read" converts through a probe writer that emits nothing, so it prices
//! input resolution, the reader, tree building, validation, and the
//! manifest; "full" is the ordinary Markdown conversion into a discarding
//! writer. "render" is DERIVED as full minus read: the Markdown planning
//! and rendering share. It is labeled derived in the output and in the
//! book, never presented as a direct measurement.
//!
//! Inputs are pre-read into memory so both configurations price the same
//! bytes; disk time is excluded from every column. Results are written to
//! `benchmarks/results/stages.json`; numbers are never edited by hand.

const std = @import("std");
const Io = std.Io;
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");

const iterations = 5;
const max_corpus_files = 64;
const max_input_bytes = 512 * 1024 * 1024;
const corpus_dir = "benchmarks/corpus";
const out_path = "benchmarks/results/stages.json";

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

/// The default readers with the probe writer in place of Markdown.
const ProbeBundle = core.Bundle(.{
    .readers = zenfmt.Default.readers,
    .writers = .{probe_writer},
});

const StageResult = struct {
    name: []const u8,
    size: u64,
    read_ns: u64,
    full_ns: u64,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

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
        const result = try stageFile(gpa, io, name);
        try results.append(gpa, result);
        std.debug.print("done {s}\n", .{name});
    }

    var machine: std.Io.Writer.Allocating = .init(gpa);
    defer machine.deinit();
    try renderJson(&machine.writer, results.items);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = machine.written() }) catch |err| {
        std.debug.print("benchmark-stages: cannot write {s}: {t}\n", .{ out_path, err });
        return 1;
    };
    std.debug.print("written to {s}\n", .{out_path});
    return 0;
}

fn stageFile(gpa: std.mem.Allocator, io: Io, name: []const u8) !StageResult {
    std.debug.assert(name.len > 0);
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ corpus_dir, name });
    defer gpa.free(path);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_input_bytes));
    defer gpa.free(bytes);

    // Warm-up once per configuration, then median of N.
    _ = try timeConvert(ProbeBundle, gpa, io, name, bytes);
    _ = try timeConvert(zenfmt.Default, gpa, io, name, bytes);

    var read_samples: [iterations]u64 = undefined;
    var full_samples: [iterations]u64 = undefined;
    var index: u32 = 0;
    while (index < iterations) : (index += 1) {
        read_samples[index] = try timeConvert(ProbeBundle, gpa, io, name, bytes);
        full_samples[index] = try timeConvert(zenfmt.Default, gpa, io, name, bytes);
    }
    std.debug.assert(index == iterations);

    return .{
        .name = try gpa.dupe(u8, name),
        .size = bytes.len,
        .read_ns = median(&read_samples),
        .full_ns = median(&full_samples),
    };
}

fn timeConvert(
    comptime Bundle: type,
    gpa: std.mem.Allocator,
    io: Io,
    name: []const u8,
    bytes: []const u8,
) !u64 {
    var discard_buffer: [8 * 1024]u8 = undefined;
    var discarding = Io.Writer.Discarding.init(&discard_buffer);
    const started = Io.Clock.Timestamp.now(io, .awake);
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

fn median(samples: *[iterations]u64) u64 {
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

/// `stages.json`: read and full are measured; render is derived as their
/// difference and named in `derived` so no consumer mistakes it.
fn renderJson(writer: *std.Io.Writer, results: []const StageResult) !void {
    try writer.print(
        "{{\"derived\":[\"render_ms\"],\"iterations\":{d},\"files\":[",
        .{iterations},
    );
    for (results, 0..) |result, index| {
        for (result.name) |byte| std.debug.assert(byte >= 0x20 and byte != '"' and byte != '\\');
        if (index > 0) try writer.writeAll(",");
        const render_ns = result.full_ns -| result.read_ns;
        try writer.print(
            "{{\"name\":\"{s}\",\"size\":{d},\"read_ms\":{d:.3}," ++
                "\"full_ms\":{d:.3},\"render_ms\":{d:.3}}}",
            .{
                result.name,
                result.size,
                @as(f64, @floatFromInt(result.read_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(result.full_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(render_ns)) / std.time.ns_per_ms,
            },
        );
    }
    try writer.writeAll("]}\n");
}
