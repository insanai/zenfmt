//! Diagnostics (ZDS 0002, Diagnostics and Error Messages).
//!
//! An error message is a user interface. Every report answers four questions
//! in order: what happened, where, what zenfmt did about it, and what the
//! user can do next. Construction validates the contract with assertions, so
//! a report that names a failure without giving direction is rejected at the
//! source rather than shipped.
//!
//! Text and JSON are two renderers of the same `Report`; display flags never
//! change the canonical report stream stored in the artifact manifest.

const std = @import("std");
const assert = std.debug.assert;
const limits_mod = @import("limits.zig");
const json = @import("json.zig");

pub const Severity = enum(u8) {
    note,
    warning,
    err,

    pub fn name(severity: Severity) []const u8 {
        return switch (severity) {
            .note => "note",
            .warning => "warning",
            .err => "error",
        };
    }
};

/// The lossiness tier of a degraded or dropped construct. The tier of a
/// construct is decided in the plugin's ZDS, not at the keyboard.
pub const LossTier = enum(u8) {
    /// Something reached the output in simplified form.
    degraded,
    /// Recognized, and produced nothing.
    dropped,
};

/// Which exit class a failure belongs to; a bulk script wants to treat a zip
/// bomb differently from a malformed document.
pub const ExitClass = enum(u8) {
    conversion,
    usage,
    limit,
};

pub const Direction = struct {
    /// Short imperative heading: "Select the format explicitly".
    title: []const u8,
    /// Why this action helps, including risk when it weakens a safety limit.
    explanation: []const u8,
    /// A complete argv vector when a command is the useful action. The
    /// renderer performs platform-appropriate quoting.
    command: ?[]const []const u8 = null,
    /// An exact replacement when the problem is a token or source span.
    replacement: ?[]const u8 = null,
};

/// Where something happened, separated from prose so the text and JSON
/// renderers expose the same facts.
pub const Context = union(enum) {
    source: Source,
    /// A logical document location, e.g. "table 3, row 7".
    logical: []const u8,
    /// An archive member name.
    archive_member: []const u8,
    argv: Argv,
    path: Path,

    pub const Source = struct {
        /// Display name of the input.
        name: []const u8,
        /// 1-based line number of the excerpt's first line.
        line: u32,
        /// The excerpted source lines, without a trailing newline.
        excerpt: []const u8,
        /// Caret span as byte offsets into `excerpt`.
        span_start: u32,
        span_len: u32,
    };

    pub const Argv = struct {
        args: []const []const u8,
        /// Index of the offending argument.
        highlight: u32,
    };

    pub const Path = struct {
        path: []const u8,
        /// What was being attempted: "create the output file".
        operation: []const u8,
    };
};

pub const Report = struct {
    severity: Severity,
    /// Stable namespaced machine id: "core.unknown-input-format".
    code: []const u8,
    /// Short human banner: "UNKNOWN INPUT FORMAT". Wording may improve
    /// without breaking scripts or suppression files.
    title: []const u8,
    /// What happened and, when known, why.
    problem: []const u8,
    /// What was or was not produced, preserved, ignored, or changed.
    consequence: []const u8,
    loss: ?LossTier = null,
    context: ?Context = null,
    /// Ordered, concrete next actions. Non-empty for `warning` and `err`.
    directions: []const Direction = &.{},
    exit_class: ExitClass = .conversion,
    /// How many times this report fired; repeats are counted, not repeated.
    count: u32 = 1,
    /// Bounded distinct locations retained after aggregation.
    samples: []const Context = &.{},
};

/// The reserved allocation-exhaustion report: static strings only, so it can
/// be returned after cleanup without allocating.
pub const out_of_memory: Report = .{
    .severity = .err,
    .code = "core.out-of-memory",
    .title = "OUT OF MEMORY",
    .problem = "I ran out of memory while converting this document.",
    .consequence = "The conversion stopped and no output file was created " ++
        "or replaced.",
    .directions = &.{.{
        .title = "Free memory or shrink the input",
        .explanation = "Close other programs or run the conversion on a " ++
            "machine with more available memory. If the input is " ++
            "unusually large, converting it in smaller pieces may also " ++
            "work.",
    }},
};

fn validCode(code: []const u8) bool {
    if (code.len == 0) return false;
    var has_dot = false;
    for (code) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-' => {},
        '.' => has_dot = true,
        else => return false,
    };
    return has_dot;
}

