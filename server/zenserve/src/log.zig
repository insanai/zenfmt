//! Structured logging (ZDS 0016, Observability core).
//!
//! One line per event, logfmt or JSON lines, written to a caller-supplied
//! writer. The emitting API takes typed fields rather than preformatted
//! strings, which is what makes the observability contract enforceable:
//! every value passes through bounded escaping and truncation, so a log
//! line is safe for any byte sequence a caller hands it. The closed event
//! and field vocabulary is the caller's responsibility; this module
//! enforces the shape.
//!
//! A line is assembled in a fixed stack buffer of `max_line_bytes` and
//! written under a mutex, so concurrent tasks never interleave lines.
//! Write errors are swallowed: logging must never fail the request.

const std = @import("std");
const assert = std.debug.assert;

/// The wire format of an emitted line.
pub const Format = enum { text, json };

/// Severity, ordered from most to least severe. A logger configured at
/// `info` emits `err`, `warn`, and `info` lines and drops `debug`.
pub const Level = enum(u2) {
    err,
    warn,
    info,
    debug,

    /// Returns true when `level` is at least as severe as `threshold`.
    pub fn atLeast(level: Level, threshold: Level) bool {
        return @intFromEnum(level) <= @intFromEnum(threshold);
    }
};

/// Hard bound on one emitted line, including the trailing newline. Fields
/// that do not fit are dropped whole; the line always closes validly.
pub const max_line_bytes = 4096;

/// Bound on one rendered value. Longer values are cut at this many source
/// bytes and marked with a trailing `...` inside the quotes.
pub const max_value_bytes = 512;

/// A typed field value. Strings may contain arbitrary bytes; escaping
/// makes them safe in both formats.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    unsigned: u64,
    boolean: bool,
};

/// One name/value pair. Names are trusted identifiers from the closed
/// field vocabulary and must match the bare-atom pattern
/// `[A-Za-z0-9._/:-]+`; `emit` asserts this.
pub const Field = struct {
    name: []const u8,
    value: Value,
};

/// A structured logger over one output writer. The mutex serializes
/// whole lines across concurrent tasks; the buffer is per-call stack
/// space, so a logger allocates nothing.
pub const Logger = struct {
    format: Format,
    level: Level,
    mutex: std.Io.Mutex = .init,
    out: *std.Io.Writer,

    /// Emits one line, or returns silently when `level` is below the
    /// configured threshold. Wall time is read from `io`'s real clock.
    /// The lock is taken uncancelably and write errors are swallowed:
    /// emitting a log line never fails or cancels the calling task.
    pub fn emit(
        logger: *Logger,
        io: std.Io,
        level: Level,
        event: []const u8,
        fields: []const Field,
    ) void {
        if (!level.atLeast(logger.level)) return;
        assert(isBareAtom(event));
        for (fields) |field| assert(isBareAtom(field.name));

        const unix_seconds = std.Io.Clock.now(.real, io).toSeconds();
        var buf: [max_line_bytes]u8 = undefined;
        const line = switch (logger.format) {
            .text => renderText(&buf, unix_seconds, level, event, fields),
            .json => renderJson(&buf, unix_seconds, level, event, fields),
        };
        if (line.len == 0) return;
        assert(line.len <= max_line_bytes);
        assert(line[line.len - 1] == '\n');

        logger.mutex.lockUncancelable(io);
        defer logger.mutex.unlock(io);
        logger.out.writeAll(line) catch {};
        logger.out.flush() catch {};
    }
};

/// Returns true when `bytes` is nonempty and every byte is in the logfmt
/// bare-atom alphabet `[A-Za-z0-9._/:-]`.
fn isBareAtom(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '/', ':', '-' => {},
        else => return false,
    };
    return true;
}

/// Renders a logfmt line into `buf`, dropping trailing fields that do not
/// fit. Returns the line including the newline, or an empty slice when
/// even the fixed prefix does not fit.
fn renderText(
    buf: *[max_line_bytes]u8,
    unix_seconds: i64,
    level: Level,
    event: []const u8,
    fields: []const Field,
) []const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. max_line_bytes - 1]);
    w.print("time={d} level={s} event={s}", .{
        unix_seconds, @tagName(level), event,
    }) catch return buf[0..0];
    for (fields) |field| {
        const mark = w.end;
        writeTextField(&w, field) catch {
            w.end = mark;
            break;
        };
    }
    buf[w.end] = '\n';
    return buf[0 .. w.end + 1];
}

fn writeTextField(w: *std.Io.Writer, field: Field) std.Io.Writer.Error!void {
    try w.writeByte(' ');
    try w.writeAll(field.name);
    try w.writeByte('=');
    switch (field.value) {
        .string => |s| try writeTextString(w, s),
        .integer => |v| try w.print("{d}", .{v}),
        .unsigned => |v| try w.print("{d}", .{v}),
        .boolean => |v| try w.writeAll(if (v) "true" else "false"),
    }
}

