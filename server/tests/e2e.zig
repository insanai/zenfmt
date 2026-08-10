//! End-to-end loopback suite (ZDS 0016, Testing and Quality Gates).
//!
//! Starts the real server on an ephemeral port and drives it with
//! `std.http.Client`: conversion parity against a direct engine call,
//! content negotiation, the error contract, the operational plane, and the
//! adversarial protocol cases that must refuse promptly and precisely.

const std = @import("std");
const zenfmt = @import("zenfmt");
const server = @import("zenfmt_server");

const testing = std.testing;

// A markdown document exercises the full engine path without a binary
// fixture; detection resolves it from the `.md` extension.
const fixture =
    "# The zenfmt Server\n\nA paragraph with **bold** text.\n\n" ++
    "- one\n- two\n";
const fixture_name = "note.md";

const Harness = struct {
    threaded: std.Io.Threaded,
    instance: server.app.Instance,
    port: u16,

    fn start(options: server.Options) !*Harness {
        const harness = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(harness);
        harness.threaded = .init(testing.allocator, .{});
        errdefer harness.threaded.deinit();
        var patched = options;
        patched.port = 0; // ephemeral
        harness.instance = try server.app.Instance.start(
            testing.allocator,
            harness.threaded.io(),
            patched,
        );
        harness.port = harness.instance.port();
        return harness;
    }

    fn stop(harness: *Harness) void {
        harness.instance.stop();
        harness.threaded.deinit();
        testing.allocator.destroy(harness);
    }

    const Response = struct {
        status: u16,
        body: []const u8,
        set_cookie: ?[]const u8 = null,
        retry_after: ?[]const u8 = null,
    };

    /// One request over a fresh connection; everything allocates from the
    /// caller's arena.
    fn request(
        harness: *Harness,
        arena: std.mem.Allocator,
        method: std.http.Method,
        target: []const u8,
        body: ?[]const u8,
        extra_headers: []const std.http.Header,
    ) !Response {
        const io = harness.threaded.io();
        var client: std.http.Client = .{ .allocator = arena, .io = io };
        defer client.deinit();

        var url_buf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "http://127.0.0.1:{d}{s}",
            .{ harness.port, target },
        );
        // The lower-level request path, so the tests can read `Set-Cookie`.
        const uri = try std.Uri.parse(url);
        var redirect_buf: [2048]u8 = undefined;
        var req = try client.request(method, uri, .{
            .extra_headers = extra_headers,
            .redirect_behavior = .not_allowed,
        });
        defer req.deinit();
        if (body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            try req.sendBodyComplete(@constCast(payload));
        } else {
            try req.sendBodiless();
        }
        var response = try req.receiveHead(&redirect_buf);
        var set_cookie: ?[]const u8 = null;
        var retry_after: ?[]const u8 = null;
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) {
                set_cookie = try arena.dupe(u8, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
                retry_after = try arena.dupe(u8, header.value);
            }
        }
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const response_body = try reader.allocRemaining(arena, .limited(16 * 1024 * 1024));
        return .{
            .status = @intFromEnum(response.head.status),
            .body = response_body,
            .set_cookie = set_cookie,
            .retry_after = retry_after,
        };
    }
};

/// Extracts the session token from a `Set-Cookie` value: everything up to
/// the first `;`, as a ready-to-send `Cookie` header value.
fn cookieHeader(set_cookie: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len;
    return set_cookie[0..semi];
}

fn expectJsonField(
    arena: std.mem.Allocator,
    body: []const u8,
    field: []const u8,
    expected: []const u8,
) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const value = parsed.object.get(field) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(expected, value.string);
}

fn firstReportCode(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const reports = parsed.object.get("reports").?.array;
    return reports.items[0].object.get("code").?.string;
}

fn expectStatus(
    harness: *Harness,
    arena: std.mem.Allocator,
    expected: u16,
    method: std.http.Method,
    target: []const u8,
    body: ?[]const u8,
    headers: []const std.http.Header,
) !void {
    const response = try harness.request(arena, method, target, body, headers);
    try testing.expectEqual(expected, response.status);
}

const Session = struct {
    cookie: []const u8,
    csrf: []const u8,
};

fn loginSession(
    harness: *Harness,
    arena: std.mem.Allocator,
    name: []const u8,
    password: []const u8,
) !Session {
    const body = try std.json.Stringify.valueAlloc(arena, .{
        .name = name,
        .password = password,
    }, .{});
    const response = try harness.request(
        arena,
        .POST,
        "/api/v1/session",
        body,
        &.{.{ .name = "content-type", .value = "application/json" }},
    );
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        response.body,
        .{},
    );
    return .{
        .cookie = cookieHeader(response.set_cookie.?),
        .csrf = parsed.object.get("csrf").?.string,
    };
}