/// The construction contract, asserted rather than returned: a malformed
/// report is a plugin bug, caught in that plugin's tests.
fn assertReportValid(report: Report) void {
    assert(validCode(report.code));
    assert(report.title.len > 0);
    assert(report.problem.len > 0);
    assert(report.consequence.len > 0);
    assert(report.count >= 1);
    const needs_direction = report.severity != .note or report.loss != null;
    if (needs_direction) assert(report.directions.len > 0);
    for (report.directions) |direction| {
        assert(direction.title.len > 0);
        assert(direction.explanation.len > 0);
        if (direction.command) |command| assert(command.len > 0);
    }
    if (report.context) |context| switch (context) {
        .source => |source| {
            assert(source.span_start <= source.excerpt.len);
            assert(source.span_start + source.span_len <= source.excerpt.len);
        },
        .argv => |argv| assert(argv.highlight < argv.args.len),
        else => {},
    };
}

// ---------------------------------------------------------- aggregation

/// The conversion's report sink. Reports aggregate only when `code`,
/// consequence, and directions are identical; the aggregate keeps the first
/// few distinct contexts and counts the rest.
pub const Reports = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    max_samples: u32,

    const Entry = struct {
        report: Report,
        samples: std.ArrayList(Context),
        omitted: u32,
    };

    pub fn init(gpa: std.mem.Allocator, limits: limits_mod.Limits) Reports {
        assert(limits.max_report_samples >= 1);
        return .{ .gpa = gpa, .max_samples = limits.max_report_samples };
    }

    /// Strings inside `report` must outlive the conversion: static memory or
    /// the conversion arena.
    pub fn add(r: *Reports, report: Report) error{OutOfMemory}!void {
        assertReportValid(report);
        assert(report.samples.len == 0);

        for (r.entries.items) |*entry| {
            if (!aggregates(entry.report, report)) continue;
            entry.report.count += report.count;
            if (entry.report.severity != report.severity) {
                // The louder severity wins the aggregate.
                if (@intFromEnum(report.severity) > @intFromEnum(entry.report.severity)) {
                    entry.report.severity = report.severity;
                }
            }
            if (report.context) |context| {
                // A location already sampled adds nothing; the count above
                // carries the repetition.
                var duplicate = false;
                for (entry.samples.items) |existing| {
                    if (contextEql(existing, context)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) {
                    // Counted, not resampled.
                } else if (entry.samples.items.len < r.max_samples) {
                    try entry.samples.append(r.gpa, context);
                } else {
                    entry.omitted += 1;
                }
            }
            return;
        }

        var entry: Entry = .{ .report = report, .samples = .empty, .omitted = 0 };
        if (report.context) |context| {
            assert(r.max_samples >= 1);
            try entry.samples.append(r.gpa, context);
        }
        try r.entries.append(r.gpa, entry);
    }

    fn contextEql(a: Context, b: Context) bool {
        if (@as(std.meta.Tag(Context), a) != @as(std.meta.Tag(Context), b)) return false;
        return switch (a) {
            .source => |source| std.mem.eql(u8, source.name, b.source.name) and
                source.line == b.source.line and
                source.span_start == b.source.span_start and
                source.span_len == b.source.span_len,
            .logical => |name| std.mem.eql(u8, name, b.logical),
            .archive_member => |member| std.mem.eql(u8, member, b.archive_member),
            .argv => |argv| argv.highlight == b.argv.highlight,
            .path => |path| std.mem.eql(u8, path.path, b.path.path) and
                std.mem.eql(u8, path.operation, b.path.operation),
        };
    }

    fn aggregates(existing: Report, candidate: Report) bool {
        if (!std.mem.eql(u8, existing.code, candidate.code)) return false;
        if (!std.mem.eql(u8, existing.consequence, candidate.consequence)) return false;
        if (existing.directions.len != candidate.directions.len) return false;
        for (existing.directions, candidate.directions) |a, b| {
            if (!std.mem.eql(u8, a.title, b.title)) return false;
            if (!std.mem.eql(u8, a.explanation, b.explanation)) return false;
        }
        return true;
    }

    /// The canonical report list: aggregated, in first-occurrence order,
    /// with bounded samples materialized.
    pub fn finalize(r: *Reports) error{OutOfMemory}![]const Report {
        const out = try r.gpa.alloc(Report, r.entries.items.len);
        for (r.entries.items, out) |*entry, *report| {
            report.* = entry.report;
            report.samples = entry.samples.items;
            assert(report.samples.len <= r.max_samples);
        }
        return out;
    }

    pub fn worst(r: *const Reports) ?Severity {
        var result: ?Severity = null;
        for (r.entries.items) |entry| {
            const severity = entry.report.severity;
            if (result == null or @intFromEnum(severity) > @intFromEnum(result.?)) {
                result = severity;
            }
        }
        return result;
    }

    pub fn worstExitClass(r: *const Reports) ExitClass {
        var result: ExitClass = .conversion;
        for (r.entries.items) |entry| {
            if (entry.report.severity != .err) continue;
            const class = entry.report.exit_class;
            if (@intFromEnum(class) > @intFromEnum(result)) result = class;
        }
        return result;
    }

    pub fn hasErrors(r: *const Reports) bool {
        return r.worst() == .err;
    }
};

