//! Bounded streaming multipart/form-data parsing (ZDS 0016).
//!
//! The standard library has no multipart parser, so this file implements one
//! over `*std.Io.Reader` as an explicit state machine: no recursion, every
//! buffer fixed, every part and header bounded. Bodies stream through a
//! caller-supplied `*std.Io.Writer` sink without buffering a whole part; the
//! delimiter scan is a KMP prefix match, so a body chunk that almost matches
//! the boundary is carried correctly across read boundaries of any size.

const std = @import("std");
const assert = std.debug.assert;

/// The most parts one multipart body may carry (ZDS 0016 `max_batch_parts`).
pub const max_parts = 16;

/// The byte budget for one part's header block, terminator lines included.
pub const max_part_header_bytes = 4096;

/// RFC 2046: a boundary is at most 70 characters.
pub const max_boundary_len = 70;

/// The delimiter is `\r\n--` plus the boundary.
const max_delimiter_len = max_boundary_len + 4;

pub const Error = error{
    MalformedMultipart,
    TooManyParts,
    PartHeadersTooLarge,
    ReadFailed,
};

/// The parsed header block of one part. Names, filenames, and content types
/// longer than the fixed buffers are truncated, never overrun.
pub const PartHeader = struct {
    name_buf: [256]u8,
    name_len: u16,
    filename_buf: [256]u8,
    filename_len: u16,
    content_type_buf: [256]u8,
    content_type_len: u16,

    pub const empty: PartHeader = .{
        .name_buf = undefined,
        .name_len = 0,
        .filename_buf = undefined,
        .filename_len = 0,
        .content_type_buf = undefined,
        .content_type_len = 0,
    };

    /// Returns the `name` parameter of Content-Disposition; empty if absent.
    pub fn name(header: *const PartHeader) []const u8 {
        assert(header.name_len <= header.name_buf.len);
        return header.name_buf[0..header.name_len];
    }

    /// Returns the `filename` parameter; empty when the part carries none.
    pub fn filename(header: *const PartHeader) []const u8 {
        assert(header.filename_len <= header.filename_buf.len);
        return header.filename_buf[0..header.filename_len];
    }

    /// Returns the part's Content-Type value; empty when absent.
    pub fn contentType(header: *const PartHeader) []const u8 {
        assert(header.content_type_len <= header.content_type_buf.len);
        return header.content_type_buf[0..header.content_type_len];
    }
};