fn changePassword(
    harness: *Harness,
    arena: std.mem.Allocator,
    session: Session,
    password: []const u8,
) !void {
    const body = try std.json.Stringify.valueAlloc(arena, .{
        .new_password = password,
    }, .{});
    const response = try harness.request(
        arena,
        .POST,
        "/api/v1/session/password",
        body,
        &.{
            .{ .name = "cookie", .value = session.cookie },
            .{ .name = "x-zenfmt-csrf", .value = session.csrf },
            .{ .name = "content-type", .value = "application/json" },
        },
    );
    try testing.expectEqual(@as(u16, 204), response.status);
}

fn expectPasswordCsrf(
    harness: *Harness,
    arena: std.mem.Allocator,
    session: Session,
) !void {
    try expectStatus(
        harness,
        arena,
        403,
        .POST,
        "/api/v1/session/password",
        "{\"new_password\":\"a-better-secret\"}",
        &.{
            .{ .name = "cookie", .value = session.cookie },
            .{ .name = "content-type", .value = "application/json" },
        },
    );
    try changePassword(harness, arena, session, "a-better-secret");
}

fn readyAdministrator(
    harness: *Harness,
    arena: std.mem.Allocator,
    bootstrap_password: []const u8,
) !Session {
    const bootstrap = try loginSession(harness, arena, "admin", bootstrap_password);
    try changePassword(harness, arena, bootstrap, "admin-strong-pass");
    return loginSession(harness, arena, "admin", "admin-strong-pass");
}

test "open mode converts and matches the direct engine call byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.start(.{});
    defer harness.stop();

    const response = try harness.request(
        arena,
        .POST,
        "/api/v1/convert?to=markdown",
        fixture,
        &.{.{ .name = "x-zenfmt-name", .value = fixture_name }},
    );
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expect(response.body.len > 0);

    // Direct engine call on the same bytes.
    var direct = zenfmt.convert(testing.allocator, harness.threaded.io(), .{
        .input = .{ .bytes = .{ .name = fixture_name, .data = fixture } },
        .output = .{ .memory = .{ .artifact_name = "note.md" } },
    });
    defer direct.deinit(testing.allocator);
    try testing.expectEqual(zenfmt.Status.success, direct.status);
    try testing.expectEqualStrings(direct.ensemble.?.artifact, response.body);
}

test "the JSON envelope mirrors the conversion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.start(.{});
    defer harness.stop();

    const response = try harness.request(
        arena,
        .POST,
        "/api/v1/convert",
        fixture,
        &.{
            .{ .name = "x-zenfmt-name", .value = fixture_name },
            .{ .name = "accept", .value = "application/json" },
        },
    );
    try testing.expectEqual(@as(u16, 200), response.status);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{});
    const object = parsed.object;
    try testing.expectEqualStrings("success", object.get("status").?.string);
    try testing.expectEqualStrings("note.md", object.get("artifact_name").?.string);
    try testing.expectEqualStrings("markdown", object.get("source_format").?.string);
    try testing.expectEqualStrings("markdown", object.get("output_format").?.string);
    try testing.expect(object.get("artifact").?.string.len > 0);
    try testing.expect(object.get("manifest").? == .object);
    try testing.expect(object.get("reports").? == .array);
}

test "PUT aliases POST for Tika muscle memory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.start(.{});
    defer harness.stop();

    const response = try harness.request(
        arena,
        .PUT,
        "/api/v1/convert?to=markdown",
        fixture,
        &.{.{ .name = "x-zenfmt-name", .value = fixture_name }},
    );
    try testing.expectEqual(@as(u16, 200), response.status);
}