// ------------------------------------------------------- text rendering

const banner_width = 71;
const wrap_width = 71;

pub const RenderOptions = struct {
    /// Suppress notes; warnings and errors always render.
    quiet: bool = false,
    /// ANSI color; only when the destination is a terminal.
    color: bool = false,
};

pub fn renderText(
    reports: []const Report,
    out: *std.Io.Writer,
    options: RenderOptions,
) std.Io.Writer.Error!void {
    var first = true;
    for (reports) |report| {
        if (options.quiet and report.severity == .note) continue;
        if (!first) try out.writeAll("\n");
        first = false;
        try renderOne(report, out, options);
    }
}

fn renderOne(report: Report, out: *std.Io.Writer, options: RenderOptions) std.Io.Writer.Error!void {
    try renderBanner(report, out, options);
    try out.writeAll("\n");
    try renderWrapped(out, report.problem, 0);
    try out.writeAll("\n");

    if (report.samples.len > 0) {
        for (report.samples) |context| {
            try renderContext(context, out);
            try out.writeAll("\n");
        }
        const extra = report.count -| @as(u32, @intCast(report.samples.len));
        if (extra > 0) {
            try out.print("    ... and {d} more like this.\n\n", .{extra});
        }
    } else if (report.context) |context| {
        try renderContext(context, out);
        try out.writeAll("\n");
    } else if (report.count > 1) {
        try out.print("    This happened {d} times.\n\n", .{report.count});
    }

    try renderWrapped(out, report.consequence, 0);

    if (report.directions.len > 0) {
        try out.writeAll("\nWhat you can do:\n");
        for (report.directions) |direction| {
            try out.writeAll("\n  ");
            try out.writeAll(direction.title);
            try out.writeAll(":\n");
            // A direction whose title says everything carries no separate
            // explanation line; repeating the bytes would read as a stutter.
            if (!std.mem.eql(u8, direction.title, direction.explanation)) {
                try renderWrapped(out, direction.explanation, 4);
            }
            if (direction.command) |command| {
                try out.writeAll("\n        ");
                try renderCommand(command, out);
                try out.writeAll("\n");
            }
            if (direction.replacement) |replacement| {
                try out.print("\n        {s}\n", .{replacement});
            }
        }
    }
}

fn renderBanner(report: Report, out: *std.Io.Writer, options: RenderOptions) std.Io.Writer.Error!void {
    const label = contextLabel(report);
    if (options.color) try out.writeAll(severityColor(report.severity));
    try out.writeAll("-- ");
    try out.writeAll(report.title);
    try out.writeAll(" ");
    const used = 3 + report.title.len + 1 + 1 + label.len;
    const dashes = if (used < banner_width) banner_width - used else 3;
    var remaining = dashes;
    while (remaining > 0) : (remaining -= 1) try out.writeAll("-");
    try out.writeAll(" ");
    try out.writeAll(label);
    if (options.color) try out.writeAll("\x1b[0m");
    try out.writeAll("\n");
}

fn severityColor(severity: Severity) []const u8 {
    return switch (severity) {
        .note => "\x1b[36m",
        .warning => "\x1b[33m",
        .err => "\x1b[31m",
    };
}

fn contextLabel(report: Report) []const u8 {
    const context = report.context orelse {
        if (report.samples.len > 0) return sampleLabel(report.samples[0]);
        return "zenfmt";
    };
    return sampleLabel(context);
}

fn sampleLabel(context: Context) []const u8 {
    return switch (context) {
        .source => |source| source.name,
        .archive_member => |member| member,
        .path => |path| path.path,
        .logical, .argv => "zenfmt",
    };
}

