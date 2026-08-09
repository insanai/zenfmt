//! The zenfmt conversion benchmark (paxos-zig pattern: `zig build benchmark`).
//!
//! Runs every converter that supports a corpus file — zenfmt, pandoc, and
//! firecrawl's anydoc — as a child process, and measures wall-clock latency,
//! CPU time (user + system), and peak resident set size from the child's
//! `wait4` rusage. Each measurement is the median of `--iterations` runs
//! after one warm-up. Results land in `benchmarks/results/results.md`.
//!
//! Fairness notes: every tool converts file → GitHub-Flavored Markdown to a
//! discarded output, spawned the way its documentation recommends; anydoc's
//! Node.js startup is part of its real invocation cost and is measured, as
//! is pandoc's Haskell runtime startup and zenfmt's process startup.

const std = @import("std");
const Io = std.Io;

const max_corpus_files = 128;
const max_iterations = 64;

const Options = struct {
    zenfmt: []const u8 = "zig-out/bin/zenfmt",
    pandoc: []const u8 = "pandoc",
    anydoc: []const u8 = "benchmarks/.anydoc/node_modules/.bin/anydoc",
    python: []const u8 = "benchmarks/.venv-wheel/bin/python",
    corpus: []const u8 = "benchmarks/corpus",
    out: []const u8 = "benchmarks/results/results.md",
    iterations: u32 = 5,
    version: []const u8 = "unknown",
    revision: []const u8 = "unknown",
};

/// The zenfmt reader extension set, shared by the CLI row and the
/// installed-wheel row: the wheel bundles the identical engine, so its
/// support table is the same by construction (ZDS 0014).
const zenfmt_extensions: []const []const u8 = &.{
    "txt",  "md",   "markdown", "csv",  "docx", "docm", "rtf",
    "xlsx", "xlsm", "odt",      "pptx", "pptm", "ppsx", "ppsm",
    "html", "htm",  "adoc",     "rst",  "ods",  "odp",  "epub",
    "pdf",  "doc",  "xls",      "ppt",  "pps",  "pot",  "xlsb",
};

const Tool = enum {
    zenfmt,
    pandoc,
    anydoc,
    zenfmt_python,

    fn name(tool: Tool) []const u8 {
        return switch (tool) {
            .zenfmt_python => "zenfmt-python-wheel",
            else => @tagName(tool),
        };
    }

    /// Which input extensions each tool's reader set accepts, per its own
    /// documentation. A tool never runs on a file it does not support; the
    /// support matrix itself is one of the benchmark's results.
    fn supports(tool: Tool, extension: []const u8) bool {
        const table: []const []const u8 = switch (tool) {
            .zenfmt, .zenfmt_python => zenfmt_extensions,
            .pandoc => &.{
                "docx", "odt", "epub", "html", "htm", "csv", "rtf", "rst", "md", "markdown",
            },
            .anydoc => &.{
                "doc",  "docx", "docm", "ppt", "pps",  "pot",  "pptx",
                "pptm", "ppsx", "ppsm", "xls", "xlsx", "xlsm", "xlsb",
                "odt",  "ods",  "odp",  "rtf", "epub", "csv",  "pdf",
            },
        };
        for (table) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate, extension)) return true;
        }
        return false;
    }
};

const tool_count = std.meta.tags(Tool).len;

const Sample = struct {
    wall_ns: u64,
    cpu_ns: u64,
    max_rss: u64,
    ok: bool,
};

const Measurement = struct {
    tool: Tool,
    wall_ns: u64,
    cpu_ns: u64,
    max_rss: u64,
    ok: bool,
    supported: bool,
};

