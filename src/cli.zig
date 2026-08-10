//! The zenfmt command-line front end (ZDS 0002, Command-Line Interface).
//!
//! A separate module beside the umbrella library, so a user filter project
//! reuses the whole CLI: its `main` calls `zenfmt_cli.main` with the pipeline
//! its `pub fn filters` declared, exactly as `cli/src/main.zig` calls it with
//! the empty one. It is deliberately not part of the umbrella, because it
//! reaches process arguments and threaded I/O, and the browser module
//! (ZDS 0015) builds the umbrella for a target that has neither.
//!
//! Argument parsing uses one short-lived arena: flags match a comptime table
//! that also generates `--help`, and parsed values borrow the collected argv
//! slices. Exit codes are `0` success, `1` conversion error, `2` usage error,
//! and `3` limit exceeded — a bulk script wants to treat a zip bomb
//! differently from a malformed document.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const zenfmt = @import("zenfmt");
const zencli = @import("zencli");

const version_text = "zenfmt " ++ @import("zenfmt_build").version ++ "\n";

const exit_ok = zencli.exit_ok;
const exit_conversion = zencli.exit_conversion;
const exit_usage = zencli.exit_usage;
const exit_limit = zencli.exit_limit;

const Flag = zencli.Flag;

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

const help_preamble =
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

/// True when the serve subcommand is compiled in (`-Dserver`, ZDS 0016).
const server_enabled = @import("zenfmt_build").server;

const help_text = zencli.helpText(help_preamble, &flags) ++
    (if (server_enabled)
        "\nzenfmt serve runs the document server; see `zenfmt serve --help`.\n"
    else
        "");

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
    var iterator = try std.process.Args.Iterator.initAllocator(args, arena);
    defer iterator.deinit();
    while (iterator.next()) |arg| try argv.append(arena, try arena.dupe(u8, arg));

    // The subcommand rule (ZDS 0016): a first positional argument of exactly
    // `serve` selects the server; a file named serve is written `./serve`.
    if (comptime server_enabled) {
        if (CliParser.firstPositional(argv.items)) |positional| {
            if (std.mem.eql(u8, positional.arg, "serve")) {
                const server = @import("zenfmt_server");
                var serve_argv: std.ArrayList([]const u8) = .empty;
                try serve_argv.ensureTotalCapacity(arena, argv.items.len - 1);
                for (argv.items, 0..) |arg, index| {
                    if (index == positional.index) continue;
                    serve_argv.appendAssumeCapacity(arg);
                }
                return server.serve_command.main(gpa, io, serve_argv.items, out, err_out);
            }
        }
    }

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
        return zencli.classExitCode(conversion.exit_class);
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

const UsageError = zencli.UsageError;

const CliParser = zencli.Parser(&flags);

/// The zencli sink for the conversion grammar: flags apply through
/// `applyFlag`, and the positional contract is a single input.
const FlagSink = struct {
    cli: *Cli,

    pub fn applyFlag(sink: *FlagSink, name: []const u8, value: ?[]const u8) bool {
        return applyCliFlag(sink.cli, name, value);
    }

    pub fn positional(sink: *FlagSink, arg: []const u8) bool {
        if (sink.cli.input != null) return false;
        sink.cli.input = arg;
        return true;
    }
};

fn parseArgs(argv: []const []const u8, cli: *Cli, parse_error: *?UsageError) void {
    var sink: FlagSink = .{ .cli = cli };
    CliParser.parse(
        argv,
        &sink,
        "I can convert one input per invocation, and this is a second one.",
        parse_error,
    );
}