fn renderContext(context: Context, out: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (context) {
        .source => |source| {
            var line_number = source.line;
            var offset: u32 = 0;
            var lines = std.mem.splitScalar(u8, source.excerpt, '\n');
            while (lines.next()) |line| {
                try out.print("    {d: >4} | {s}\n", .{ line_number, line });
                const line_start = offset;
                const line_end = offset + @as(u32, @intCast(line.len));
                if (source.span_len > 0 and
                    source.span_start >= line_start and source.span_start < line_end)
                {
                    const caret_start = source.span_start - line_start;
                    const span_end = @min(source.span_start + source.span_len, line_end);
                    const caret_len = span_end - source.span_start;
                    try out.writeAll("         | ");
                    var i: u32 = 0;
                    while (i < caret_start) : (i += 1) try out.writeAll(" ");
                    i = 0;
                    while (i < caret_len) : (i += 1) try out.writeAll("^");
                    try out.writeAll("\n");
                }
                offset = line_end + 1;
                line_number += 1;
            }
        },
        .logical => |location| try out.print("    at {s}\n", .{location}),
        .archive_member => |member| try out.print("    in archive entry {s}\n", .{member}),
        .argv => |argv| {
            try out.writeAll("    ");
            var caret_start: usize = 0;
            var caret_len: usize = 0;
            var column: usize = 0;
            for (argv.args, 0..) |arg, i| {
                if (i > 0) {
                    try out.writeAll(" ");
                    column += 1;
                }
                if (i == argv.highlight) {
                    caret_start = column;
                    caret_len = arg.len;
                }
                try out.writeAll(arg);
                column += arg.len;
            }
            try out.writeAll("\n    ");
            var i: usize = 0;
            while (i < caret_start) : (i += 1) try out.writeAll(" ");
            i = 0;
            while (i < @max(caret_len, 1)) : (i += 1) try out.writeAll("^");
            try out.writeAll("\n");
        },
        .path => |path| try out.print("    while trying to {s}: {s}\n", .{
            path.operation, path.path,
        }),
    }
}

/// Greedy word wrap; words longer than the width are emitted unbroken.
fn renderWrapped(out: *std.Io.Writer, prose: []const u8, indent: usize) std.Io.Writer.Error!void {
    assert(indent < wrap_width);
    const width = wrap_width - indent;
    var words = std.mem.tokenizeAny(u8, prose, " \n");
    var column: usize = 0;
    while (words.next()) |word| {
        if (column == 0) {
            try writeIndent(out, indent);
            try out.writeAll(word);
            column = word.len;
        } else if (column + 1 + word.len <= width) {
            try out.writeAll(" ");
            try out.writeAll(word);
            column += 1 + word.len;
        } else {
            try out.writeAll("\n");
            try writeIndent(out, indent);
            try out.writeAll(word);
            column = word.len;
        }
    }
    if (column > 0) try out.writeAll("\n");
}

fn writeIndent(out: *std.Io.Writer, indent: usize) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try out.writeAll(" ");
}

/// POSIX single-quote quoting, only when an argument needs it.
fn renderCommand(command: []const []const u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    for (command, 0..) |arg, i| {
        if (i > 0) try out.writeAll(" ");
        if (needsQuoting(arg)) {
            try out.writeAll("'");
            for (arg) |byte| {
                if (byte == '\'') {
                    try out.writeAll("'\\''");
                } else {
                    try out.writeByte(byte);
                }
            }
            try out.writeAll("'");
        } else {
            try out.writeAll(arg);
        }
    }
}

fn needsQuoting(arg: []const u8) bool {
    if (arg.len == 0) return true;
    for (arg) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '/', '=', ':', ',', '+', '@' => {},
        else => return true,
    };
    return false;
}

// ------------------------------------------------------- JSON rendering