/// Writes a string value: bare when it is a short atom, otherwise quoted
/// with escapes. Truncation cuts the source bytes first, so no escape
/// sequence is ever split; a truncated value is always quoted and carries
/// the `...` marker inside the quotes.
fn writeTextString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const truncated = s.len > max_value_bytes;
    const body = if (truncated) s[0..max_value_bytes] else s;
    if (!truncated and isBareAtom(body)) return w.writeAll(body);
    try w.writeByte('"');
    for (body) |byte| try writeTextEscaped(w, byte);
    if (truncated) try w.writeAll("...");
    try w.writeByte('"');
}

/// Escapes one byte for a quoted logfmt value: the five named escapes,
/// `\xNN` for remaining control bytes (including DEL), and everything
/// else verbatim.
fn writeTextEscaped(w: *std.Io.Writer, byte: u8) std.Io.Writer.Error!void {
    switch (byte) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            if (byte < 0x20 or byte == 0x7f) {
                try w.print("\\x{x:0>2}", .{byte});
            } else {
                try w.writeByte(byte);
            }
        },
    }
}

/// Renders a JSON-lines object into `buf`, dropping trailing fields that
/// do not fit and always closing the object, so every emitted line is a
/// complete JSON document.
fn renderJson(
    buf: *[max_line_bytes]u8,
    unix_seconds: i64,
    level: Level,
    event: []const u8,
    fields: []const Field,
) []const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. max_line_bytes - 2]);
    w.print("{{\"time\":{d},\"level\":\"{s}\",\"event\":\"{s}\"", .{
        unix_seconds, @tagName(level), event,
    }) catch return buf[0..0];
    for (fields) |field| {
        const mark = w.end;
        writeJsonField(&w, field) catch {
            w.end = mark;
            break;
        };
    }
    buf[w.end] = '}';
    buf[w.end + 1] = '\n';
    return buf[0 .. w.end + 2];
}

fn writeJsonField(w: *std.Io.Writer, field: Field) std.Io.Writer.Error!void {
    try w.writeByte(',');
    try w.writeByte('"');
    try w.writeAll(field.name);
    try w.writeAll("\":");
    switch (field.value) {
        .string => |s| try writeJsonString(w, s),
        .integer => |v| try w.print("{d}", .{v}),
        .unsigned => |v| try w.print("{d}", .{v}),
        .boolean => |v| try w.writeAll(if (v) "true" else "false"),
    }
}

/// Writes a JSON string value. Output is pure ASCII: bytes outside the
/// printable ASCII range are escaped as `\u00NN` (a latin-1 reading of
/// the byte), so any byte sequence, valid UTF-8 or not, produces a valid
/// JSON document. Truncation cuts source bytes before escaping.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const truncated = s.len > max_value_bytes;
    const body = if (truncated) s[0..max_value_bytes] else s;
    try w.writeByte('"');
    for (body) |byte| try writeJsonEscaped(w, byte);
    if (truncated) try w.writeAll("...");
    try w.writeByte('"');
}

fn writeJsonEscaped(w: *std.Io.Writer, byte: u8) std.Io.Writer.Error!void {
    switch (byte) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            if (byte < 0x20 or byte >= 0x7f) {
                try w.print("\\u00{x:0>2}", .{byte});
            } else {
                try w.writeByte(byte);
            }
        },
    }
}

// ---- tests

const testing = std.testing;

/// Emits one line through a fresh logger into `out` and returns it.
fn testLine(
    io: std.Io,
    format: Format,
    threshold: Level,
    level: Level,
    fields: []const Field,
    out: []u8,
) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    var logger: Logger = .{ .format = format, .level = threshold, .out = &w };
    logger.emit(io, level, "test.event", fields);
    return w.buffered();
}

/// Strips the variable `time=<seconds> ` prefix from a text line.
fn afterTime(line: []const u8) []const u8 {
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return line;
    return line[space + 1 ..];
}

test "level ordering and atLeast" {
    try testing.expect(Level.err.atLeast(.debug));
    try testing.expect(Level.info.atLeast(.info));
    try testing.expect(!Level.debug.atLeast(.info));
    try testing.expect(!Level.info.atLeast(.err));
}

test "field names match the bare-atom pattern" {
    try testing.expect(isBareAtom("duration_ms"));
    try testing.expect(isBareAtom("http.request"));
    try testing.expect(isBareAtom("a/b:c-d"));
    try testing.expect(!isBareAtom(""));
    try testing.expect(!isBareAtom("bad name"));
    try testing.expect(!isBareAtom("quote\""));
}