test "the error contract answers with server reports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.start(.{});
    defer harness.stop();

    // Unknown route.
    const missing = try harness.request(arena, .GET, "/api/v1/nope", null, &.{});
    try testing.expectEqual(@as(u16, 404), missing.status);
    try testing.expectEqualStrings(
        "server.unknown-route",
        try firstReportCode(arena, missing.body),
    );

    // Method not allowed.
    const bad_method = try harness.request(arena, .DELETE, "/api/v1/formats", null, &.{});
    try testing.expectEqual(@as(u16, 405), bad_method.status);

    // Empty body.
    const empty = try harness.request(arena, .POST, "/api/v1/convert", "", &.{});
    try testing.expectEqual(@as(u16, 400), empty.status);
    try testing.expectEqualStrings(
        "server.missing-input",
        try firstReportCode(arena, empty.body),
    );

    // Limit overrides are forbidden below administrator.
    const limits = try harness.request(
        arena,
        .POST,
        "/api/v1/convert?limit=max_depth=8",
        fixture,
        &.{},
    );
    try testing.expectEqual(@as(u16, 403), limits.status);
    try testing.expectEqualStrings(
        "server.limit-override-forbidden",
        try firstReportCode(arena, limits.body),
    );

    // Bad strictness spelling.
    const strict = try harness.request(
        arena,
        .POST,
        "/api/v1/convert?strict=hard",
        fixture,
        &.{},
    );
    try testing.expectEqual(@as(u16, 400), strict.status);
    try testing.expectEqualStrings(
        "server.invalid-query",
        try firstReportCode(arena, strict.body),
    );

    // Undetectable input surfaces the engine's usage report.
    const garbage = try harness.request(
        arena,
        .POST,
        "/api/v1/convert",
        "not a document at all",
        &.{.{ .name = "accept", .value = "application/json" }},
    );
    try testing.expectEqual(@as(u16, 400), garbage.status);
    try expectJsonField(arena, garbage.body, "status", "failed");
}

test "body cap refuses oversized declared and actual bodies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.start(.{ .max_body_bytes = 1024 });
    defer harness.stop();

    const big = try arena.alloc(u8, 4096);
    @memset(big, 'a');
    const response = try harness.request(arena, .POST, "/api/v1/convert", big, &.{});
    try testing.expectEqual(@as(u16, 413), response.status);
    try testing.expectEqualStrings(
        "server.body-too-large",
        try firstReportCode(arena, response.body),
    );
}

test "the operational plane answers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.start(.{});
    defer harness.stop();

    const healthz = try harness.request(arena, .GET, "/healthz", null, &.{});
    try testing.expectEqual(@as(u16, 200), healthz.status);
    try testing.expectEqualStrings("ok\n", healthz.body);

    const readyz = try harness.request(arena, .GET, "/readyz", null, &.{});
    try testing.expectEqual(@as(u16, 200), readyz.status);

    const metrics = try harness.request(arena, .GET, "/metrics", null, &.{});
    try testing.expectEqual(@as(u16, 200), metrics.status);
    try testing.expect(std.mem.indexOf(u8, metrics.body, "zenfmt_build_info") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        metrics.body,
        "zenfmt_http_requests_total",
    ) != null);

    const status = try harness.request(arena, .GET, "/api/v1/status", null, &.{});
    try testing.expectEqual(@as(u16, 200), status.status);
    try expectJsonField(arena, status.body, "mode", "open");

    const formats = try harness.request(arena, .GET, "/api/v1/formats", null, &.{});
    try testing.expectEqual(@as(u16, 200), formats.status);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, formats.body, .{});
    try testing.expect(parsed.object.get("formats").?.array.items.len >= 19);
}

test "adversarial: oversized head, malformed request line, slow close" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = arena;

    var harness = try Harness.start(.{});
    defer harness.stop();
    const io = harness.threaded.io();

    // A request head beyond 16 KiB answers 431 and closes.
    {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", harness.port);
        var stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buf: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll("GET / HTTP/1.1\r\nhost: x\r\n");
        var filler: [64]u8 = undefined;
        @memset(&filler, 'a');
        var written: usize = 0;
        while (written < 20 * 1024) : (written += filler.len) {
            writer.interface.writeAll("x-filler: ") catch break;
            writer.interface.writeAll(&filler) catch break;
            writer.interface.writeAll("\r\n") catch break;
        }
        writer.interface.flush() catch {};
        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var response_buf: [4096]u8 = undefined;
        const n = reader.interface.readSliceShort(&response_buf) catch 0;
        try testing.expect(std.mem.indexOf(u8, response_buf[0..n], "431") != null);
    }

    // Protocol garbage is closed without a response.
    {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", harness.port);
        var stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buf: [128]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll("NOT HTTP AT ALL\r\n\r\n");
        try writer.interface.flush();
        var read_buf: [512]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var response_buf: [512]u8 = undefined;
        const n = reader.interface.readSliceShort(&response_buf) catch 0;
        try testing.expectEqual(@as(usize, 0), n);
    }
}

