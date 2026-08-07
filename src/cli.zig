//! The zenfmt command-line front end (ZDS 0002, Command-Line Interface).
//!
//! Lives in the umbrella library so a user filter project reuses the whole
//! CLI: its `main` calls `zenfmt.cli.main` with the pipeline its
//! `pub fn filters` declared, exactly as `cli/src/main.zig` calls it with
//! the empty one. Argument parsing allocates nothing: flags match a
//! comptime table that also generates `--help`, and values are slices of
//! argv. Exit codes are `0` success, `1` conversion error, `2` usage
//! error, and `3` limit exceeded — a bulk script wants to treat a zip bomb
//! differently from a malformed document.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const zenfmt = @import("root.zig");

const version_text = "zenfmt 0.0.0\n";

const exit_ok: u8 = 0;
const exit_conversion: u8 = 1;
const exit_usage: u8 = 2;
const exit_limit: u8 = 3;

const Flag = struct {
    long: []const u8,
    short: ?[]const u8 = null,
    value: ?[]const u8 = null,
    help: []const u8,
};

/// One table drives parsing and `--help`; they cannot drift apart.
const flags = [_]Flag{
    .{ .long = "--from", .short = "-f", .value = "FORMAT", .help = "Input format. Default: from the extension, then from content." },
    .{ .long = "--to", .short = "-t", .value = "FORMAT", .help = "Output format. Default: markdown." },
    .{ .long = "--output", .short = "-o", .value = "PATH", .help = "Output file. Default: INPUT with the new extension." },
    .{ .long = "--stdout", .help = "Write the document to stdout instead of a file." },
    .{ .long = "--metadata-out", .value = "PATH", .help = "Persist the manifest produced with --stdout." },
    .{ .long = "--overwrite", .help = "Replace existing artifact and manifest paths." },
    .{ .long = "--preserve-facets", .help = "Serialize full facet rows into the manifest." },
    .{ .long = "--filters", .help = "Run the pipeline compiled into this binary." },
    .{ .long = "--list-formats", .help = "Print the registry's readers and writers." },
    .{ .long = "--list-filters", .help = "Print the filters compiled into this binary." },
    .{ .long = "--strict", .help = "Refuse declared loss; grades: content (default), structure, exact." },
    .{ .long = "--quiet", .help = "Suppress notes." },
    .{ .long = "--reports", .value = "FORM", .help = "text (default) or json." },
    .{ .long = "--limit", .value = "NAME=VALUE", .help = "Override one resource limit." },
    .{ .long = "--help", .short = "-h", .help = "Show this help." },
    .{ .long = "--version", .short = "-V", .help = "Show the version." },
};

const help_text = blk: {
    var text: []const u8 =
        \\zenfmt converts documents. The common cases:
        \\
        \\    zenfmt report.docx                 # report.md + report.md.zenfmt.json
        \\    zenfmt report.docx -o notes.md     # notes.md + notes.md.zenfmt.json
        \\    zenfmt report.docx --stdout        # document bytes only on stdout
        \\
        \\usage: zenfmt [options] INPUT
        \\
        \\INPUT is a file path, or `-` for stdin (requires --from and either
        \\-o PATH or --stdout).
        \\
        \\
    ;
    for (flags) |flag| {
        var left: []const u8 = "  ";
        if (flag.short) |short| {
            left = left ++ short ++ ", ";
        } else {
            left = left ++ "    ";
        }
        left = left ++ flag.long;
        if (flag.value) |value| left = left ++ " " ++ value;
        while (left.len < 28) left = left ++ " ";
        text = text ++ left ++ flag.help ++ "\n";
    }
    break :blk text;
};

const ReportForm = enum { text, json };

const Cli = struct {
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    output: ?[]const u8 = null,
    to_stdout: bool = false,
    metadata_out: ?[]const u8 = null,
    overwrite: bool = false,
    preserve_facets: bool = false,
    filters: bool = false,
    list_formats: bool = false,
    list_filters: bool = false,
    strict: zenfmt.Strictness = .off,
    quiet: bool = false,
    reports_form: ReportForm = .text,
    show_help: bool = false,
    show_version: bool = false,
    limits: zenfmt.Limits = .{},
    input: ?[]const u8 = null,
};

pub fn main(init: std.process.Init, compiled: *const zenfmt.Pipeline) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var stderr_buffer: [8 * 1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const err_out = &stderr_writer.interface;

    const code = run(gpa, io, init.minimal.args, out, err_out, compiled) catch |err| blk: {
        err_out.print("zenfmt: unexpected failure: {t}\n", .{err}) catch {};
        break :blk exit_conversion;
    };
    out.flush() catch {};
    err_out.flush() catch {};
    return code;
}