test "text: bare and quoted values" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: [max_line_bytes]u8 = undefined;
    const line = testLine(io, .text, .info, .info, &.{
        .{ .name = "route", .value = .{ .string = "convert" } },
        .{ .name = "agent", .value = .{ .string = "two words" } },
        .{ .name = "empty", .value = .{ .string = "" } },
        .{ .name = "status", .value = .{ .integer = -1 } },
        .{ .name = "bytes", .value = .{ .unsigned = 42 } },
        .{ .name = "ok", .value = .{ .boolean = true } },
    }, &out);
    try testing.expect(std.mem.startsWith(u8, line, "time="));
    try testing.expectEqualStrings(
        "level=info event=test.event route=convert agent=\"two words\" " ++
            "empty=\"\" status=-1 bytes=42 ok=true\n",
        afterTime(line),
    );
}

test "text: every escape class" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: [max_line_bytes]u8 = undefined;
    const line = testLine(io, .text, .info, .info, &.{
        .{ .name = "v", .value = .{ .string = "a\"b\\c\nd\re\tf\x01g\x7fh" } },
    }, &out);
    try testing.expectEqualStrings(
        "level=info event=test.event " ++
            "v=\"a\\\"b\\\\c\\nd\\re\\tf\\x01g\\x7fh\"\n",
        afterTime(line),
    );
}

test "value truncation at max_value_bytes" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const long = "x" ** (max_value_bytes + 100);
    var out: [max_line_bytes]u8 = undefined;
    const line = testLine(io, .text, .info, .info, &.{
        .{ .name = "v", .value = .{ .string = long } },
    }, &out);
    const expected = "level=info event=test.event v=\"" ++
        "x" ** max_value_bytes ++ "...\"\n";
    try testing.expectEqualStrings(expected, afterTime(line));
}

test "line truncation drops whole trailing fields" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const chunk = "y" ** max_value_bytes;
    var fields: [10]Field = undefined;
    for (&fields) |*field| {
        field.* = .{ .name = "k", .value = .{ .string = chunk } };
    }
    var out: [max_line_bytes]u8 = undefined;
    const line = testLine(io, .text, .info, .info, &fields, &out);
    try testing.expect(line.len <= max_line_bytes);
    try testing.expect(line[line.len - 1] == '\n');
    // Every field that survived is complete: the line ends with a full
    // bare value, and fewer fields fit than were offered.
    try testing.expect(std.mem.endsWith(u8, line, chunk ++ "\n"));
    const kept = std.mem.count(u8, line, " k=");
    try testing.expect(kept > 0);
    try testing.expect(kept < fields.len);
}

test "level filtering emits nothing below threshold" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: [max_line_bytes]u8 = undefined;
    const dropped = testLine(io, .text, .warn, .info, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), dropped.len);
    const kept = testLine(io, .text, .warn, .err, &.{}, &out);
    try testing.expect(kept.len > 0);
}

test "json: every line parses and round-trips values" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: [max_line_bytes]u8 = undefined;
    const line = testLine(io, .json, .info, .warn, &.{
        .{ .name = "s", .value = .{ .string = "a\"b\\c\nd\x7f\xffe" } },
        .{ .name = "n", .value = .{ .integer = -7 } },
        .{ .name = "u", .value = .{ .unsigned = 9 } },
        .{ .name = "b", .value = .{ .boolean = false } },
    }, &out);
    try testing.expect(line[line.len - 1] == '\n');

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        line[0 .. line.len - 1],
        .{},
    );
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqualStrings("warn", object.get("level").?.string);
    try testing.expectEqualStrings("test.event", object.get("event").?.string);
    // The 0x7f and 0xff bytes come back as their latin-1 codepoints.
    try testing.expectEqualStrings(
        "a\"b\\c\nd\u{7f}\u{ff}e",
        object.get("s").?.string,
    );
    try testing.expectEqual(@as(i64, -7), object.get("n").?.integer);
    try testing.expectEqual(@as(i64, 9), object.get("u").?.integer);
    try testing.expectEqual(false, object.get("b").?.bool);
}

test "json: truncated line is still a valid document" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const chunk = "z" ** max_value_bytes;
    const names = [12][]const u8{
        "k00", "k01", "k02", "k03", "k04", "k05",
        "k06", "k07", "k08", "k09", "k10", "k11",
    };
    var fields: [names.len]Field = undefined;
    for (&fields, names) |*field, name| {
        field.* = .{ .name = name, .value = .{ .string = chunk } };
    }
    var out: [max_line_bytes]u8 = undefined;
    const line = testLine(io, .json, .info, .info, &fields, &out);
    try testing.expect(line.len <= max_line_bytes);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        line[0 .. line.len - 1],
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "test.event",
        parsed.value.object.get("event").?.string,
    );
}