const FileResult = struct {
    name: []const u8,
    size: u64,
    measurements: [tool_count]Measurement,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var options = Options{};
    parseArgs(init.minimal.args, &options);
    std.debug.assert(options.iterations >= 1);
    std.debug.assert(options.iterations <= max_iterations);

    const names = try corpusFiles(gpa, io, options.corpus);
    defer gpa.free(names);
    if (names.len == 0) {
        std.debug.print(
            "benchmark: no corpus files in {s}; run benchmarks/fetch_corpus.sh first\n",
            .{options.corpus},
        );
        return 1;
    }

    var results: std.ArrayList(FileResult) = .empty;
    defer results.deinit(gpa);
    for (names) |file_name| {
        const result = try benchmarkFile(gpa, io, &options, file_name);
        try results.append(gpa, result);
        std.debug.print("done {s}\n", .{file_name});
    }

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    try renderReport(&report.writer, results.items, options.iterations);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = options.out, .data = report.written() }) catch |err| {
        std.debug.print("benchmark: cannot write {s}: {t}\n", .{ options.out, err });
        return 1;
    };

    // The machine-readable twin: the book's benchmark chapter renders its
    // charts from this file, in the manner of paxos-zig's dashboard.
    var machine: std.Io.Writer.Allocating = .init(gpa);
    defer machine.deinit();
    try renderJson(
        &machine.writer,
        results.items,
        options.iterations,
        options.version,
        options.revision,
    );
    const json_path = "benchmarks/results/latest.json";
    Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = machine.written() }) catch |err| {
        std.debug.print("benchmark: cannot write {s}: {t}\n", .{ json_path, err });
        return 1;
    };

    std.debug.print("\n{s}\nwritten to {s} and {s}\n", .{ report.written(), options.out, json_path });
    return 0;
}

/// `latest.json`: everything the report tables carry, as data. File and
/// tool names in this corpus are plain ASCII, asserted rather than escaped.
fn renderJson(
    writer: *std.Io.Writer,
    results: []const FileResult,
    iterations: u32,
    version: []const u8,
    revision: []const u8,
) !void {
    try writer.print(
        "{{\"version\":\"{s}\",\"git_revision\":\"{s}\"," ++
            "\"iterations\":{d},\"files\":[",
        .{ version, revision, iterations },
    );
    for (results, 0..) |result, file_index| {
        for (result.name) |byte| std.debug.assert(byte >= 0x20 and byte != '"' and byte != '\\');
        if (file_index > 0) try writer.writeAll(",");
        try writer.print("{{\"name\":\"{s}\",\"size\":{d},\"tools\":[", .{ result.name, result.size });
        for (result.measurements, 0..) |m, tool_index| {
            if (tool_index > 0) try writer.writeAll(",");
            try writer.print(
                "{{\"tool\":\"{s}\",\"supported\":{},\"ok\":{},\"wall_ms\":{d:.2}," ++
                    "\"cpu_ms\":{d:.2},\"max_rss_mb\":{d:.2}}}",
                .{
                    m.tool.name(),
                    m.supported,
                    m.ok,
                    @as(f64, @floatFromInt(m.wall_ns)) / std.time.ns_per_ms,
                    @as(f64, @floatFromInt(m.cpu_ns)) / std.time.ns_per_ms,
                    @as(f64, @floatFromInt(m.max_rss)) / (1024 * 1024),
                },
            );
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]}\n");
}

fn parseArgs(args: std.process.Args, options: *Options) void {
    var iterator = std.process.Args.Iterator.init(args);
    _ = iterator.next(); // program name
    while (iterator.next()) |arg| {
        const flags = [_]struct { name: []const u8, slot: *[]const u8 }{
            .{ .name = "--zenfmt", .slot = &options.zenfmt },
            .{ .name = "--pandoc", .slot = &options.pandoc },
            .{ .name = "--anydoc", .slot = &options.anydoc },
            .{ .name = "--python", .slot = &options.python },
            .{ .name = "--corpus", .slot = &options.corpus },
            .{ .name = "--out", .slot = &options.out },
            .{ .name = "--version", .slot = &options.version },
            .{ .name = "--revision", .slot = &options.revision },
        };
        var matched = false;
        for (flags) |flag| {
            if (std.mem.eql(u8, arg, flag.name)) {
                flag.slot.* = iterator.next() orelse fatal(flag.name);
                matched = true;
            }
        }
        if (matched) continue;
        if (std.mem.eql(u8, arg, "--iterations")) {
            const value = iterator.next() orelse fatal(arg);
            options.iterations = std.fmt.parseInt(u32, value, 10) catch fatal(arg);
            continue;
        }
        fatal(arg);
    }
}

fn fatal(flag: []const u8) noreturn {
    std.debug.print("benchmark: bad or incomplete argument near {s}\n", .{flag});
    std.process.exit(2);
}

