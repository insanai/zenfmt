//! The zenserve request context (ZDS 0016, The zenserve Library).
//!
//! One `Context` travels one request through the application: the parsed
//! head, the per-request arena, the resolved principal, and the response
//! helpers. Every helper answers exactly once; the kernel asserts that a
//! handler either responded or failed, never both, never neither.

const std = @import("std");
const assert = std.debug.assert;

const auth = @import("auth.zig");
const report = @import("report.zig");

/// The authenticated identity of a request: the implicit anonymous user of
/// open mode, a session, or an API key.
pub const Principal = struct {
    role: auth.Role,
    kind: Kind,
    /// The account name, key id, or "anonymous"; borrowed from the request
    /// arena or static memory.
    name: []const u8,
    user_id: i64 = 0,
    /// Set for cookie sessions so handlers can revoke or touch them.
    session_digest: ?auth.Digest = null,

    pub const Kind = enum { anonymous, session, api_key };

    /// Open mode: every request acts as the anonymous `user`.
    pub const anonymous_open: Principal = .{
        .role = .user,
        .kind = .anonymous,
        .name = "anonymous",
    };

    /// Secure mode before authentication: allowed only on `anonymous` routes.
    pub const anonymous_secure: Principal = .{
        .role = .anonymous,
        .kind = .anonymous,
        .name = "anonymous",
    };
};

const json_content_type: std.http.Header = .{
    .name = "content-type",
    .value = "application/json",
};