fn applyCliFlag(cli: *Cli, name: []const u8, value: ?[]const u8) bool {
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

// ---------------------------------------------------------------- tests
//
// The CLI behavior gate (ZDS 0016, The zencli Library): these tests pin the
// observable command-line contract — the generated help text, the parse
// grammar, the exit codes, and the usage diagnostic — so the zencli
// extraction is a refactor gated by byte identity, not a review discussion.

const testing = std.testing;

/// The byte-exact `--help` output.
const help_golden =
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
    \\  -f, --from FORMAT         Input format. Default: from the extension, then from content.
    \\  -t, --to FORMAT           Output format. Default: markdown.
    \\  -o, --output PATH         Output file. Default: INPUT with the new extension.
    \\      --stdout              Write the document to stdout instead of a file.
    \\      --metadata-out PATH   Persist the manifest produced with --stdout.
    \\      --overwrite           Replace existing artifact and manifest paths.
    \\      --preserve-facets     Serialize full facet rows into the manifest.
    \\      --filters             Run the pipeline compiled into this binary.
    \\      --list-formats        Print the registry's readers and writers.
    \\      --list-filters        Print the filters compiled into this binary.
    \\      --strict              Refuse declared loss; grades: content (default), structure, exact.
    \\      --quiet               Suppress notes.
    \\      --reports FORM        text (default) or json.
    \\      --limit NAME=VALUE    Override one resource limit.
    \\  -h, --help                Show this help.
    \\  -V, --version             Show the version.
    \\
;

test "help text matches the golden snapshot" {
    const expected = help_golden ++ (if (server_enabled)
        "\nzenfmt serve runs the document server; see `zenfmt serve --help`.\n"
    else
        "");
    try testing.expectEqualStrings(expected, help_text);
}

test "exit codes are the published contract" {
    try testing.expectEqual(@as(u8, 0), exit_ok);
    try testing.expectEqual(@as(u8, 1), exit_conversion);
    try testing.expectEqual(@as(u8, 2), exit_usage);
    try testing.expectEqual(@as(u8, 3), exit_limit);
}

const Parsed = struct { cli: Cli, err: ?UsageError };

fn testParse(argv: []const []const u8) Parsed {
    var cli: Cli = .{};
    var parse_error: ?UsageError = null;
    parseArgs(argv, &cli, &parse_error);
    return .{ .cli = cli, .err = parse_error };
}

test "parse: defaults with a single input" {
    const parsed = testParse(&.{ "zenfmt", "in.docx" });
    try testing.expectEqual(@as(?UsageError, null), parsed.err);
    try testing.expectEqualStrings("in.docx", parsed.cli.input.?);
    try testing.expectEqual(zenfmt.Strictness.off, parsed.cli.strict);
    try testing.expectEqual(ReportForm.text, parsed.cli.reports_form);
    try testing.expect(!parsed.cli.quiet);
    try testing.expect(!parsed.cli.to_stdout);
    try testing.expectEqual(@as(?[]const u8, null), parsed.cli.from);
    try testing.expectEqual(@as(?[]const u8, null), parsed.cli.to);
}

test "parse: inline and following values are equivalent" {
    const parsed = testParse(&.{ "zenfmt", "--from=docx", "--to", "markdown", "doc.bin" });
    try testing.expectEqual(@as(?UsageError, null), parsed.err);
    try testing.expectEqualStrings("docx", parsed.cli.from.?);
    try testing.expectEqualStrings("markdown", parsed.cli.to.?);
    try testing.expectEqualStrings("doc.bin", parsed.cli.input.?);
}

test "parse: short flags alias their long spellings" {
    const parsed = testParse(&.{ "zenfmt", "-f", "docx", "-t", "markdown", "-o", "out.md", "x" });
    try testing.expectEqual(@as(?UsageError, null), parsed.err);
    try testing.expectEqualStrings("docx", parsed.cli.from.?);
    try testing.expectEqualStrings("markdown", parsed.cli.to.?);
    try testing.expectEqualStrings("out.md", parsed.cli.output.?);
    try testing.expectEqualStrings("x", parsed.cli.input.?);
}

test "parse: bare --strict grades to content and never consumes the next argument" {
    const bare = testParse(&.{ "zenfmt", "--strict", "in.docx" });
    try testing.expectEqual(@as(?UsageError, null), bare.err);
    try testing.expectEqual(zenfmt.Strictness.content, bare.cli.strict);
    try testing.expectEqualStrings("in.docx", bare.cli.input.?);

    const graded = testParse(&.{ "zenfmt", "--strict=exact", "in.docx" });
    try testing.expectEqual(zenfmt.Strictness.exact, graded.cli.strict);

    const structure = testParse(&.{ "zenfmt", "--strict=structure", "in.docx" });
    try testing.expectEqual(zenfmt.Strictness.structure, structure.cli.strict);

    const bad = testParse(&.{ "zenfmt", "--strict=bogus", "in.docx" });
    try testing.expectEqualStrings("I do not recognize this option.", bad.err.?.message);
    try testing.expectEqual(@as(?u32, 1), bad.err.?.highlight);
}

test "parse: boolean flags reject inline values" {
    const quiet = testParse(&.{ "zenfmt", "--quiet=yes", "in.docx" });
    try testing.expectEqualStrings("I do not recognize this option.", quiet.err.?.message);

    const facets = testParse(&.{ "zenfmt", "--preserve-facets=1", "in.docx" });
    try testing.expectEqualStrings("I do not recognize this option.", facets.err.?.message);
}

test "parse: unknown option is highlighted" {
    const parsed = testParse(&.{ "zenfmt", "--nope", "in.docx" });
    try testing.expectEqualStrings("I do not recognize this option.", parsed.err.?.message);
    try testing.expectEqual(@as(?u32, 1), parsed.err.?.highlight);
}

test "parse: a value flag at the end of argv is a usage error" {
    const parsed = testParse(&.{ "zenfmt", "--from" });
    try testing.expectEqualStrings(
        "This option needs a value and none followed it.",
        parsed.err.?.message,
    );
    try testing.expectEqual(@as(?u32, 1), parsed.err.?.highlight);
}

test "parse: a second positional is refused" {
    const parsed = testParse(&.{ "zenfmt", "a.docx", "b.docx" });
    try testing.expectEqualStrings(
        "I can convert one input per invocation, and this is a second one.",
        parsed.err.?.message,
    );
    try testing.expectEqual(@as(?u32, 2), parsed.err.?.highlight);
}

test "parse: --limit overrides one limit and refuses bad ones" {
    const inline_form = testParse(&.{ "zenfmt", "--limit=max_depth=64", "in.docx" });
    try testing.expectEqual(@as(?UsageError, null), inline_form.err);
    try testing.expectEqual(@as(u32, 64), inline_form.cli.limits.max_depth);

    const following = testParse(&.{ "zenfmt", "--limit", "max_depth=64", "in.docx" });
    try testing.expectEqual(@as(u32, 64), following.cli.limits.max_depth);

    const zero = testParse(&.{ "zenfmt", "--limit=max_depth=0", "in.docx" });
    try testing.expectEqualStrings("I do not recognize this option.", zero.err.?.message);

    const unknown = testParse(&.{ "zenfmt", "--limit=nope=1", "in.docx" });
    try testing.expectEqualStrings("I do not recognize this option.", unknown.err.?.message);
}

test "parse: --reports accepts text and json only" {
    const json_form = testParse(&.{ "zenfmt", "--reports", "json", "in.docx" });
    try testing.expectEqual(ReportForm.json, json_form.cli.reports_form);

    const text_form = testParse(&.{ "zenfmt", "--reports=text", "in.docx" });
    try testing.expectEqual(ReportForm.text, text_form.cli.reports_form);

    const bad = testParse(&.{ "zenfmt", "--reports=xml", "in.docx" });
    try testing.expectEqualStrings("I do not recognize this option.", bad.err.?.message);
}

test "parse: `-` is the stdin positional and empty arguments are skipped" {
    const stdin = testParse(&.{ "zenfmt", "-" });
    try testing.expectEqual(@as(?UsageError, null), stdin.err);
    try testing.expectEqualStrings("-", stdin.cli.input.?);

    const empty = testParse(&.{ "zenfmt", "", "in.docx" });
    try testing.expectEqualStrings("in.docx", empty.cli.input.?);
}

test "parse: help and version flags are recognized" {
    try testing.expect(testParse(&.{ "zenfmt", "--help" }).cli.show_help);
    try testing.expect(testParse(&.{ "zenfmt", "-h" }).cli.show_help);
    try testing.expect(testParse(&.{ "zenfmt", "--version" }).cli.show_version);
    try testing.expect(testParse(&.{ "zenfmt", "-V" }).cli.show_version);
}

fn testValidateMessage(cli: *Cli) []const u8 {
    var usage_error: ?UsageError = null;
    const validated = validate(cli, &usage_error);
    testing.expect(validated == null) catch unreachable;
    return usage_error.?.message;
}

test "validate: the five usage rules" {
    var missing: Cli = .{};
    try testing.expect(std.mem.startsWith(
        u8,
        testValidateMessage(&missing),
        "I need an input file to convert.",
    ));

    var stdin_from: Cli = .{ .input = "-" };
    try testing.expect(std.mem.startsWith(
        u8,
        testValidateMessage(&stdin_from),
        "Reading from stdin needs --from,",
    ));

    var stdin_out: Cli = .{ .input = "-", .from = "docx" };
    try testing.expect(std.mem.startsWith(
        u8,
        testValidateMessage(&stdin_out),
        "Reading from stdin needs an output:",
    ));

    var metadata: Cli = .{ .input = "a.docx", .metadata_out = "m.json" };
    try testing.expect(std.mem.startsWith(
        u8,
        testValidateMessage(&metadata),
        "--metadata-out only applies with --stdout;",
    ));

    var conflict: Cli = .{ .input = "a.docx", .to_stdout = true, .output = "o.md" };
    try testing.expect(std.mem.startsWith(
        u8,
        testValidateMessage(&conflict),
        "--stdout and -o conflict;",
    ));
}

test "validate: a plain path and stdin both pass" {
    var usage_error: ?UsageError = null;
    var path: Cli = .{ .input = "a.docx" };
    const validated = validate(&path, &usage_error).?;
    try testing.expectEqualStrings("a.docx", validated.input);
    try testing.expect(!validated.stdin);

    var stdin: Cli = .{ .input = "-", .from = "docx", .to_stdout = true };
    try testing.expect(validate(&stdin, &usage_error).?.stdin);
}

test "derived output path replaces the extension in place" {
    const replaced = try derivedOutputPath(testing.allocator, "dir/report.docx", "md");
    defer testing.allocator.free(replaced);
    try testing.expectEqualStrings("dir/report.md", replaced);

    const gained = try derivedOutputPath(testing.allocator, "notes", "md");
    defer testing.allocator.free(gained);
    try testing.expectEqualStrings("notes.md", gained);
}

test "usage error renders the Elm-style report" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const argv = [_][]const u8{ "zenfmt", "--nope" };
    try renderUsageError(
        testing.allocator,
        .{ .message = "I do not recognize this option.", .highlight = 1 },
        &argv,
        &writer,
    );
    const text = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "I CANNOT UNDERSTAND THIS COMMAND") != null);
    try testing.expect(std.mem.indexOf(u8, text, "I do not recognize this option.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "zenfmt --help") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Nothing was converted.") != null);
}