/// Extracts the boundary parameter from a Content-Type value such as
/// `multipart/form-data; boundary=----x` (token or quoted-string, matched
/// case-insensitively per RFC 2046). Returns a slice of `out`, or null when
/// the value is not multipart/form-data or the boundary is absent, empty,
/// or longer than 70 characters.
pub fn boundaryFromContentType(content_type: []const u8, out: *[max_boundary_len]u8) ?[]const u8 {
    var segments = std.mem.splitScalar(u8, content_type, ';');
    const media = std.mem.trim(u8, segments.first(), " \t");
    if (!std.ascii.eqlIgnoreCase(media, "multipart/form-data")) return null;
    while (segments.next()) |segment| {
        const parameter = std.mem.trim(u8, segment, " \t");
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
        const key = std.mem.trim(u8, parameter[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "boundary")) continue;
        var value = std.mem.trim(u8, parameter[equals + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        if (value.len == 0 or value.len > max_boundary_len) return null;
        if (std.mem.indexOfAny(u8, value, "\r\n\"") != null) return null;
        @memcpy(out[0..value.len], value);
        return out[0..value.len];
    }
    return null;
}

/// The streaming parser. Feed it the reader positioned at the first byte of
/// the multipart body and the boundary from the Content-Type header; then
/// alternate `nextPart` and `streamBody`.
pub const Parser = struct {
    reader: *std.Io.Reader,
    boundary_buf: [max_boundary_len]u8,
    boundary_len: u8,
    parts_seen: u32,
    state: State,
    /// The full delimiter `\r\n--<boundary>` and its KMP failure table.
    delimiter_buf: [max_delimiter_len]u8,
    delimiter_len: u8,
    failure: [max_delimiter_len]u8,
    /// Length of the delimiter prefix currently matched by held-back bytes.
    matched: u8,

    /// `at_headers` means a delimiter and its CRLF were consumed and the
    /// next part's header block is pending; it exists so `streamBody` can
    /// finish a boundary without re-scanning.
    const State = enum { preamble, at_headers, in_part, done };

    pub fn init(reader: *std.Io.Reader, boundary: []const u8) Parser {
        assert(boundary.len >= 1);
        assert(boundary.len <= max_boundary_len);
        var parser: Parser = .{
            .reader = reader,
            .boundary_buf = undefined,
            .boundary_len = @intCast(boundary.len),
            .parts_seen = 0,
            .state = .preamble,
            .delimiter_buf = undefined,
            .delimiter_len = @intCast(boundary.len + 4),
            .failure = undefined,
            // Pretend a CRLF was already seen so `--boundary` with no
            // preceding CRLF matches at the very start of the stream.
            .matched = 2,
        };
        @memcpy(parser.boundary_buf[0..boundary.len], boundary);
        @memcpy(parser.delimiter_buf[0..4], "\r\n--");
        @memcpy(parser.delimiter_buf[4..][0..boundary.len], boundary);
        computeFailure(parser.delimiter_buf[0..parser.delimiter_len], &parser.failure);
        return parser;
    }

    /// Fills `failure[i]` with the length of the longest proper prefix of
    /// `delimiter[0 .. i + 1]` that is also its suffix. The loop advances
    /// `i + (length shrink)` each step, so it runs at most `2 * len` times.
    fn computeFailure(delimiter: []const u8, failure: *[max_delimiter_len]u8) void {
        failure[0] = 0;
        var length: usize = 0;
        var i: usize = 1;
        var budget: usize = 2 * max_delimiter_len;
        while (i < delimiter.len) {
            assert(budget > 0);
            budget -= 1;
            if (delimiter[i] == delimiter[length]) {
                length += 1;
                failure[i] = @intCast(length);
                i += 1;
            } else if (length != 0) {
                length = failure[length - 1];
            } else {
                failure[i] = 0;
                i += 1;
            }
        }
    }

    /// Advances to the next part and parses its headers into `header`.
    /// Returns null after the closing boundary. Skips any unread remainder
    /// of the current part's body.
    pub fn nextPart(parser: *Parser, header: *PartHeader) Error!?void {
        switch (parser.state) {
            .done => return null,
            .in_part, .preamble => {
                _ = parser.scanToDelimiter(null, std.math.maxInt(u64)) catch |err| switch (err) {
                    error.PartTooLarge, error.WriteFailed => unreachable, // Null sink.
                    error.TooManyParts, error.PartHeadersTooLarge => unreachable, // Not raised by the scan.
                    error.MalformedMultipart => return error.MalformedMultipart,
                    error.ReadFailed => return error.ReadFailed,
                };
                if (try parser.readTerminator() == .closed) {
                    parser.state = .done;
                    return null;
                }
            },
            .at_headers => {},
        }
        parser.parts_seen += 1;
        if (parser.parts_seen > max_parts) return error.TooManyParts;
        try parser.readPartHeaders(header);
        parser.state = .in_part;
        return {};
    }

    /// Streams the current part's body into `sink`, stopping before the next
    /// boundary; returns the number of body bytes written. The body may be
    /// at most `max_bytes` long, otherwise `error.PartTooLarge`.
    pub fn streamBody(
        parser: *Parser,
        sink: *std.Io.Writer,
        max_bytes: u64,
    ) (Error || error{ PartTooLarge, WriteFailed })!u64 {
        assert(parser.state == .in_part);
        const written = try parser.scanToDelimiter(sink, max_bytes);
        parser.state = switch (try parser.readTerminator()) {
            .closed => .done,
            .part => .at_headers,
        };
        return written;
    }

    /// Consumes stream bytes up to and including the next delimiter,
    /// emitting confirmed body bytes into `sink` (or discarding them when
    /// `sink` is null). Bytes that match a delimiter prefix are held back
    /// until the match resolves, so a near-boundary split across reads of
    /// any size is emitted correctly. The loop consumes one stream byte per
    /// iteration, so it is bounded by the length of the (finite) stream;
    /// end of stream before the delimiter is a malformed body.
    fn scanToDelimiter(
        parser: *Parser,
        sink: ?*std.Io.Writer,
        max_bytes: u64,
    ) (Error || error{ PartTooLarge, WriteFailed })!u64 {
        const delimiter = parser.delimiter_buf[0..parser.delimiter_len];
        var matched: usize = parser.matched;
        var emitted: u64 = 0;
        while (true) {
            const byte = parser.reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => return error.MalformedMultipart,
                error.ReadFailed => return error.ReadFailed,
            };
            if (byte == delimiter[matched]) {
                matched += 1;
                if (matched == delimiter.len) {
                    parser.matched = 0;
                    return emitted;
                }
                continue;
            }
            // Mismatch: of the held `matched` bytes plus `byte`, keep the
            // longest suffix that still prefixes the delimiter and emit the
            // rest. The retreat loop shrinks `matched` every step, so it is
            // bounded by the delimiter length.
            var keep = matched;
            while (keep > 0 and byte != delimiter[keep]) keep = parser.failure[keep - 1];
            if (byte == delimiter[keep]) keep += 1;
            const flush = matched + 1 - keep;
            if (sink != null and emitted + flush > max_bytes) return error.PartTooLarge;
            if (flush > matched) {
                assert(flush == matched + 1);
                if (sink) |writer| {
                    try writer.writeAll(delimiter[0..matched]);
                    try writer.writeByte(byte);
                }
            } else if (sink) |writer| {
                try writer.writeAll(delimiter[0..flush]);
            }
            emitted += flush;
            matched = keep;
        }
    }

    /// Reads the two bytes after a delimiter: `--` closes the body, CRLF
    /// opens a part's header block. Anything else is malformed.
    fn readTerminator(parser: *Parser) Error!enum { part, closed } {
        const first = parser.takeHeaderByte() catch return error.MalformedMultipart;
        const second = parser.takeHeaderByte() catch return error.MalformedMultipart;
        if (first == '-' and second == '-') return .closed;
        if (first == '\r' and second == '\n') return .part;
        return error.MalformedMultipart;
    }

    fn takeHeaderByte(parser: *Parser) error{MalformedMultipart}!u8 {
        return parser.reader.takeByte() catch error.MalformedMultipart;
    }

    /// Reads header lines until the blank line, within the
    /// `max_part_header_bytes` budget, recognizing Content-Disposition and
    /// Content-Type and skipping every other header. The outer loop is
    /// bounded because every line consumes at least two budgeted bytes.
    fn readPartHeaders(parser: *Parser, header: *PartHeader) Error!void {
        header.* = .empty;
        var line_buf: [max_part_header_bytes]u8 = undefined;
        var budget: usize = max_part_header_bytes;
        while (budget > 0) {
            const line = try parser.readHeaderLine(line_buf[0..budget]);
            budget -= line.len + 2;
            if (line.len == 0) return;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse
                return error.MalformedMultipart;
            const header_name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(header_name, "content-disposition")) {
                try parseDisposition(value, header);
            } else if (std.ascii.eqlIgnoreCase(header_name, "content-type")) {
                header.content_type_len = copyBounded(&header.content_type_buf, value);
            }
        }
        return error.PartHeadersTooLarge;
    }

    /// Reads one CRLF-terminated line into `buf`, excluding the CRLF. The
    /// loop is bounded by the remaining header budget; a line that fills it
    /// without a CRLF is oversized.
    fn readHeaderLine(parser: *Parser, buf: []u8) Error![]u8 {
        var length: usize = 0;
        var pending_cr = false;
        while (length + 2 <= buf.len + 2) {
            const byte = try parser.takeHeaderByte();
            if (pending_cr) {
                if (byte == '\n') return buf[0..length];
                return error.MalformedMultipart; // Bare CR inside a header line.
            }
            if (byte == '\r') {
                pending_cr = true;
                continue;
            }
            if (byte == '\n') return error.MalformedMultipart; // Bare LF.
            if (length >= buf.len) return error.PartHeadersTooLarge;
            buf[length] = byte;
            length += 1;
        }
        return error.PartHeadersTooLarge;
    }

    /// Parses `form-data; name="..."; filename="..."`, honoring quoted
    /// strings with backslash escapes. Unknown parameters are skipped. The
    /// cursor advances at least one byte per parameter, bounding the loop.
    fn parseDisposition(value: []const u8, header: *PartHeader) Error!void {
        const semicolon = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
        const kind = std.mem.trim(u8, value[0..semicolon], " \t");
        if (!std.ascii.eqlIgnoreCase(kind, "form-data")) return error.MalformedMultipart;
        var index: usize = @min(semicolon + 1, value.len);
        var scratch: [256]u8 = undefined;
        while (index < value.len) {
            while (index < value.len and (value[index] == ' ' or value[index] == '\t')) index += 1;
            const key_start = index;
            while (index < value.len and value[index] != '=' and value[index] != ';') index += 1;
            const key = std.mem.trim(u8, value[key_start..index], " \t");
            if (index >= value.len or value[index] == ';') {
                index += 1;
                continue;
            }
            index += 1; // Consume '='.
            const parameter = try parseParameterValue(value, &index, &scratch);
            if (std.ascii.eqlIgnoreCase(key, "name")) {
                header.name_len = copyBounded(&header.name_buf, parameter);
            } else if (std.ascii.eqlIgnoreCase(key, "filename")) {
                header.filename_len = copyBounded(&header.filename_buf, parameter);
            }
            if (index < value.len and value[index] == ';') index += 1;
        }
    }

    /// Parses a token or quoted-string parameter value starting at
    /// `index.*`, advancing the cursor past it. Quoted strings may escape
    /// any byte with a backslash. Returns a slice of `scratch`, truncated
    /// to its capacity; the loop is bounded by the value length.
    fn parseParameterValue(
        value: []const u8,
        index: *usize,
        scratch: *[256]u8,
    ) Error![]const u8 {
        var length: usize = 0;
        if (index.* < value.len and value[index.*] == '"') {
            index.* += 1;
            while (index.* < value.len) {
                const byte = value[index.*];
                index.* += 1;
                if (byte == '"') return scratch[0..length];
                var literal = byte;
                if (byte == '\\') {
                    if (index.* >= value.len) return error.MalformedMultipart;
                    literal = value[index.*];
                    index.* += 1;
                }
                if (length < scratch.len) {
                    scratch[length] = literal;
                    length += 1;
                }
            }
            return error.MalformedMultipart; // Unterminated quoted string.
        }
        const start = index.*;
        while (index.* < value.len and value[index.*] != ';' and value[index.*] != ' ' and
            value[index.*] != '\t') index.* += 1;
        const token = value[start..index.*];
        const copied = copyBounded(scratch, token);
        return scratch[0..copied];
    }
};