fn run(
    gpa: std.mem.Allocator,
    io: Io,
    args: std.process.Args,
    out: *Io.Writer,
    err_out: *Io.Writer,
    compiled: *const zenfmt.Pipeline,
) !u8 {
    // Collect argv slices once; parsing then borrows them.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    var iterator = std.process.Args.Iterator.init(args);
    defer iterator.deinit();
    while (iterator.next()) |arg| try argv.append(arena, try arena.dupe(u8, arg));

    var cli: Cli = .{};
    var parse_error: ?UsageError = null;
    parseArgs(argv.items, &cli, &parse_error);
    if (parse_error) |usage| {
        try renderUsageError(arena, usage, argv.items, err_out);
        return exit_usage;
    }

    if (cli.show_help) {
        try out.writeAll(help_text);
        return exit_ok;
    }
    if (cli.show_version) {
        try out.writeAll(version_text);
        return exit_ok;
    }
    if (cli.list_formats) {
        try listFormats(out);
        return exit_ok;
    }
    if (cli.list_filters) {
        try listFilters(compiled, out);
        return exit_ok;
    }

    var usage_error: ?UsageError = null;
    const validated = validate(&cli, &usage_error) orelse {
        try renderUsageError(arena, usage_error.?, argv.items, err_out);
        return exit_usage;
    };

    var spill_path: ?[]const u8 = null;
    defer if (spill_path) |path| Io.Dir.cwd().deleteFile(io, path) catch {};
    const options = (try buildOptions(arena, io, validated, cli, out, err_out, &spill_path)) orelse
        return exit_usage;

    var options_with_pipeline = options;
    if (cli.filters) options_with_pipeline.pipeline = compiled;
    var conversion = zenfmt.convert(gpa, io, options_with_pipeline);
    defer conversion.deinit(gpa);

    // Reports go to stderr in the selected form; stdout carries only the
    // document.
    switch (cli.reports_form) {
        .text => {
            const color = Io.File.stderr().supportsAnsiEscapeCodes(io) catch false;
            try conversion.renderReports(err_out, .{ .quiet = cli.quiet, .color = color });
        },
        .json => try renderReportsJson(arena, conversion.reports, cli.quiet, err_out),
    }

    if (conversion.status == .failed) {
        return switch (conversion.exit_class) {
            .usage => exit_usage,
            .limit => exit_limit,
            .conversion => exit_conversion,
        };
    }

    if (cli.metadata_out) |path| {
        assert(cli.to_stdout);
        const manifest_json = conversion.manifest_json.?;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = manifest_json }) catch |err| {
            try err_out.print("zenfmt: cannot write {s}: {t}\n", .{ path, err });
            return exit_conversion;
        };
    }
    return exit_ok;
}

// -------------------------------------------------------------- parsing

const UsageError = struct {
    message: []const u8,
    /// Index into argv of the offending argument, when one exists.
    highlight: ?u32 = null,
};

fn parseArgs(argv: []const []const u8, cli: *Cli, parse_error: *?UsageError) void {
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (arg.len == 0) continue;
        if (arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            if (cli.input != null) {
                parse_error.* = .{
                    .message = "I can convert one input per invocation, and this is a second one.",
                    .highlight = @intCast(i),
                };
                return;
            }
            cli.input = arg;
            continue;
        }

        // `--flag=value` splits into name and inline value.
        const equals = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (equals) |index| arg[0..index] else arg;
        const inline_value = if (equals) |index| arg[index + 1 ..] else null;

        const value: ?[]const u8, const consumed_next: bool = blk: {
            // A flag that takes no value still accepts an inline one when
            // it is graded, like `--strict=exact`; `applyFlag` decides.
            if (!flagTakesValue(name)) break :blk .{ inline_value, false };
            if (inline_value) |v| break :blk .{ v, false };
            if (i + 1 < argv.len) break :blk .{ argv[i + 1], true };
            parse_error.* = .{
                .message = "This option needs a value and none followed it.",
                .highlight = @intCast(i),
            };
            return;
        };

        if (!applyFlag(cli, name, value)) {
            parse_error.* = .{
                .message = "I do not recognize this option.",
                .highlight = @intCast(i),
            };
            return;
        }
        if (consumed_next) i += 1;
    }
}

