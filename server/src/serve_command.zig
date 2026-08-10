//! The `zenfmt serve` grammar (ZDS 0016, The CLI Surface).
//!
//! The serve flag table declares through zencli exactly as the conversion
//! grammar does: one table drives parsing and `zenfmt serve --help`. The
//! umbrella CLI dispatches here when the first positional argument is
//! exactly `serve`; everything after that token parses against this table.

const std = @import("std");
const zencli = @import("zencli");
const zenfmt = @import("zenfmt");

const root = @import("root.zig");

const version_text = "zenfmt " ++ @import("zenfmt_build").version ++ "\n";

const Flag = zencli.Flag;

const flags = [_]Flag{
    .{ .long = "--address", .value = "ADDR", .help = "Bind address. Default: 127.0.0.1." },
    .{ .long = "--port", .value = "N", .help = "Bind port. Default: 8998." },
    .{ .long = "--secure", .help = "Enable accounts, sessions, keys, and audit." },
    .{
        .long = "--data-dir",
        .value = "PATH",
        .help = "Store directory; required with --secure.",
    },
    .{
        .long = "--behind-proxy",
        .help = "Assert TLS termination and mark session cookies Secure.",
    },
    .{
        .long = "--allow-insecure-network",
        .help = "Allow cleartext secure mode on a non-loopback bind.",
    },
    .{
        .long = "--max-body",
        .value = "BYTES",
        .help = "Request body cap; accepts KiB/MiB/GiB. Default: 64MiB.",
    },
    .{
        .long = "--connections",
        .value = "N",
        .help = "Connection slots. Default: 128.",
    },
    .{
        .long = "--conversions",
        .value = "N",
        .help = "Concurrent conversion cap. Default: logical CPUs.",
    },
    .{
        .long = "--limit",
        .value = "NAME=VALUE",
        .help = "Override one engine limit, repeatable.",
    },
    .{
        .long = "--log-format",
        .value = "FMT",
        .help = "text (default) or json.",
    },
    .{
        .long = "--log-level",
        .value = "LEVEL",
        .help = "err, warn, info (default), or debug.",
    },
    .{ .long = "--no-ui", .help = "Serve the API and operational plane only." },
    .{
        .long = "--drain-seconds",
        .value = "N",
        .help = "Graceful shutdown deadline. Default: 30.",
    },
    .{ .long = "--help", .short = "-h", .help = "Show this help." },
    .{ .long = "--version", .short = "-V", .help = "Show the version." },
};

const help_preamble =
    \\zenfmt serve runs the zenfmt server (ZDS 0016). The common cases:
    \\
    \\    zenfmt serve                                     # open mode on 127.0.0.1:8998
    \\    zenfmt serve --port 9000 --max-body 256MiB
    \\    zenfmt serve --secure --data-dir /var/lib/zenfmt --behind-proxy
    \\
    \\usage: zenfmt serve [options]
    \\
    \\Open mode converts anonymously and keeps no state. Secure mode adds
    \\accounts, sessions, API keys, and an audit trail in an embedded store.
    \\
    \\
;

const help_text = zencli.helpText(help_preamble, &flags);

const Parsed = struct {
    options: root.Options,
    show_help: bool = false,
    show_version: bool = false,
};

const ServeParser = zencli.Parser(&flags);

const Sink = struct {
    parsed: *Parsed,

    pub fn applyFlag(sink: *Sink, name: []const u8, value: ?[]const u8) bool {
        return applyServeFlag(sink.parsed, name, value);
    }

    pub fn positional(sink: *Sink, arg: []const u8) bool {
        _ = sink;
        _ = arg;
        return false;
    }
};

