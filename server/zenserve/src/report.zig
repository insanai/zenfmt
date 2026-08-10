//! Server-origin report codes (ZDS 0016, Server report codes).
//!
//! Server failures reuse the engine's report shape with the `server.` prefix.
//! Every code carries its HTTP status from the record's table, a fixed title,
//! and renders as the failure envelope the engine's clients already parse:
//! `{"status":"failed","reports":[...],"exit_class":"..."}`. The out-of-memory
//! envelope is a comptime constant so it can be emitted without allocating.

const std = @import("std");
const assert = std.debug.assert;

/// Every server-origin failure code from the ZDS 0016 table. The enum spelling
/// uses underscores; the wire spelling is `server.` plus the kebab-case name.
pub const Code = enum {
    head_too_large,
    body_too_large,
    unsupported_media,
    missing_input,
    unknown_route,
    method_not_allowed,
    unauthorized,
    invalid_credentials,
    forbidden,
    password_change_required,
    last_administrator,
    rate_limited,
    busy,
    limit_override_forbidden,
    store_unavailable,
    shutting_down,
    open_network_bind,
    out_of_memory,

    /// Returns the stable wire code, for example "server.head-too-large".
    pub fn text(code: Code) []const u8 {
        return switch (code) {
            .head_too_large => "server.head-too-large",
            .body_too_large => "server.body-too-large",
            .unsupported_media => "server.unsupported-media",
            .missing_input => "server.missing-input",
            .unknown_route => "server.unknown-route",
            .method_not_allowed => "server.method-not-allowed",
            .unauthorized => "server.unauthorized",
            .invalid_credentials => "server.invalid-credentials",
            .forbidden => "server.forbidden",
            .password_change_required => "server.password-change-required",
            .last_administrator => "server.last-administrator",
            .rate_limited => "server.rate-limited",
            .busy => "server.busy",
            .limit_override_forbidden => "server.limit-override-forbidden",
            .store_unavailable => "server.store-unavailable",
            .shutting_down => "server.shutting-down",
            .open_network_bind => "server.open-network-bind",
            .out_of_memory => "server.out-of-memory",
        };
    }

    /// Returns the HTTP status from the record's table. `open_network_bind`
    /// is a startup warning with no HTTP response, represented as 0.
    pub fn httpStatus(code: Code) u16 {
        return switch (code) {
            .head_too_large => 431,
            .body_too_large => 413,
            .unsupported_media => 415,
            .missing_input => 400,
            .unknown_route => 404,
            .method_not_allowed => 405,
            .unauthorized => 401,
            .invalid_credentials => 401,
            .forbidden => 403,
            .password_change_required => 403,
            .last_administrator => 409,
            .rate_limited => 429,
            .busy => 503,
            .limit_override_forbidden => 403,
            .store_unavailable => 503,
            .shutting_down => 503,
            .open_network_bind => 0,
            .out_of_memory => 500,
        };
    }

    /// Returns the fixed short title rendered above the problem text.
    pub fn title(code: Code) []const u8 {
        return switch (code) {
            .head_too_large => "THE REQUEST HEAD IS TOO LARGE",
            .body_too_large => "THE REQUEST BODY IS TOO LARGE",
            .unsupported_media => "THE MEDIA TYPE IS NOT ACCEPTED",
            .missing_input => "THE REQUEST BODY IS EMPTY",
            .unknown_route => "NO ROUTE MATCHES THIS PATH",
            .method_not_allowed => "THE METHOD IS NOT ALLOWED HERE",
            .unauthorized => "AUTHENTICATION IS REQUIRED",
            .invalid_credentials => "THE CREDENTIALS WERE REJECTED",
            .forbidden => "THIS ACTION IS FORBIDDEN",
            .password_change_required => "A PASSWORD CHANGE IS REQUIRED",
            .last_administrator => "THE LAST ADMINISTRATOR MUST REMAIN",
            .rate_limited => "THE RATE LIMIT IS EXHAUSTED",
            .busy => "THE SERVER IS BUSY",
            .limit_override_forbidden => "LIMIT OVERRIDES ARE FORBIDDEN",
            .store_unavailable => "THE STORE IS UNAVAILABLE",
            .shutting_down => "THE SERVER IS SHUTTING DOWN",
            .open_network_bind => "OPEN MODE IS BOUND TO THE NETWORK",
            .out_of_memory => "THE SERVER IS OUT OF MEMORY",
        };
    }
};