fn flagTakesValue(name: []const u8) bool {
    inline for (flags) |flag| {
        if (flag.value != null) {
            if (std.mem.eql(u8, name, flag.long)) return true;
            if (flag.short) |short| if (std.mem.eql(u8, name, short)) return true;
        }
    }
    return false;
}

fn applyFlag(cli: *Cli, name: []const u8, value: ?[]const u8) bool {
    if (matches(name, "--from", "-f")) {
        cli.from = value.?;
    } else if (matches(name, "--to", "-t")) {
        cli.to = value.?;
    } else if (matches(name, "--output", "-o")) {
        cli.output = value.?;
    } else if (matches(name, "--stdout", null)) {
        cli.to_stdout = true;
    } else if (matches(name, "--metadata-out", null)) {
        cli.metadata_out = value.?;
    } else if (matches(name, "--overwrite", null)) {
        cli.overwrite = true;
    } else if (matches(name, "--preserve-facets", null)) {
        if (value != null) return false;
        cli.preserve_facets = true;
    } else if (matches(name, "--filters", null)) {
        cli.filters = true;
    } else if (matches(name, "--list-formats", null)) {
        cli.list_formats = true;
    } else if (matches(name, "--list-filters", null)) {
        cli.list_filters = true;
    } else if (matches(name, "--strict", null)) {
        if (value) |grade| {
            cli.strict = zenfmt.Strictness.parse(grade) orelse return false;
        } else {
            cli.strict = .content;
        }
    } else if (matches(name, "--quiet", null)) {
        if (value != null) return false;
        cli.quiet = true;
    } else if (matches(name, "--reports", null)) {
        if (std.mem.eql(u8, value.?, "json")) {
            cli.reports_form = .json;
        } else if (std.mem.eql(u8, value.?, "text")) {
            cli.reports_form = .text;
        } else {
            return false;
        }
    } else if (matches(name, "--limit", null)) {
        cli.limits.override(value.?) catch return false;
    } else if (matches(name, "--help", "-h")) {
        cli.show_help = true;
    } else if (matches(name, "--version", "-V")) {
        cli.show_version = true;
    } else {
        return false;
    }
    return true;
}

fn matches(name: []const u8, long: []const u8, short: ?[]const u8) bool {
    if (std.mem.eql(u8, name, long)) return true;
    if (short) |s| return std.mem.eql(u8, name, s);
    return false;
}

const Validated = struct {
    input: []const u8,
    stdin: bool,
};

fn validate(cli: *Cli, usage_error: *?UsageError) ?Validated {
    const input = cli.input orelse {
        usage_error.* = .{ .message = "I need an input file to convert. " ++
            "Pass a path, or `-` to read stdin." };
        return null;
    };
    const stdin = std.mem.eql(u8, input, "-");
    if (stdin and cli.from == null) {
        usage_error.* = .{ .message = "Reading from stdin needs --from, " ++
            "because there is no file name to detect the format from." };
        return null;
    }
    if (stdin and cli.output == null and !cli.to_stdout) {
        usage_error.* = .{ .message = "Reading from stdin needs an output: " ++
            "pass -o PATH or --stdout." };
        return null;
    }
    if (cli.metadata_out != null and !cli.to_stdout) {
        usage_error.* = .{ .message = "--metadata-out only applies with " ++
            "--stdout; a path output always writes its manifest beside " ++
            "the artifact." };
        return null;
    }
    if (cli.to_stdout and cli.output != null) {
        usage_error.* = .{ .message = "--stdout and -o conflict; pick one " ++
            "destination." };
        return null;
    }
    return .{ .input = input, .stdin = stdin };
}

/// True when the `--from` format's reader wants seekable input, so a
/// stdin conversion spills to a temporary file.
fn stdinSpillsToFile(from: []const u8) bool {
    for (zenfmt.Default.readers) |descriptor| {
        if (std.mem.eql(u8, descriptor.format, from)) {
            return descriptor.input == .seekable;
        }
    }
    return false;
}