/// One request in flight.
pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Reset by the kernel after the response flushes; handlers allocate
    /// only from it.
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    peer: std.Io.net.IpAddress,
    /// Sixteen lowercase hex characters, generated per request.
    request_id: [16]u8,
    principal: Principal,
    /// The `{param}` capture of the matched route, when one exists.
    param: ?[]const u8 = null,
    /// The application state; handlers cast it back with `appAs`.
    app: *anyopaque,
    /// The request body cap the kernel enforces for this listener.
    max_body_bytes: u64,
    /// Set by every respond helper; the kernel asserts it on return.
    responded: bool = false,
    /// The status the response carried; valid once `responded` is true.
    responded_status: u16 = 0,
    /// Secure-mode session facts, set during principal resolution: the
    /// per-session CSRF token and whether a one-time password gates the
    /// account. Empty and false for open mode and non-session principals.
    csrf: []const u8 = "",
    must_change_password: bool = false,

    pub fn requestId(ctx: *const Context) []const u8 {
        return &ctx.request_id;
    }

    pub fn appAs(ctx: *Context, comptime T: type) *T {
        return @ptrCast(@alignCast(ctx.app));
    }

    /// The request body reader, honoring `Expect: 100-continue`. The
    /// transfer buffer must outlive every read.
    pub fn bodyReader(ctx: *Context, buffer: []u8) error{WriteFailed}!*std.Io.Reader {
        return ctx.request.readerExpectContinue(buffer) catch return error.WriteFailed;
    }

    /// Reads the whole body into the arena under `limit` bytes. A declared
    /// or actual overrun answers `413 server.body-too-large` (before
    /// inviting the body when the length is declared) and returns null.
    pub fn readBodyAlloc(
        ctx: *Context,
        transfer: []u8,
        limit: u64,
    ) error{ OutOfMemory, WriteFailed, ReadFailed }!?[]const u8 {
        assert(limit > 0);
        if (ctx.request.head.content_length) |declared| {
            if (declared > limit) {
                try ctx.respondReport(report.body_too_large_report);
                return null;
            }
        }
        const reader = try ctx.bodyReader(transfer);
        const bytes = reader.allocRemaining(
            ctx.arena,
            .limited(limit + 1),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                try ctx.respondReport(report.body_too_large_report);
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
        };
        if (bytes.len > limit) {
            try ctx.respondReport(report.body_too_large_report);
            return null;
        }
        return bytes;
    }

    /// Answers with a complete body and flushes.
    pub fn respondBytes(
        ctx: *Context,
        status: std.http.Status,
        extra_headers: []const std.http.Header,
        content: []const u8,
    ) error{WriteFailed}!void {
        assert(!ctx.responded);
        ctx.request.respond(content, .{
            .status = status,
            .extra_headers = extra_headers,
        }) catch return error.WriteFailed;
        ctx.responded = true;
        ctx.responded_status = @intFromEnum(status);
    }

    /// Serializes `value` as JSON into the arena and answers it.
    pub fn respondJson(
        ctx: *Context,
        status: std.http.Status,
        value: anytype,
    ) error{ OutOfMemory, WriteFailed }!void {
        try ctx.respondJsonHeaders(status, &.{}, value);
    }

    /// JSON with additional response headers (e.g. `Set-Cookie`).
    pub fn respondJsonHeaders(
        ctx: *Context,
        status: std.http.Status,
        extra: []const std.http.Header,
        value: anytype,
    ) error{ OutOfMemory, WriteFailed }!void {
        const body = std.json.Stringify.valueAlloc(ctx.arena, value, .{}) catch
            return error.OutOfMemory;
        var headers_buf: [8]std.http.Header = undefined;
        assert(extra.len + 1 <= headers_buf.len);
        headers_buf[0] = json_content_type;
        for (extra, 0..) |header, i| headers_buf[i + 1] = header;
        try ctx.respondBytes(status, headers_buf[0 .. extra.len + 1], body);
    }

    /// Answers a server-origin failure envelope with the code's status.
    pub fn respondReport(ctx: *Context, server_report: report.Report) error{WriteFailed}!void {
        try ctx.respondReportHeaders(server_report, &.{});
    }

    /// Answers a failure envelope with additional response headers
    /// (`Retry-After`, `Allow`, `WWW-Authenticate`).
    pub fn respondReportHeaders(
        ctx: *Context,
        server_report: report.Report,
        extra: []const std.http.Header,
    ) error{WriteFailed}!void {
        assert(!ctx.responded);
        const status_int = report.Code.httpStatus(server_report.code);
        assert(status_int >= 400 and status_int <= 599);
        var body_buf: [2048]u8 = undefined;
        var body: std.Io.Writer = .fixed(&body_buf);
        report.writeEnvelope(server_report, &body) catch unreachable;

        var headers_buf: [8]std.http.Header = undefined;
        assert(extra.len + 1 <= headers_buf.len);
        headers_buf[0] = json_content_type;
        for (extra, 0..) |header, i| headers_buf[i + 1] = header;

        // Never invite a body this response refuses: `respond` would send
        // `100 Continue` first when the head carried an expectation.
        ctx.request.head.expect = null;
        ctx.request.respond(body.buffered(), .{
            .status = @enumFromInt(status_int),
            .keep_alive = status_int != 431 and status_int != 503,
            .extra_headers = headers_buf[0 .. extra.len + 1],
        }) catch return error.WriteFailed;
        ctx.responded = true;
        ctx.responded_status = status_int;
    }

    /// Begins a streaming response (chunked when `content_length` is null)
    /// and returns the body writer. The caller must `end()` it; each
    /// `writer.flush()` followed by `flush()` pushes one chunk.
    pub fn respondStreaming(
        ctx: *Context,
        buffer: []u8,
        status: std.http.Status,
        content_length: ?u64,
        extra_headers: []const std.http.Header,
    ) error{WriteFailed}!std.http.BodyWriter {
        assert(!ctx.responded);
        const body_writer = ctx.request.respondStreaming(buffer, .{
            .content_length = content_length,
            .respond_options = .{
                .status = status,
                .extra_headers = extra_headers,
            },
        }) catch return error.WriteFailed;
        ctx.responded = true;
        ctx.responded_status = @intFromEnum(status);
        return body_writer;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "principals carry the mode's default roles" {
    try testing.expectEqual(auth.Role.user, Principal.anonymous_open.role);
    try testing.expectEqual(auth.Role.anonymous, Principal.anonymous_secure.role);
    try testing.expect(Principal.anonymous_open.session_digest == null);
}