/// Parses and runs `zenfmt serve`; `argv` is the full process argv with the
/// `serve` token removed. Returns the process exit code.
pub fn main(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) u8 {
    var parsed: Parsed = .{ .options = .{} };
    var sink: Sink = .{ .parsed = &parsed };
    var parse_error: ?zencli.UsageError = null;
    ServeParser.parse(
        argv,
        &sink,
        "The serve subcommand takes no positional arguments.",
        &parse_error,
    );
    if (parse_error == null) validate(&parsed, &parse_error);
    if (parse_error) |usage| {
        renderUsageError(usage, argv, err_out) catch {};
        return zencli.exit_usage;
    }
    if (parsed.show_help) {
        out.writeAll(help_text) catch return zencli.exit_conversion;
        return zencli.exit_ok;
    }
    if (parsed.show_version) {
        out.writeAll(version_text) catch return zencli.exit_conversion;
        return zencli.exit_ok;
    }
    return root.run(gpa, io, parsed.options, err_out);
}

fn applyServeFlag(parsed: *Parsed, name: []const u8, value: ?[]const u8) bool {
    const options = &parsed.options;
    if (matches(name, "--address")) {
        options.address = value.?;
    } else if (matches(name, "--port")) {
        options.port = std.fmt.parseInt(u16, value.?, 10) catch return false;
    } else if (matches(name, "--secure")) {
        if (value != null) return false;
        options.secure = true;
    } else if (matches(name, "--data-dir")) {
        options.data_dir = value.?;
    } else if (matches(name, "--behind-proxy")) {
        if (value != null) return false;
        options.behind_proxy = true;
    } else if (matches(name, "--allow-insecure-network")) {
        if (value != null) return false;
        options.allow_insecure_network = true;
    } else if (matches(name, "--max-body")) {
        options.max_body_bytes = parseBytes(value.?) orelse return false;
    } else if (matches(name, "--connections")) {
        const n = std.fmt.parseInt(u32, value.?, 10) catch return false;
        if (n == 0 or n > 128) return false;
        options.connections = n;
    } else if (matches(name, "--conversions")) {
        const n = std.fmt.parseInt(u32, value.?, 10) catch return false;
        if (n == 0) return false;
        options.conversions = n;
    } else if (matches(name, "--limit")) {
        options.limits.override(value.?) catch return false;
    } else if (matches(name, "--log-format")) {
        if (std.mem.eql(u8, value.?, "text")) {
            options.log_format = .text;
        } else if (std.mem.eql(u8, value.?, "json")) {
            options.log_format = .json;
        } else return false;
    } else if (matches(name, "--log-level")) {
        options.log_level = parseLogLevel(value.?) orelse return false;
    } else if (matches(name, "--no-ui")) {
        if (value != null) return false;
        options.ui = false;
    } else if (matches(name, "--drain-seconds")) {
        options.drain_seconds = std.fmt.parseInt(u32, value.?, 10) catch return false;
    } else if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
        parsed.show_help = true;
    } else if (std.mem.eql(u8, name, "--version") or std.mem.eql(u8, name, "-V")) {
        parsed.show_version = true;
    } else {
        return false;
    }
    return true;
}

fn matches(name: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, name, long);
}

fn parseLogLevel(text: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, text, "err")) return .err;
    if (std.mem.eql(u8, text, "warn")) return .warn;
    if (std.mem.eql(u8, text, "info")) return .info;
    if (std.mem.eql(u8, text, "debug")) return .debug;
    return null;
}

/// Parses a byte count with an optional binary suffix: `1048576`, `64KiB`,
/// `256MiB`, `1GiB`.
fn parseBytes(text: []const u8) ?u64 {
    var digits: usize = 0;
    while (digits < text.len and text[digits] >= '0' and text[digits] <= '9') digits += 1;
    if (digits == 0) return null;
    const value = std.fmt.parseInt(u64, text[0..digits], 10) catch return null;
    const suffix = text[digits..];
    const multiplier: u64 = if (suffix.len == 0)
        1
    else if (std.mem.eql(u8, suffix, "KiB"))
        1024
    else if (std.mem.eql(u8, suffix, "MiB"))
        1024 * 1024
    else if (std.mem.eql(u8, suffix, "GiB"))
        1024 * 1024 * 1024
    else
        return null;
    if (value > std.math.maxInt(u64) / multiplier) return null;
    const bytes = value * multiplier;
    if (bytes == 0) return null;
    return bytes;
}