test "the NDJSON batch route streams one envelope per part" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var harness = try Harness.start(.{});
    defer harness.stop();

    const boundary = "zenfmtBOUNDARY";
    const body = try std.fmt.allocPrint(arena, "--{s}\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"a.md\"\r\n\r\n" ++
        "# First\r\n" ++
        "--{s}\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"b.md\"\r\n\r\n" ++
        "# Second\r\n" ++
        "--{s}--\r\n", .{ boundary, boundary, boundary });
    const content_type = try std.fmt.allocPrint(
        arena,
        "multipart/form-data; boundary={s}",
        .{boundary},
    );
    const response = try harness.request(arena, .POST, "/api/v1/convert/batch", body, &.{
        .{ .name = "content-type", .value = content_type },
    });
    try testing.expectEqual(@as(u16, 200), response.status);
    // Two NDJSON lines, each a success envelope.
    var lines = std.mem.tokenizeScalar(u8, response.body, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        try testing.expectEqualStrings("success", parsed.object.get("status").?.string);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "restart binds the same options cleanly" {
    var harness = try Harness.start(.{});
    const port = harness.port;
    harness.stop();
    try testing.expect(port != 0);

    var second = try Harness.start(.{});
    defer second.stop();
    try testing.expect(second.port != 0);
}

// ---------------------------------------------------------- secure mode

const SecureHarness = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    harness: *Harness,
    password: [24]u8,

    fn start() !SecureHarness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var scratch: std.Io.Threaded = .init(testing.allocator, .{});
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(scratch.io(), &path_buf);
        scratch.deinit();
        const dir = try testing.allocator.dupe(u8, path_buf[0..len]);
        errdefer testing.allocator.free(dir);

        const harness = try Harness.start(.{ .secure = true, .data_dir = dir });
        // The bootstrap credential is exposed for the test to log in.
        const bootstrap = server.app.Instance.last_bootstrap orelse return error.NoBootstrap;
        return .{ .tmp = tmp, .dir = dir, .harness = harness, .password = bootstrap.password };
    }

    fn stop(secure: *SecureHarness) void {
        secure.harness.stop();
        testing.allocator.free(secure.dir);
        secure.tmp.cleanup();
    }
};

test "secure mode bootstraps, gates the one-time password, and authenticates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var secure = try SecureHarness.start();
    defer secure.stop();
    const h = secure.harness;

    // The operational plane stays open; the conversion API needs a login.
    try expectStatus(h, arena, 200, .GET, "/healthz", null, &.{});
    try expectStatus(h, arena, 200, .GET, "/", null, &.{});
    try expectStatus(h, arena, 200, .GET, "/login", null, &.{});
    const anon = try h.request(arena, .POST, "/api/v1/convert", "x", &.{});
    try testing.expectEqual(@as(u16, 401), anon.status);
    // The admin plane's users route needs administrator, not just a login.
    const anon_users = try h.request(arena, .GET, "/api/v1/users", null, &.{});
    try testing.expectEqual(@as(u16, 401), anon_users.status);

    // Log in with the bootstrap credential.
    const login_body = try std.fmt.allocPrint(
        arena,
        "{{\"name\":\"admin\",\"password\":\"{s}\"}}",
        .{&secure.password},
    );
    const login = try h.request(arena, .POST, "/api/v1/session", login_body, &.{
        .{ .name = "content-type", .value = "application/json" },
    });
    try testing.expectEqual(@as(u16, 200), login.status);
    try testing.expect(login.set_cookie != null);
    const cookie = cookieHeader(login.set_cookie.?);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, login.body, .{});
    try testing.expect(parsed.object.get("must_change_password").?.bool);
    const csrf = parsed.object.get("csrf").?.string;

    // The one-time password gates everything but the password change.
    const gated = try h.request(arena, .GET, "/api/v1/users", null, &.{
        .{ .name = "cookie", .value = cookie },
    });
    try testing.expectEqual(@as(u16, 403), gated.status);
    try testing.expectEqualStrings(
        "server.password-change-required",
        try firstReportCode(arena, gated.body),
    );

    // Change the password (CSRF required).
    try expectPasswordCsrf(h, arena, .{ .cookie = cookie, .csrf = csrf });
    // The change keeps the current session but clears the one-time gate;
    // every other session of the account was revoked.
    const after = try h.request(arena, .GET, "/api/v1/session", null, &.{
        .{ .name = "cookie", .value = cookie },
    });
    try testing.expectEqual(@as(u16, 200), after.status);
    const after_json = try std.json.parseFromSliceLeaky(std.json.Value, arena, after.body, .{});
    try testing.expect(!after_json.object.get("must_change_password").?.bool);
}