/// Sorted corpus file names; hidden files and partial downloads excluded.
fn corpusFiles(gpa: std.mem.Allocator, io: Io, corpus: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    var dir = Io.Dir.cwd().openDir(io, corpus, .{ .iterate = true }) catch return &.{};
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

fn benchmarkFile(
    gpa: std.mem.Allocator,
    io: Io,
    options: *const Options,
    file_name: []const u8,
) !FileResult {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ options.corpus, file_name });
    defer gpa.free(path);
    const extension = if (std.mem.lastIndexOfScalar(u8, file_name, '.')) |dot|
        file_name[dot + 1 ..]
    else
        "";
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch null;

    var result = FileResult{
        .name = try gpa.dupe(u8, file_name),
        .size = if (stat) |value| value.size else 0,
        .measurements = undefined,
    };
    inline for (std.meta.tags(Tool), 0..) |tool, index| {
        result.measurements[index] = try benchmarkTool(gpa, io, options, tool, path, extension);
    }
    return result;
}

fn benchmarkTool(
    gpa: std.mem.Allocator,
    io: Io,
    options: *const Options,
    tool: Tool,
    path: []const u8,
    extension: []const u8,
) !Measurement {
    var measurement = Measurement{
        .tool = tool,
        .wall_ns = 0,
        .cpu_ns = 0,
        .max_rss = 0,
        .ok = false,
        .supported = Tool.supports(tool, extension),
    };
    if (!measurement.supported) return measurement;

    const argv: []const []const u8 = switch (tool) {
        .zenfmt => &.{ options.zenfmt, path, "--stdout", "--quiet" },
        .pandoc => &.{ options.pandoc, path, "-t", "gfm", "-o", "/dev/null" },
        .anydoc => &.{ options.anydoc, path, "-o", "/dev/null" },
        // A fresh interpreter per run: the installed wheel's cold row,
        // directly comparable to the CLI child-process row. `-I` keeps the
        // checkout off sys.path so only the clean-installed wheel runs.
        .zenfmt_python => &.{
            options.python, "-I", "python/benchmarks/python_api.py", "--convert", path,
        },
    };

    _ = runOnce(io, argv) catch return measurement; // warm-up
    var samples: [max_iterations]Sample = undefined;
    var count: u32 = 0;
    while (count < options.iterations) : (count += 1) {
        samples[count] = runOnce(io, argv) catch return measurement;
        if (!samples[count].ok) return measurement;
    }

    measurement.ok = true;
    measurement.wall_ns = medianOf(samples[0..count], "wall_ns");
    measurement.cpu_ns = medianOf(samples[0..count], "cpu_ns");
    measurement.max_rss = medianOf(samples[0..count], "max_rss");
    _ = gpa;
    return measurement;
}

fn runOnce(io: Io, argv: []const []const u8) !Sample {
    const started = Io.Clock.Timestamp.now(io, .awake);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .request_resource_usage_statistics = true,
    });
    const term = try child.wait(io);
    const elapsed = started.durationTo(Io.Clock.Timestamp.now(io, .awake));
    const wall_ns: u64 = @intCast(@max(elapsed.raw.nanoseconds, 0));

    var cpu_ns: u64 = 0;
    var max_rss: u64 = 0;
    if (child.resource_usage_statistics.rusage) |usage| {
        cpu_ns = timevalNs(usage.utime) + timevalNs(usage.stime);
    }
    if (child.resource_usage_statistics.getMaxRss()) |rss| max_rss = rss;
    return .{
        .wall_ns = wall_ns,
        .cpu_ns = cpu_ns,
        .max_rss = max_rss,
        .ok = term == .exited and term.exited == 0,
    };
}

fn timevalNs(value: anytype) u64 {
    const sec: u64 = @intCast(@max(value.sec, 0));
    const usec: u64 = @intCast(@max(value.usec, 0));
    return sec * std.time.ns_per_s + usec * std.time.ns_per_us;
}

fn medianOf(samples: []Sample, comptime field: []const u8) u64 {
    std.debug.assert(samples.len >= 1);
    var values: [max_iterations]u64 = undefined;
    for (samples, 0..) |sample, index| values[index] = @field(sample, field);
    std.mem.sort(u64, values[0..samples.len], {}, std.sort.asc(u64));
    return values[samples.len / 2];
}

// ------------------------------------------------------------- reporting