fn validate(parsed: *Parsed, parse_error: *?zencli.UsageError) void {
    const options = &parsed.options;
    if (parsed.show_help or parsed.show_version) return;
    if (options.secure and options.data_dir == null) {
        parse_error.* = .{ .message = "--secure needs --data-dir PATH: " ++
            "accounts, sessions, and audit have to live somewhere durable." };
        return;
    }
    if (!options.secure and options.data_dir != null) {
        parse_error.* = .{ .message = "--data-dir only applies with --secure; " ++
            "open mode keeps no state." };
        return;
    }
    if (!options.secure and options.allow_insecure_network) {
        parse_error.* = .{ .message = "--allow-insecure-network only applies " ++
            "with --secure; open mode has no credentials to protect." };
        return;
    }
    if (!options.secure and options.behind_proxy) {
        parse_error.* = .{ .message = "--behind-proxy only applies with " ++
            "--secure because open mode has no session cookie." };
        return;
    }
    if (options.secure and !isLoopback(options.address) and
        !options.behind_proxy and !options.allow_insecure_network)
    {
        parse_error.* = .{ .message = "secure mode on a non-loopback address " ++
            "needs TLS termination through --behind-proxy, or the explicit " ++
            "--allow-insecure-network acknowledgement." };
        return;
    }
}

fn isLoopback(address: []const u8) bool {
    const parsed = std.Io.net.IpAddress.parse(address, 0) catch return false;
    const loopback6 = [1]u8{0} ** 15 ++ [1]u8{1};
    return switch (parsed) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| std.mem.eql(u8, &ip6.bytes, &loopback6),
    };
}

