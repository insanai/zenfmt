//! zencli — the command-line kernel (ZDS 0016, The zencli Library).
//!
//! The comptime flag-table machinery extracted from the zenfmt CLI so every
//! front end in the monorepo shares one grammar engine: a flag table drives
//! parsing and `--help` from a single declaration, argv is walked once with
//! no recursion and no allocation, and the four-value exit-code policy lives
//! in one place. The library imports only the standard library and knows
//! nothing about documents, conversions, or HTTP.
//!
//! The extraction is gated by byte identity: the zenfmt CLI's behavior suite
//! (`src/cli.zig`, tests) pins the generated help text and the parse grammar,
//! and any drift is a test failure.

const std = @import("std");

/// One command-line flag. `value` is null for a flag that takes no value;
/// otherwise it names the metavar shown in `--help`. A value-less flag may
/// still accept an inline `--flag=grade` value when its sink decides to
/// (the graded-flag rule, e.g. `--strict=exact`); it never consumes the
/// following argument.
pub const Flag = struct {
    long: []const u8,
    short: ?[]const u8 = null,
    value: ?[]const u8 = null,
    help: []const u8,
};

/// A subcommand: a name that, when it appears as the first positional
/// argument, selects its own flag table for the rest of argv.
pub const Command = struct {
    name: []const u8,
    summary: []const u8,
};

/// A usage diagnostic: the message and, when one exists, the index into argv
/// of the offending argument.
pub const UsageError = struct {
    message: []const u8,
    highlight: ?u32 = null,
};

/// The shared process exit-code policy (ZDS 0002): success, conversion
/// failure, usage error, limit exceeded.
pub const exit_ok: u8 = 0;
pub const exit_conversion: u8 = 1;
pub const exit_usage: u8 = 2;
pub const exit_limit: u8 = 3;

/// Maps a diagnostic exit class — any enum with the tags `conversion`,
/// `usage`, and `limit` — to the shared exit codes, without importing the
/// library that declares the enum.
pub fn classExitCode(exit_class: anytype) u8 {
    return switch (exit_class) {
        .conversion => exit_conversion,
        .usage => exit_usage,
        .limit => exit_limit,
    };
}

/// The `--help` column where flag descriptions start.
pub const help_column = 28;

/// Assembles help text at comptime: the caller's preamble, then one line per
/// flag. One table drives parsing and `--help`; they cannot drift apart.
pub fn helpText(comptime preamble: []const u8, comptime table: []const Flag) []const u8 {
    comptime {
        var text: []const u8 = preamble;
        for (table) |flag| {
            var left: []const u8 = "  ";
            if (flag.short) |short| {
                left = left ++ short ++ ", ";
            } else {
                left = left ++ "    ";
            }
            left = left ++ flag.long;
            if (flag.value) |value| left = left ++ " " ++ value;
            while (left.len < help_column) left = left ++ " ";
            text = text ++ left ++ flag.help ++ "\n";
        }
        return text;
    }
}

/// Rejects a command table whose entries could be mistaken for flags or for
/// each other. Runs at comptime; a bad table does not compile.
pub fn checkCommands(comptime commands: []const Command) void {
    comptime {
        for (commands, 0..) |command, i| {
            if (command.name.len == 0 or command.name[0] == '-') {
                @compileError("zencli: command name reads as a flag: '" ++ command.name ++ "'");
            }
            for (commands[0..i]) |previous| {
                if (std.mem.eql(u8, previous.name, command.name)) {
                    @compileError("zencli: duplicate command name: '" ++ command.name ++ "'");
                }
            }
        }
    }
}

/// A positional argument found by `firstPositional`.
pub const Positional = struct {
    index: u32,
    arg: []const u8,
};