fn buildOptions(
    arena: std.mem.Allocator,
    io: Io,
    validated: Validated,
    cli: Cli,
    out: *Io.Writer,
    err_out: *Io.Writer,
    spill_path: *?[]const u8,
) !?zenfmt.ConvertOptions {
    const input_spec: zenfmt.InputSpec = if (validated.stdin) blk: {
        var stdin_buffer: [16 * 1024]u8 = undefined;
        var stdin_reader = Io.File.stdin().readerStreaming(io, &stdin_buffer);
        const bytes = stdin_reader.interface.allocRemaining(
            arena,
            .limited(cli.limits.max_input_bytes + 1),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                try err_out.writeAll("zenfmt: stdin exceeds the input size limit\n");
                return null;
            },
            else => return err,
        };
        // A seekable format spills to a temporary file (ZDS 0013, Core
        // Contract Repairs): the reader windows the file instead of the
        // engine holding the pipe's whole contents twice.
        if (stdinSpillsToFile(cli.from.?)) {
            var suffix: [8]u8 = undefined;
            io.random(&suffix);
            const path = try std.fmt.allocPrint(
                arena,
                ".zenfmt-stdin-{x}.tmp",
                .{&suffix},
            );
            Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch {
                try err_out.writeAll("zenfmt: could not spill stdin to a temporary file\n");
                return null;
            };
            spill_path.* = path;
            break :blk .{ .path = path };
        }
        break :blk .{ .bytes = .{ .name = "stdin", .data = bytes } };
    } else .{ .path = validated.input };

    const output_spec: zenfmt.OutputSpec = if (cli.to_stdout)
        .{ .writer = out }
    else if (cli.output) |path|
        .{ .path = path }
    else blk: {
        const to = cli.to orelse zenfmt.default_output_format;
        const extension = zenfmt.Default.primaryExtension(to) orelse "out";
        break :blk .{ .path = try derivedOutputPath(arena, validated.input, extension) };
    };

    return .{
        .input = input_spec,
        .output = output_spec,
        .from = cli.from,
        .to = cli.to,
        .limits = cli.limits,
        .overwrite = cli.overwrite,
        .preserve_facets = cli.preserve_facets,
        .strict = cli.strict,
    };
}

/// `dir/report.docx` becomes `dir/report.md`; an extensionless input gains
/// the extension.
fn derivedOutputPath(
    arena: std.mem.Allocator,
    input: []const u8,
    extension: []const u8,
) ![]const u8 {
    const basename = std.fs.path.basename(input);
    const stem_len = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |index|
        input.len - (basename.len - index)
    else
        input.len;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ input[0..stem_len], extension });
}

fn listFilters(compiled: *const zenfmt.Pipeline, out: *Io.Writer) !void {
    const stages = compiled.stageDescriptors();
    if (stages.len == 0) {
        try out.writeAll("No filters are compiled into this binary.\n");
        return;
    }
    try out.writeAll("Filters, in pipeline order:\n");
    for (stages) |stage| {
        try out.print("  {s}  {s}\n", .{
            stage.descriptor.id,
            stage.descriptor.description,
        });
    }
}

fn listFormats(out: *Io.Writer) !void {
    try out.writeAll("Readers:\n");
    inline for (zenfmt.Default.readers) |descriptor| {
        try out.print("  {s}", .{descriptor.format});
        for (descriptor.extensions) |extension| try out.print(" .{s}", .{extension});
        try out.writeAll("\n");
    }
    try out.writeAll("Writers:\n");
    inline for (zenfmt.Default.writers) |descriptor| {
        try out.print("  {s}", .{descriptor.format});
        for (descriptor.extensions) |extension| try out.print(" .{s}", .{extension});
        try out.writeAll("\n");
    }
}

fn renderUsageError(
    arena: std.mem.Allocator,
    usage: UsageError,
    argv: []const []const u8,
    err_out: *Io.Writer,
) !void {
    const context: ?zenfmt.report.Context = if (usage.highlight) |index| .{
        .argv = .{ .args = argv, .highlight = index },
    } else null;
    const usage_report: zenfmt.Report = .{
        .severity = .err,
        .code = "cli.usage",
        .title = "I CANNOT UNDERSTAND THIS COMMAND",
        .problem = usage.message,
        .consequence = "Nothing was converted.",
        .context = context,
        .exit_class = .usage,
        .directions = &.{.{
            .title = "See the options",
            .explanation = "Run `zenfmt --help` for the options and the " ++
                "common invocations.",
        }},
    };
    _ = arena;
    try zenfmt.report.renderText(&.{usage_report}, err_out, .{});
}

fn renderReportsJson(
    arena: std.mem.Allocator,
    reports: []const zenfmt.Report,
    quiet: bool,
    err_out: *Io.Writer,
) !void {
    for (reports) |item| {
        if (quiet and item.severity == .note) continue;
        var stream = zenfmt.json.WriteStream.init(arena);
        defer stream.deinit();
        try zenfmt.report.writeJson(item, &stream);
        const bytes = try stream.toOwnedSlice();
        defer arena.free(bytes);
        try err_out.writeAll(bytes);
        try err_out.writeAll("\n");
    }
}