fn renderUsageError(
    usage: zencli.UsageError,
    argv: []const []const u8,
    err_out: *std.Io.Writer,
) !void {
    const context: ?zenfmt.report.Context = if (usage.highlight) |index| .{
        .argv = .{ .args = argv, .highlight = index },
    } else null;
    const usage_report: zenfmt.Report = .{
        .severity = .err,
        .code = "cli.usage",
        .title = "I CANNOT UNDERSTAND THIS COMMAND",
        .problem = usage.message,
        .consequence = "The server did not start.",
        .context = context,
        .exit_class = .usage,
        .directions = &.{.{
            .title = "See the serve options",
            .explanation = "Run `zenfmt serve --help` for the flags and the " ++
                "common invocations.",
        }},
    };
    try zenfmt.report.renderText(&.{usage_report}, err_out, .{});
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn parseFor(argv: []const []const u8) struct { parsed: Parsed, err: ?zencli.UsageError } {
    var parsed: Parsed = .{ .options = .{} };
    var sink: Sink = .{ .parsed = &parsed };
    var parse_error: ?zencli.UsageError = null;
    ServeParser.parse(
        argv,
        &sink,
        "The serve subcommand takes no positional arguments.",
        &parse_error,
    );
    if (parse_error == null) validate(&parsed, &parse_error);
    return .{ .parsed = parsed, .err = parse_error };
}

test "defaults are the open-mode one-command server" {
    const result = parseFor(&.{"zenfmt"});
    try testing.expectEqual(@as(?zencli.UsageError, null), result.err);
    const options = result.parsed.options;
    try testing.expectEqualStrings("127.0.0.1", options.address);
    try testing.expectEqual(@as(u16, 8998), options.port);
    try testing.expect(!options.secure);
    try testing.expectEqual(@as(u64, 64 * 1024 * 1024), options.max_body_bytes);
    try testing.expectEqual(@as(u32, 128), options.connections);
    try testing.expect(options.ui);
}

test "flags parse into options" {
    const result = parseFor(&.{
        "zenfmt",          "--port",      "9000",
        "--max-body",      "256MiB",      "--connections",
        "16",              "--no-ui",     "--log-format",
        "json",            "--log-level", "debug",
        "--drain-seconds", "5",           "--conversions",
        "2",
    });
    try testing.expectEqual(@as(?zencli.UsageError, null), result.err);
    const options = result.parsed.options;
    try testing.expectEqual(@as(u16, 9000), options.port);
    try testing.expectEqual(@as(u64, 256 * 1024 * 1024), options.max_body_bytes);
    try testing.expectEqual(@as(u32, 16), options.connections);
    try testing.expect(!options.ui);
    try testing.expectEqual(root.LogFormat.json, options.log_format);
    try testing.expectEqual(std.log.Level.debug, options.log_level);
    try testing.expectEqual(@as(u32, 5), options.drain_seconds);
    try testing.expectEqual(@as(?u32, 2), options.conversions);
}

test "secure mode validation" {
    const missing_dir = parseFor(&.{ "zenfmt", "--secure" });
    try testing.expect(std.mem.startsWith(
        u8,
        missing_dir.err.?.message,
        "--secure needs --data-dir",
    ));

    const stray_dir = parseFor(&.{ "zenfmt", "--data-dir", "/tmp/x" });
    try testing.expect(std.mem.startsWith(
        u8,
        stray_dir.err.?.message,
        "--data-dir only applies with --secure",
    ));

    const stray_insecure = parseFor(&.{ "zenfmt", "--allow-insecure-network" });
    try testing.expect(std.mem.startsWith(
        u8,
        stray_insecure.err.?.message,
        "--allow-insecure-network only applies with --secure",
    ));

    const good = parseFor(&.{ "zenfmt", "--secure", "--data-dir", "/var/lib/zenfmt" });
    try testing.expectEqual(@as(?zencli.UsageError, null), good.err);
    try testing.expect(good.parsed.options.secure);
    try testing.expectEqualStrings("/var/lib/zenfmt", good.parsed.options.data_dir.?);

    const exposed = parseFor(&.{
        "zenfmt",    "--secure", "--data-dir", "/var/lib/zenfmt",
        "--address", "0.0.0.0",
    });
    try testing.expect(std.mem.startsWith(
        u8,
        exposed.err.?.message,
        "secure mode on a non-loopback address",
    ));
    const acknowledged = parseFor(&.{
        "zenfmt",    "--secure", "--data-dir",               "/var/lib/zenfmt",
        "--address", "0.0.0.0",  "--allow-insecure-network",
    });
    try testing.expectEqual(@as(?zencli.UsageError, null), acknowledged.err);
}

test "positional arguments are refused" {
    const result = parseFor(&.{ "zenfmt", "stray.docx" });
    try testing.expectEqualStrings(
        "The serve subcommand takes no positional arguments.",
        result.err.?.message,
    );
}

test "repeatable limit flags accumulate" {
    const result = parseFor(&.{
        "zenfmt",
        "--limit",
        "max_depth=64",
        "--limit",
        "max_input_bytes=2048",
    });
    try testing.expectEqual(@as(?zencli.UsageError, null), result.err);
    try testing.expectEqual(@as(u32, 64), result.parsed.options.limits.max_depth);
    try testing.expectEqual(@as(u64, 2048), result.parsed.options.limits.max_input_bytes);
}

test "byte sizes parse with binary suffixes only" {
    try testing.expectEqual(@as(?u64, 1048576), parseBytes("1048576"));
    try testing.expectEqual(@as(?u64, 64 * 1024), parseBytes("64KiB"));
    try testing.expectEqual(@as(?u64, 1024 * 1024 * 1024), parseBytes("1GiB"));
    try testing.expectEqual(@as(?u64, null), parseBytes("64MB"));
    try testing.expectEqual(@as(?u64, null), parseBytes("MiB"));
    try testing.expectEqual(@as(?u64, null), parseBytes("0"));
}

test "bad flag values are usage errors" {
    try testing.expect(parseFor(&.{ "zenfmt", "--port", "70000" }).err != null);
    try testing.expect(parseFor(&.{ "zenfmt", "--connections", "0" }).err != null);
    try testing.expect(parseFor(&.{ "zenfmt", "--connections", "129" }).err != null);
    try testing.expect(parseFor(&.{ "zenfmt", "--log-level", "verbose" }).err != null);
    try testing.expect(parseFor(&.{ "zenfmt", "--limit", "nope=1" }).err != null);
}