/// The parser for one flag table. The sink is a pointer providing:
///
///   fn applyFlag(sink, name: []const u8, value: ?[]const u8) bool
///   fn positional(sink, arg: []const u8) bool
///
/// `applyFlag` returns false for an unrecognized name, a rejected value, or
/// an inline value on a flag that takes none. `positional` returns false
/// when the positional contract is exhausted; the caller's overflow message
/// becomes the usage error.
pub fn Parser(comptime table: []const Flag) type {
    return struct {
        pub fn takesValue(name: []const u8) bool {
            inline for (table) |flag| {
                if (flag.value != null) {
                    if (std.mem.eql(u8, name, flag.long)) return true;
                    if (flag.short) |short| if (std.mem.eql(u8, name, short)) return true;
                }
            }
            return false;
        }

        /// One bounded pass over argv (ZDS 0002: no recursion). Parsing
        /// never allocates; parsed values borrow the argv slices.
        pub fn parse(
            argv: []const []const u8,
            sink: anytype,
            overflow_message: []const u8,
            parse_error: *?UsageError,
        ) void {
            var i: usize = 1;
            while (i < argv.len) : (i += 1) {
                const arg = argv[i];
                if (arg.len == 0) continue;
                if (arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
                    if (!sink.positional(arg)) {
                        parse_error.* = .{
                            .message = overflow_message,
                            .highlight = @intCast(i),
                        };
                        return;
                    }
                    continue;
                }

                // `--flag=value` splits into name and inline value.
                const equals = std.mem.indexOfScalar(u8, arg, '=');
                const name = if (equals) |index| arg[0..index] else arg;
                const inline_value = if (equals) |index| arg[index + 1 ..] else null;

                const value: ?[]const u8, const consumed_next: bool = blk: {
                    // A flag that takes no value still accepts an inline one
                    // when it is graded, like `--strict=exact`; the sink
                    // decides.
                    if (!takesValue(name)) break :blk .{ inline_value, false };
                    if (inline_value) |v| break :blk .{ v, false };
                    if (i + 1 < argv.len) break :blk .{ argv[i + 1], true };
                    parse_error.* = .{
                        .message = "This option needs a value and none followed it.",
                        .highlight = @intCast(i),
                    };
                    return;
                };

                if (!sink.applyFlag(name, value)) {
                    parse_error.* = .{
                        .message = "I do not recognize this option.",
                        .highlight = @intCast(i),
                    };
                    return;
                }
                if (consumed_next) i += 1;
            }
        }

        /// The first positional argument under this table's value-consumption
        /// rules, or null. Used for subcommand dispatch before any flag is
        /// interpreted: unknown flags are stepped over, not diagnosed —
        /// the real parse afterwards owns the diagnostics.
        pub fn firstPositional(argv: []const []const u8) ?Positional {
            var i: usize = 1;
            while (i < argv.len) : (i += 1) {
                const arg = argv[i];
                if (arg.len == 0) continue;
                if (arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
                    return .{ .index = @intCast(i), .arg = arg };
                }
                const has_inline = std.mem.indexOfScalar(u8, arg, '=') != null;
                if (!has_inline and takesValue(arg) and i + 1 < argv.len) i += 1;
            }
            return null;
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const test_flags = [_]Flag{
    .{ .long = "--alpha", .short = "-a", .value = "X", .help = "Takes a value." },
    .{ .long = "--beta", .help = "Boolean." },
    .{ .long = "--gamma", .help = "Graded: accepts an inline value only." },
};

const TestParser = Parser(&test_flags);

const TestSink = struct {
    alpha: ?[]const u8 = null,
    beta: bool = false,
    gamma: ?[]const u8 = null,
    positionals: [4]?[]const u8 = @splat(null),
    count: usize = 0,

    pub fn applyFlag(sink: *TestSink, name: []const u8, value: ?[]const u8) bool {
        if (std.mem.eql(u8, name, "--alpha") or std.mem.eql(u8, name, "-a")) {
            sink.alpha = value.?;
        } else if (std.mem.eql(u8, name, "--beta")) {
            if (value != null) return false;
            sink.beta = true;
        } else if (std.mem.eql(u8, name, "--gamma")) {
            sink.gamma = value orelse "default";
        } else {
            return false;
        }
        return true;
    }

    pub fn positional(sink: *TestSink, arg: []const u8) bool {
        if (sink.count == sink.positionals.len) return false;
        sink.positionals[sink.count] = arg;
        sink.count += 1;
        return true;
    }
};

fn testParse(argv: []const []const u8) struct { sink: TestSink, err: ?UsageError } {
    var sink: TestSink = .{};
    var parse_error: ?UsageError = null;
    TestParser.parse(argv, &sink, "Too many positionals.", &parse_error);
    return .{ .sink = sink, .err = parse_error };
}

test "value flags take inline or following values" {
    const inline_form = testParse(&.{ "tool", "--alpha=1", "p" });
    try testing.expectEqualStrings("1", inline_form.sink.alpha.?);
    try testing.expectEqualStrings("p", inline_form.sink.positionals[0].?);

    const following = testParse(&.{ "tool", "-a", "2" });
    try testing.expectEqualStrings("2", following.sink.alpha.?);
    try testing.expectEqual(@as(usize, 0), following.sink.count);
}

test "graded flags accept an inline value and never consume the next argument" {
    const bare = testParse(&.{ "tool", "--gamma", "p" });
    try testing.expectEqualStrings("default", bare.sink.gamma.?);
    try testing.expectEqualStrings("p", bare.sink.positionals[0].?);

    const graded = testParse(&.{ "tool", "--gamma=fine" });
    try testing.expectEqualStrings("fine", graded.sink.gamma.?);
}

test "diagnostics carry the offending argv index" {
    const missing = testParse(&.{ "tool", "--alpha" });
    try testing.expectEqualStrings(
        "This option needs a value and none followed it.",
        missing.err.?.message,
    );
    try testing.expectEqual(@as(?u32, 1), missing.err.?.highlight);

    const unknown = testParse(&.{ "tool", "--delta" });
    try testing.expectEqualStrings("I do not recognize this option.", unknown.err.?.message);

    const rejected = testParse(&.{ "tool", "--beta=1" });
    try testing.expectEqualStrings("I do not recognize this option.", rejected.err.?.message);

    const overflow = testParse(&.{ "tool", "a", "b", "c", "d", "e" });
    try testing.expectEqualStrings("Too many positionals.", overflow.err.?.message);
    try testing.expectEqual(@as(?u32, 5), overflow.err.?.highlight);
}

test "empty arguments and `-` follow the positional rules" {
    const parsed = testParse(&.{ "tool", "", "-" });
    try testing.expectEqual(@as(?UsageError, null), parsed.err);
    try testing.expectEqualStrings("-", parsed.sink.positionals[0].?);
}

test "firstPositional steps over flags and their values" {
    try testing.expectEqualStrings(
        "serve",
        TestParser.firstPositional(&.{ "tool", "--alpha", "x", "--beta", "serve" }).?.arg,
    );
    try testing.expectEqualStrings(
        "serve",
        TestParser.firstPositional(&.{ "tool", "--alpha=x", "serve" }).?.arg,
    );
    // An unknown flag is stepped over without value consumption.
    try testing.expectEqualStrings(
        "y",
        TestParser.firstPositional(&.{ "tool", "--nope", "y" }).?.arg,
    );
    try testing.expectEqual(
        @as(?Positional, null),
        TestParser.firstPositional(&.{ "tool", "--alpha", "serve" }),
    );
}

test "helpText renders the table into the shared column" {
    const text = comptime helpText("usage: tool\n\n", &test_flags);
    try testing.expectEqualStrings(
        "usage: tool\n" ++
            "\n" ++
            "  -a, --alpha X             Takes a value.\n" ++
            "      --beta                Boolean.\n" ++
            "      --gamma               Graded: accepts an inline value only.\n",
        text,
    );
}

test "exit codes and the class mapping are the published contract" {
    try testing.expectEqual(@as(u8, 0), exit_ok);
    try testing.expectEqual(@as(u8, 1), exit_conversion);
    try testing.expectEqual(@as(u8, 2), exit_usage);
    try testing.expectEqual(@as(u8, 3), exit_limit);

    const Class = enum { conversion, usage, limit };
    try testing.expectEqual(@as(u8, 1), classExitCode(Class.conversion));
    try testing.expectEqual(@as(u8, 2), classExitCode(Class.usage));
    try testing.expectEqual(@as(u8, 3), classExitCode(Class.limit));
}

test "checkCommands accepts a well-formed table" {
    comptime checkCommands(&.{
        .{ .name = "serve", .summary = "Run the server." },
    });
}