/// Copies `source` into `dest`, truncating at the buffer's capacity, and
/// returns the copied length.
fn copyBounded(dest: []u8, source: []const u8) u16 {
    const length = @min(dest.len, source.len);
    @memcpy(dest[0..length], source[0..length]);
    return @intCast(length);
}

// Tests.

const TestChunkReader = struct {
    interface: std.Io.Reader,
    source: []const u8,
    position: usize,
    chunk: usize,

    fn init(source: []const u8, buffer: []u8, chunk: usize) TestChunkReader {
        return .{
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .source = source,
            .position = 0,
            .chunk = chunk,
        };
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const reader: *TestChunkReader = @alignCast(@fieldParentPtr("interface", r));
        if (reader.position >= reader.source.len) return error.EndOfStream;
        const remaining = reader.source[reader.position..];
        const wanted = @min(limit.minInt(remaining.len), reader.chunk);
        const written = try w.write(remaining[0..wanted]);
        reader.position += written;
        return written;
    }
};

fn expectPart(
    parser: *Parser,
    expected_name: []const u8,
    expected_filename: []const u8,
    expected_content_type: []const u8,
    expected_body: []const u8,
) !void {
    var header: PartHeader = .empty;
    try std.testing.expect((try parser.nextPart(&header)) != null);
    try std.testing.expectEqualStrings(expected_name, header.name());
    try std.testing.expectEqualStrings(expected_filename, header.filename());
    try std.testing.expectEqualStrings(expected_content_type, header.contentType());
    var body_buf: [1024]u8 = undefined;
    var body_writer = std.Io.Writer.fixed(&body_buf);
    const written = try parser.streamBody(&body_writer, 1024);
    try std.testing.expectEqualStrings(expected_body, body_writer.buffered());
    try std.testing.expectEqual(expected_body.len, written);
}