test "secure login rate limit answers with a retry hint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var secure = try SecureHarness.start();
    defer secure.stop();

    // Admission happens before JSON parsing. Malformed credentials exercise
    // the same bucket without making the test depend on Argon2 timing.
    var attempt: usize = 0;
    while (attempt < 10) : (attempt += 1) {
        const response = try secure.harness.request(
            arena,
            .POST,
            "/api/v1/session",
            "{",
            &.{.{ .name = "content-type", .value = "application/json" }},
        );
        try testing.expectEqual(@as(u16, 401), response.status);
    }
    const limited = try secure.harness.request(
        arena,
        .POST,
        "/api/v1/session",
        "{",
        &.{.{ .name = "content-type", .value = "application/json" }},
    );
    try testing.expectEqual(@as(u16, 429), limited.status);
    try testing.expect(limited.retry_after != null);
    try testing.expectEqualStrings(
        "server.rate-limited",
        try firstReportCode(arena, limited.body),
    );
}

test "the role matrix: user cannot reach the admin plane" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var secure = try SecureHarness.start();
    defer secure.stop();
    const h = secure.harness;

    const admin = try readyAdministrator(h, arena, &secure.password);
    const cookie = admin.cookie;
    const csrf = admin.csrf;

    // The administrator creates a plain user.
    const create = try h.request(
        arena,
        .POST,
        "/api/v1/users",
        "{\"name\":\"analyst\",\"role\":\"user\"}",
        &.{
            .{ .name = "cookie", .value = cookie },
            .{ .name = "x-zenfmt-csrf", .value = csrf },
            .{ .name = "content-type", .value = "application/json" },
        },
    );
    try testing.expectEqual(@as(u16, 200), create.status);
    const created = try std.json.parseFromSliceLeaky(std.json.Value, arena, create.body, .{});
    const analyst_password = created.object.get("password").?.string;

    const invalid_name = try h.request(
        arena,
        .POST,
        "/api/v1/users",
        "{\"name\":\"unsafe/name\",\"role\":\"user\"}",
        &.{
            .{ .name = "cookie", .value = cookie },
            .{ .name = "x-zenfmt-csrf", .value = csrf },
            .{ .name = "content-type", .value = "application/json" },
        },
    );
    try testing.expectEqual(@as(u16, 400), invalid_name.status);

    // The user logs in, changes their one-time password, and is refused
    // the admin plane.
    const first_user = try loginSession(h, arena, "analyst", analyst_password);
    try changePassword(h, arena, first_user, "analyst-strong-pass");
    const user = try loginSession(h, arena, "analyst", "analyst-strong-pass");

    // The user may convert but not list users.
    const forbidden = try h.request(arena, .GET, "/api/v1/users", null, &.{
        .{ .name = "cookie", .value = user.cookie },
    });
    try testing.expectEqual(@as(u16, 403), forbidden.status);

    // The last-administrator invariant: the admin cannot demote itself.
    const demote = try h.request(arena, .PATCH, "/api/v1/users/admin", "{\"role\":\"user\"}", &.{
        .{ .name = "cookie", .value = cookie },
        .{ .name = "x-zenfmt-csrf", .value = csrf },
        .{ .name = "content-type", .value = "application/json" },
    });
    try testing.expectEqual(@as(u16, 409), demote.status);
    try testing.expectEqualStrings(
        "server.last-administrator",
        try firstReportCode(arena, demote.body),
    );
}

test "an API key authenticates the conversion route" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var secure = try SecureHarness.start();
    defer secure.stop();
    const h = secure.harness;

    const admin = try readyAdministrator(h, arena, &secure.password);
    const cookie = admin.cookie;
    const csrf = admin.csrf;

    // Create an API key; the secret appears exactly once.
    const key = try h.request(arena, .POST, "/api/v1/keys", "{\"label\":\"ci\"}", &.{
        .{ .name = "cookie", .value = cookie },
        .{ .name = "x-zenfmt-csrf", .value = csrf },
        .{ .name = "content-type", .value = "application/json" },
    });
    try testing.expectEqual(@as(u16, 200), key.status);
    const secret = (try std.json.parseFromSliceLeaky(std.json.Value, arena, key.body, .{}))
        .object.get("secret").?.string;

    // The bearer key converts without a cookie or CSRF.
    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{secret});
    const converted = try h.request(arena, .POST, "/api/v1/convert?to=markdown", fixture, &.{
        .{ .name = "authorization", .value = bearer },
        .{ .name = "x-zenfmt-name", .value = fixture_name },
    });
    try testing.expectEqual(@as(u16, 200), converted.status);

    // Persistence across restart: the store keeps the account and key.
    try testing.expect((try h.request(arena, .GET, "/api/v1/status", null, &.{
        .{ .name = "authorization", .value = bearer },
    })).status == 200);
}