/// The structured form of a report: the same facts as the text renderer,
/// not the terminal text wrapped in JSON. Used both by `--reports=json` and
/// by the artifact manifest.
pub fn writeJson(report: Report, w: *json.WriteStream) error{OutOfMemory}!void {
    try w.beginObject();
    try w.field("code");
    try w.string(report.code);
    try w.field("consequence");
    try w.string(report.consequence);
    try w.field("count");
    try w.integer(report.count);
    try w.field("directions");
    try w.beginArray();
    for (report.directions) |direction| {
        try w.beginObject();
        if (direction.command) |command| {
            try w.field("command");
            try w.beginArray();
            for (command) |arg| try w.string(arg);
            try w.endArray();
        }
        try w.field("explanation");
        try w.string(direction.explanation);
        if (direction.replacement) |replacement| {
            try w.field("replacement");
            try w.string(replacement);
        }
        try w.field("title");
        try w.string(direction.title);
        try w.endObject();
    }
    try w.endArray();
    if (report.loss) |loss| {
        try w.field("loss");
        try w.string(@tagName(loss));
    }
    try w.field("problem");
    try w.string(report.problem);
    try w.field("samples");
    try w.beginArray();
    if (report.samples.len > 0) {
        for (report.samples) |context| try writeContextJson(context, w);
    } else if (report.context) |context| {
        try writeContextJson(context, w);
    }
    try w.endArray();
    try w.field("severity");
    try w.string(report.severity.name());
    try w.field("title");
    try w.string(report.title);
    try w.endObject();
}

fn writeContextJson(context: Context, w: *json.WriteStream) error{OutOfMemory}!void {
    try w.beginObject();
    switch (context) {
        .source => |source| {
            try w.field("excerpt");
            try w.string(source.excerpt);
            try w.field("kind");
            try w.string("source");
            try w.field("line");
            try w.integer(source.line);
            try w.field("name");
            try w.string(source.name);
            try w.field("span_len");
            try w.integer(source.span_len);
            try w.field("span_start");
            try w.integer(source.span_start);
        },
        .logical => |location| {
            try w.field("kind");
            try w.string("logical");
            try w.field("location");
            try w.string(location);
        },
        .archive_member => |member| {
            try w.field("kind");
            try w.string("archive-member");
            try w.field("member");
            try w.string(member);
        },
        .argv => |argv| {
            try w.field("args");
            try w.beginArray();
            for (argv.args) |arg| try w.string(arg);
            try w.endArray();
            try w.field("highlight");
            try w.integer(argv.highlight);
            try w.field("kind");
            try w.string("argv");
        },
        .path => |path| {
            try w.field("kind");
            try w.string("path");
            try w.field("operation");
            try w.string(path.operation);
            try w.field("path");
            try w.string(path.path);
        },
    }
    try w.endObject();
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "reports aggregate on identical code, consequence, and directions" {
    var reports = Reports.init(testing.allocator, .{ .max_report_samples = 2 });
    defer {
        for (reports.entries.items) |*entry| entry.samples.deinit(testing.allocator);
        reports.entries.deinit(testing.allocator);
    }

    const template: Report = .{
        .severity = .warning,
        .code = "docx.comment-dropped",
        .title = "COMMENT DROPPED",
        .problem = "This document contains a comment.",
        .consequence = "The comment is absent from the output.",
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source DOCX if comments matter.",
        }},
    };

    var one = template;
    one.context = .{ .logical = "paragraph 1" };
    try reports.add(one);
    var two = template;
    two.context = .{ .logical = "paragraph 2" };
    try reports.add(two);
    var three = template;
    three.context = .{ .logical = "paragraph 9" };
    try reports.add(three);

    const final = try reports.finalize();
    defer testing.allocator.free(final);
    try testing.expectEqual(@as(usize, 1), final.len);
    try testing.expectEqual(@as(u32, 3), final[0].count);
    try testing.expectEqual(@as(usize, 2), final[0].samples.len);
    try testing.expectEqual(Severity.warning, reports.worst().?);
}

test "text rendering carries the four answers" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const report: Report = .{
        .severity = .err,
        .code = "core.unknown-input-format",
        .title = "UNKNOWN INPUT FORMAT",
        .problem = "I do not recognize `docs` as an input format.",
        .consequence = "No output file was created.",
        .context = .{ .argv = .{
            .args = &.{ "zenfmt", "--from", "docs", "report.docx" },
            .highlight = 2,
        } },
        .directions = &.{.{
            .title = "Select the intended format explicitly",
            .explanation = "Select the intended format explicitly:",
            .command = &.{ "zenfmt", "--from", "docx", "report.docx" },
        }},
    };
    try renderText(&.{report}, &writer, .{});

    const rendered = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, rendered, "-- UNKNOWN INPUT FORMAT") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "^^^^") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "What you can do:") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "zenfmt --from docx report.docx") != null);
}

test "the reserved out-of-memory report is contract-valid" {
    assertReportValid(out_of_memory);
}