test "single part" {
    const body = "--B1\r\n" ++
        "Content-Disposition: form-data; name=\"field\"\r\n" ++
        "\r\n" ++
        "hello world\r\n" ++
        "--B1--\r\n";
    var reader = std.Io.Reader.fixed(body);
    var parser = Parser.init(&reader, "B1");
    try expectPart(&parser, "field", "", "", "hello world");
    var header: PartHeader = .empty;
    try std.testing.expect((try parser.nextPart(&header)) == null);
    try std.testing.expect((try parser.nextPart(&header)) == null);
}

test "two parts with a preamble" {
    const body = "ignored preamble\r\n" ++
        "--xyz\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n" ++
        "\r\n" ++
        "first\r\n" ++
        "--xyz\r\n" ++
        "Content-Disposition: form-data; name=\"b\"\r\n" ++
        "X-Ignored: whatever\r\n" ++
        "\r\n" ++
        "second\r\n" ++
        "--xyz--";
    var reader = std.Io.Reader.fixed(body);
    var parser = Parser.init(&reader, "xyz");
    try expectPart(&parser, "a", "", "", "first");
    try expectPart(&parser, "b", "", "", "second");
    var header: PartHeader = .empty;
    try std.testing.expect((try parser.nextPart(&header)) == null);
}