/// A minimal server-origin report mirroring the engine's Elm-style fields.
/// The strings are short trusted server literals; the shape serializes to
/// JSON without allocation.
pub const Report = struct {
    code: Code,
    problem: []const u8,
    consequence: []const u8,
    direction: []const u8,
};

/// Writes `text` as a JSON string, with quotes, escaping every byte that
/// RFC 8259 requires. The loop is bounded by the input length.
fn writeJsonString(text: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try writer.print("\\u{x:0>4}", .{byte});
            },
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

/// Returns the envelope exit class for a code: "usage" for the 4xx client
/// shapes, "conversion" for the 5xx server shapes.
fn exitClass(code: Code) []const u8 {
    const status = code.httpStatus();
    assert(status == 0 or (status >= 400 and status <= 599));
    return if (status >= 400 and status <= 499) "usage" else "conversion";
}

/// Writes the failure envelope for one server-origin report:
/// `{"status":"failed","reports":[{...}],"exit_class":"..."}`. The report
/// object carries code, title, problem, consequence, one direction, and
/// severity "error", mirroring the engine's JSON report shape.
pub fn writeEnvelope(report: Report, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    assert(report.problem.len > 0);
    assert(report.consequence.len > 0);
    assert(report.direction.len > 0);
    try writer.writeAll("{\"status\":\"failed\",\"reports\":[{\"code\":");
    try writeJsonString(report.code.text(), writer);
    try writer.writeAll(",\"title\":");
    try writeJsonString(report.code.title(), writer);
    try writer.writeAll(",\"problem\":");
    try writeJsonString(report.problem, writer);
    try writer.writeAll(",\"consequence\":");
    try writeJsonString(report.consequence, writer);
    try writer.writeAll(",\"directions\":[{\"title\":\"What you can do\",\"explanation\":");
    try writeJsonString(report.direction, writer);
    try writer.writeAll("}],\"severity\":\"error\"}],\"exit_class\":");
    try writeJsonString(exitClass(report.code), writer);
    try writer.writeAll("}");
}

/// The body-too-large refusal, shared by the declared-length and
/// at-the-cap paths.
pub const body_too_large_report: Report = .{
    .code = .body_too_large,
    .problem = "The request body exceeds the server's body cap.",
    .consequence = "Nothing was converted.",
    .direction = "Send a smaller document, or ask the operator to raise --max-body.",
};

/// The reserved out-of-memory report, mirroring `core.out-of-memory`.
pub const out_of_memory_report: Report = .{
    .code = .out_of_memory,
    .problem = "The server exhausted its static memory budget while handling the request.",
    .consequence = "The request was abandoned; no artifact was produced.",
    .direction = "Retry the request; if the failure repeats, reduce the request size or raise the server's memory budget.",
};

/// The preallocated out-of-memory envelope: the complete HTTP body for
/// `server.out-of-memory`, emitted allocation-free. A test asserts it is
/// byte-identical to `writeEnvelope(out_of_memory_report, ...)`.
pub const out_of_memory_body: []const u8 =
    "{\"status\":\"failed\",\"reports\":[{" ++
    "\"code\":\"server.out-of-memory\"" ++
    ",\"title\":\"THE SERVER IS OUT OF MEMORY\"" ++
    ",\"problem\":\"The server exhausted its static memory budget while handling the request.\"" ++
    ",\"consequence\":\"The request was abandoned; no artifact was produced.\"" ++
    ",\"directions\":[{\"title\":\"What you can do\",\"explanation\":" ++
    "\"Retry the request; if the failure repeats, reduce the request size or raise the server's memory budget.\"}]" ++
    ",\"severity\":\"error\"}],\"exit_class\":\"conversion\"}";