fn renderReport(
    writer: *std.Io.Writer,
    results: []const FileResult,
    iterations: u32,
) !void {
    try writer.print(
        "# zenfmt conversion benchmark\n\n" ++
            "Median of {d} runs per tool per file (one discarded warm-up); child\n" ++
            "process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.\n" ++
            "`unsupported` means the tool's documentation lists no reader for the\n" ++
            "format; `failed` means it exited non-zero.\n\n",
        .{iterations},
    );

    try writer.writeAll(
        "| file | size | tool | wall ms | cpu ms | peak RSS MB |\n" ++
            "|---|---:|---|---:|---:|---:|\n",
    );
    for (results) |result| {
        for (result.measurements, 0..) |m, index| {
            if (index == 0) {
                try writer.print("| {s} | {Bi} ", .{ result.name, result.size });
            } else {
                try writer.writeAll("| | ");
            }
            if (!m.supported) {
                try writer.print("| {s} | unsupported | | |\n", .{m.tool.name()});
            } else if (!m.ok) {
                try writer.print("| {s} | failed | | |\n", .{m.tool.name()});
            } else {
                try writer.print("| {s} | {d}.{d:0>1} | {d}.{d:0>1} | {d}.{d:0>1} |\n", .{
                    m.tool.name(),
                    m.wall_ns / std.time.ns_per_ms,
                    (m.wall_ns % std.time.ns_per_ms) / (std.time.ns_per_ms / 10),
                    m.cpu_ns / std.time.ns_per_ms,
                    (m.cpu_ns % std.time.ns_per_ms) / (std.time.ns_per_ms / 10),
                    m.max_rss / (1024 * 1024),
                    (m.max_rss % (1024 * 1024)) / (1024 * 1024 / 10),
                });
            }
        }
    }

    try summarize(writer, results);
}

/// Support counts plus head-to-head geometric means over the files both
/// tools converted successfully.
fn summarize(writer: *std.Io.Writer, results: []const FileResult) !void {
    try writer.writeAll("\n## Support matrix\n\n| tool | converted | of corpus |\n|---|---:|---:|\n");
    inline for (std.meta.tags(Tool), 0..) |tool, index| {
        var converted: u32 = 0;
        for (results) |result| {
            if (result.measurements[index].ok) converted += 1;
        }
        try writer.print(
            "| {s} | {d} | {d} |\n",
            .{ tool.name(), converted, results.len },
        );
    }

    try writer.writeAll(
        "\n## Head to head (geometric mean over commonly-converted files)\n\n" ++
            "| pair | files | wall | cpu | peak RSS |\n|---|---:|---:|---:|---:|\n",
    );
    const pairs = [_][2]usize{ .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 } };
    for (pairs) |pair| {
        var log_wall: f64 = 0;
        var log_cpu: f64 = 0;
        var log_rss: f64 = 0;
        var shared: u32 = 0;
        for (results) |result| {
            const ours = result.measurements[pair[0]];
            const theirs = result.measurements[pair[1]];
            if (!ours.ok or !theirs.ok) continue;
            shared += 1;
            log_wall += ratioLog(theirs.wall_ns, ours.wall_ns);
            log_cpu += ratioLog(theirs.cpu_ns, ours.cpu_ns);
            log_rss += ratioLog(theirs.max_rss, ours.max_rss);
        }
        const other = results[0].measurements[pair[1]].tool;
        if (shared == 0) {
            try writer.print("| zenfmt vs {s} | 0 | — | — | — |\n", .{other.name()});
            continue;
        }
        const n: f64 = @floatFromInt(shared);
        try writer.print(
            "| zenfmt vs {s} | {d} | {d:.1}x | {d:.1}x | {d:.1}x |\n",
            .{
                other.name(),
                shared,
                @exp(log_wall / n),
                @exp(log_cpu / n),
                @exp(log_rss / n),
            },
        );
    }
    try writer.writeAll(
        "\nRatios are the other tool's median divided by zenfmt's: above 1.0" ++
            " means zenfmt is faster or smaller on the shared files.\n",
    );
}

fn ratioLog(theirs: u64, ours: u64) f64 {
    const numerator: f64 = @floatFromInt(@max(theirs, 1));
    const denominator: f64 = @floatFromInt(@max(ours, 1));
    return @log(numerator / denominator);
}