test "part with filename and content type" {
    const body = "--b\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"a \\\"b\\\".txt\"\r\n" ++
        "Content-Type: text/plain; charset=utf-8\r\n" ++
        "\r\n" ++
        "contents\r\n" ++
        "--b--\r\n";
    var reader = std.Io.Reader.fixed(body);
    var parser = Parser.init(&reader, "b");
    try expectPart(&parser, "file", "a \"b\".txt", "text/plain; charset=utf-8", "contents");
}

test "body almost matching the boundary survives, fixed and tiny-chunk readers" {
    // Every prefix of the delimiter appears in the body without completing.
    const payload = "x\r\ny\r\n-z\r\n--w\r\n--bv\r\n--bounv\r\n--boun trailing";
    const body = "--bound\r\n" ++
        "Content-Disposition: form-data; name=\"tricky\"\r\n" ++
        "\r\n" ++
        payload ++ "\r\n" ++
        "--bound--\r\n";

    var fixed_reader = std.Io.Reader.fixed(body);
    var fixed_parser = Parser.init(&fixed_reader, "bound");
    try expectPart(&fixed_parser, "tricky", "", "", payload);

    // The same stream through an 8-byte reader buffer filled 3 bytes at a
    // time, forcing held-back boundary prefixes across every refill.
    var small_buffer: [8]u8 = undefined;
    var chunked = TestChunkReader.init(body, &small_buffer, 3);
    var chunked_parser = Parser.init(&chunked.interface, "bound");
    try expectPart(&chunked_parser, "tricky", "", "", payload);
}