test "every code has nonempty text, title, and the server prefix" {
    for (std.enums.values(Code)) |code| {
        try std.testing.expect(code.text().len > 0);
        try std.testing.expect(code.title().len > 0);
        try std.testing.expect(std.mem.startsWith(u8, code.text(), "server."));
        try std.testing.expect(std.mem.indexOfScalar(u8, code.text(), '_') == null);
    }
}

test "httpStatus matches the record table exactly" {
    const expected = [_]struct { code: Code, status: u16 }{
        .{ .code = .head_too_large, .status = 431 },
        .{ .code = .body_too_large, .status = 413 },
        .{ .code = .unsupported_media, .status = 415 },
        .{ .code = .missing_input, .status = 400 },
        .{ .code = .unknown_route, .status = 404 },
        .{ .code = .method_not_allowed, .status = 405 },
        .{ .code = .unauthorized, .status = 401 },
        .{ .code = .invalid_credentials, .status = 401 },
        .{ .code = .forbidden, .status = 403 },
        .{ .code = .password_change_required, .status = 403 },
        .{ .code = .last_administrator, .status = 409 },
        .{ .code = .rate_limited, .status = 429 },
        .{ .code = .busy, .status = 503 },
        .{ .code = .limit_override_forbidden, .status = 403 },
        .{ .code = .store_unavailable, .status = 503 },
        .{ .code = .shutting_down, .status = 503 },
        .{ .code = .open_network_bind, .status = 0 },
        .{ .code = .out_of_memory, .status = 500 },
    };
    try std.testing.expectEqual(expected.len, std.enums.values(Code).len);
    for (expected) |pair| {
        try std.testing.expectEqual(pair.status, pair.code.httpStatus());
    }
}

test "envelope JSON parses and carries the expected fields" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeEnvelope(.{
        .code = .rate_limited,
        .problem = "The login bucket for this address is empty.",
        .consequence = "The request was refused before authentication.",
        .direction = "Wait for the Retry-After interval, then \"try\" again.",
    }, &writer);
    const body = writer.buffered();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    try std.testing.expectEqualStrings("failed", parsed.object.get("status").?.string);
    try std.testing.expectEqualStrings("usage", parsed.object.get("exit_class").?.string);
    const reports = parsed.object.get("reports").?.array;
    try std.testing.expectEqual(@as(usize, 1), reports.items.len);
    const report = reports.items[0].object;
    try std.testing.expectEqualStrings("server.rate-limited", report.get("code").?.string);
    try std.testing.expectEqualStrings("THE RATE LIMIT IS EXHAUSTED", report.get("title").?.string);
    try std.testing.expectEqualStrings("error", report.get("severity").?.string);
    const directions = report.get("directions").?.array;
    try std.testing.expectEqual(@as(usize, 1), directions.items.len);
    try std.testing.expectEqualStrings(
        "What you can do",
        directions.items[0].object.get("title").?.string,
    );
    try std.testing.expectEqualStrings(
        "Wait for the Retry-After interval, then \"try\" again.",
        directions.items[0].object.get("explanation").?.string,
    );
}

test "out_of_memory_body matches writeEnvelope and mentions memory" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeEnvelope(out_of_memory_report, &writer);
    try std.testing.expectEqualStrings(out_of_memory_body, writer.buffered());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        out_of_memory_body,
        .{},
    );
    try std.testing.expectEqualStrings("failed", parsed.object.get("status").?.string);
    try std.testing.expectEqualStrings("conversion", parsed.object.get("exit_class").?.string);
    const report = parsed.object.get("reports").?.array.items[0].object;
    try std.testing.expectEqualStrings("server.out-of-memory", report.get("code").?.string);
    try std.testing.expect(std.mem.indexOf(u8, report.get("problem").?.string, "memory") != null);
}

test "exit class is usage for every 4xx code and conversion for 5xx" {
    for (std.enums.values(Code)) |code| {
        const status = code.httpStatus();
        if (status >= 400 and status <= 499) {
            try std.testing.expectEqualStrings("usage", exitClass(code));
        } else if (status >= 500) {
            try std.testing.expectEqualStrings("conversion", exitClass(code));
        }
    }
}