test "missing closing boundary is malformed" {
    const body = "--k\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n" ++
        "\r\n" ++
        "body without end";
    var reader = std.Io.Reader.fixed(body);
    var parser = Parser.init(&reader, "k");
    var header: PartHeader = .empty;
    try std.testing.expect((try parser.nextPart(&header)) != null);
    var sink_buf: [64]u8 = undefined;
    var sink = std.Io.Writer.fixed(&sink_buf);
    try std.testing.expectError(error.MalformedMultipart, parser.streamBody(&sink, 64));
}

test "too many parts" {
    var body_buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&body_buf);
    for (0..max_parts + 1) |_| {
        try writer.writeAll("--m\r\nContent-Disposition: form-data; name=\"p\"\r\n\r\nz\r\n");
    }
    try writer.writeAll("--m--\r\n");
    var reader = std.Io.Reader.fixed(writer.buffered());
    var parser = Parser.init(&reader, "m");
    var header: PartHeader = .empty;
    for (0..max_parts) |_| {
        try std.testing.expect((try parser.nextPart(&header)) != null);
    }
    try std.testing.expectError(error.TooManyParts, parser.nextPart(&header));
}

test "oversized part headers" {
    var body_buf: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&body_buf);
    try writer.writeAll("--h\r\nContent-Disposition: form-data; name=\"a\"\r\nX-Filler: ");
    for (0..max_part_header_bytes) |_| try writer.writeByte('f');
    try writer.writeAll("\r\n\r\nbody\r\n--h--\r\n");
    var reader = std.Io.Reader.fixed(writer.buffered());
    var parser = Parser.init(&reader, "h");
    var header: PartHeader = .empty;
    try std.testing.expectError(error.PartHeadersTooLarge, parser.nextPart(&header));
}

test "boundaryFromContentType accepts tokens and quoted strings" {
    var out: [max_boundary_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "----zen123",
        boundaryFromContentType("multipart/form-data; boundary=----zen123", &out).?,
    );
    try std.testing.expectEqualStrings(
        "a b:c",
        boundaryFromContentType("Multipart/Form-Data; charset=utf-8; BOUNDARY=\"a b:c\"", &out).?,
    );
    try std.testing.expect(boundaryFromContentType("text/plain; boundary=x", &out) == null);
    try std.testing.expect(boundaryFromContentType("multipart/form-data", &out) == null);
    try std.testing.expect(boundaryFromContentType("multipart/form-data; boundary=", &out) == null);
    const oversized = "multipart/form-data; boundary=" ++ "q" ** (max_boundary_len + 1);
    try std.testing.expect(boundaryFromContentType(oversized, &out) == null);
    const at_limit = "multipart/form-data; boundary=" ++ "q" ** max_boundary_len;
    try std.testing.expectEqual(
        @as(usize, max_boundary_len),
        boundaryFromContentType(at_limit, &out).?.len,
    );
}

test "PartTooLarge stops an oversized body" {
    const body = "--p\r\n" ++
        "Content-Disposition: form-data; name=\"big\"\r\n" ++
        "\r\n" ++
        "0123456789abcdef\r\n" ++
        "--p--\r\n";
    var reader = std.Io.Reader.fixed(body);
    var parser = Parser.init(&reader, "p");
    var header: PartHeader = .empty;
    try std.testing.expect((try parser.nextPart(&header)) != null);
    var sink_buf: [64]u8 = undefined;
    var sink = std.Io.Writer.fixed(&sink_buf);
    try std.testing.expectError(error.PartTooLarge, parser.streamBody(&sink, 8));
}
