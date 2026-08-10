//! Secure-mode authentication and administration (ZDS 0016).
//!
//! Principal resolution from the session cookie or a bearer API key, the
//! login and account routes, and the administrator user/audit routes. Every
//! cookie-authenticated state change carries a CSRF token; bearer and
//! API-key requests are CSRF-exempt by construction. The whole surface is
//! the same REST API the interface calls — there are no private endpoints.

const std = @import("std");
const zenserve = @import("zenserve");

const app_mod = @import("app.zig");
const store_mod = @import("store/store.zig");
const schema = @import("store/schema.zig");
const server_reports = @import("reports.zig");

const auth = zenserve.auth;
const Context = zenserve.Context;
const HandlerError = zenserve.HandlerError;
const Principal = zenserve.Principal;

pub const session_cookie = "zenfmt_session";
pub const host_cookie = "__Host-zenfmt_session";
pub const csrf_header = "x-zenfmt-csrf";

/// Resolves the request principal from the cookie or bearer credential.
/// Open-mode routes never reach this; secure mode calls it in the
/// middleware before the role check. A present-but-invalid credential
/// leaves the anonymous principal, which the role check then rejects.
pub fn resolvePrincipal(app: *app_mod.App, ctx: *Context) void {
    ctx.principal = Principal.anonymous_secure;
    const store = &app.store.?;

    // Bearer API key: `Authorization: Bearer zfk_<id>.<secret>`.
    if (headerValue(ctx, "authorization")) |authorization| {
        if (std.mem.startsWith(u8, authorization, "Bearer ")) {
            resolveBearer(store, ctx, authorization["Bearer ".len..]);
            return;
        }
    }

    // Session cookie.
    if (cookieValue(ctx, host_cookie) orelse cookieValue(ctx, session_cookie)) |raw| {
        resolveSession(app, store, ctx, raw);
    }
}

fn resolveBearer(store: *store_mod.Store, ctx: *Context, presented: []const u8) void {
    const bearer = auth.parseBearerKey(presented) orelse return;
    var key: auth.ApiKey = undefined;
    const found = store.authStore().lookupKey(bearer.id, &key) catch return;
    if (!found or key.disabled) return;
    if (!auth.digestEql(key.secret_digest, bearer.secret_digest)) return;
    ctx.principal = .{
        .role = key.role,
        .kind = .api_key,
        .name = ctx.arena.dupe(u8, key.name()) catch "key",
        .user_id = key.user_id,
    };
}

fn resolveSession(app: *app_mod.App, store: *store_mod.Store, ctx: *Context, raw: []const u8) void {
    const token = auth.Token.decode(raw) orelse return;
    const digest = token.digest();
    var session: auth.Session = undefined;
    const found = store.authStore().lookupSession(digest, &session) catch return;
    if (!found or session.disabled) return;
    const now = std.Io.Clock.now(.real, ctx.io).toSeconds();
    if (now >= session.absolute_expiry or now >= session.idle_expiry) return;
    store.authStore().touchSession(digest, now) catch {};
    ctx.principal = .{
        .role = session.role,
        .kind = .session,
        .name = ctx.arena.dupe(u8, session.name()) catch "user",
        .user_id = session.user_id,
        .session_digest = digest,
    };
    // A one-time password gates everything but the password-change route.
    ctx.must_change_password = session.must_change_password;
    ctx.csrf = ctx.arena.dupe(u8, session.csrf()) catch "";
    _ = app;
}

/// Enforces CSRF on cookie-authenticated state changes. Returns true when
/// the request may proceed.
pub fn csrfOk(ctx: *Context) bool {
    if (ctx.principal.kind != .session) return true;
    const method = ctx.request.head.method;
    if (method == .GET or method == .HEAD) return true;
    const presented = headerValue(ctx, csrf_header) orelse return false;
    return ctx.csrf.len > 0 and std.mem.eql(u8, presented, ctx.csrf);
}

// --------------------------------------------------------- login

pub fn login(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const store = &app.store.?;

    var transfer: [4096]u8 = undefined;
    const body = (try ctx.readBodyAlloc(&transfer, 64 * 1024)) orelse return;
    const creds = std.json.parseFromSliceLeaky(Credentials, ctx.arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return app_mod.respondEntry(ctx, server_reports.invalid_credentials, &.{});

    const now = std.Io.Clock.now(.real, ctx.io).toSeconds();
    const user = store.userByName(ctx.arena, creds.name) catch
        return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});

    // Equalize timing: verify against a dummy hash when no account matches.
    const phc = if (user) |u| u.password_phc else auth.dummy_phc;
    const password_ok = auth.verifyPassword(app.gpa, ctx.io, phc, creds.password);
    if (user == null or !password_ok or user.?.disabled) {
        if (user) |u| store.audit(.@"session.login-failed", u.name, u.name, "{}", now);
        app.metrics.counter("zenfmt_auth_failures_total", .{ .kind = .password }).inc();
        return app_mod.respondEntry(ctx, server_reports.invalid_credentials, &.{});
    }

    const account = user.?;
    var token = auth.Token.generate(ctx.io);
    var csrf_token = auth.Token.generate(ctx.io);
    var csrf_buf: [auth.token_hex_len]u8 = undefined;
    const csrf = csrf_token.encode(&csrf_buf);
    store.createSession(
        account.id,
        token.digest(),
        csrf,
        peerText(ctx),
        now,
    ) catch return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});
    store.audit(.@"session.login", account.name, account.name, "{}", now);

    var token_buf: [auth.token_hex_len]u8 = undefined;
    const token_text = token.encode(&token_buf);
    const cookie = try std.fmt.allocPrint(
        ctx.arena,
        "{s}={s}; HttpOnly; SameSite=Strict; Path=/{s}",
        .{
            if (app.options.behind_proxy) host_cookie else session_cookie,
            token_text,
            if (app.options.behind_proxy) "; Secure" else "",
        },
    );
    try ctx.respondJsonHeaders(.ok, &.{.{ .name = "set-cookie", .value = cookie }}, .{
        .name = account.name,
        .role = roleName(account.role),
        .must_change_password = account.must_change_password,
        .csrf = csrf,
    });
}

pub fn logout(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    if (ctx.principal.session_digest) |digest| {
        app.store.?.authStore().revokeSession(digest) catch {};
        app.store.?.audit(.@"session.logout", ctx.principal.name, ctx.principal.name, "{}", nowOf(ctx));
    }
    const cleared = try std.fmt.allocPrint(
        ctx.arena,
        "{s}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0",
        .{if (app.options.behind_proxy) host_cookie else session_cookie},
    );
    try ctx.respondBytes(.no_content, &.{.{ .name = "set-cookie", .value = cleared }}, "");
}

pub fn sessionInfo(ctx: *Context) HandlerError!void {
    try ctx.respondJson(.ok, .{
        .name = ctx.principal.name,
        .role = roleName(ctx.principal.role),
        .csrf = ctx.csrf,
        .must_change_password = ctx.must_change_password,
    });
}

pub fn changePassword(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const store = &app.store.?;
    var transfer: [4096]u8 = undefined;
    const body = (try ctx.readBodyAlloc(&transfer, 64 * 1024)) orelse return;
    const change = std.json.parseFromSliceLeaky(PasswordChange, ctx.arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return app_mod.respondEntry(ctx, server_reports.invalid_credentials, &.{});
    if (change.new_password.len < 8) {
        return app_mod.respondEntry(ctx, server_reports.invalid_credentials, &.{});
    }
    var phc_buf: [auth.phc_buf_len]u8 = undefined;
    const phc = auth.hashPassword(app.gpa, ctx.io, change.new_password, &phc_buf) catch
        return error.OutOfMemory;
    store.setPassword(ctx.principal.user_id, phc, false, nowOf(ctx)) catch
        return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});
    // Every other session of this account is revoked.
    store.revokeUserSessions(ctx.principal.user_id, ctx.principal.session_digest) catch {};
    store.audit(.@"session.password-change", ctx.principal.name, ctx.principal.name, "{}", nowOf(ctx));
    try ctx.respondBytes(.no_content, &.{}, "");
}

// --------------------------------------------------------- api keys

pub fn keys(ctx: *Context) HandlerError!void {
    switch (ctx.request.head.method) {
        .GET => try listKeys(ctx),
        .POST, .PUT => try createKey(ctx),
        else => try app_mod.respondEntry(ctx, server_reports.method_not_allowed, &.{}),
    }
}

fn listKeys(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const rows = app.store.?.listKeys(ctx.arena, ctx.principal.user_id) catch
        return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});
    try ctx.respondJson(.ok, .{ .keys = rows });
}

fn createKey(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const store = &app.store.?;
    var transfer: [4096]u8 = undefined;
    const body = (try ctx.readBodyAlloc(&transfer, 64 * 1024)) orelse return;
    const request = std.json.parseFromSliceLeaky(KeyRequest, ctx.arena, body, .{
        .ignore_unknown_fields = true,
    }) catch KeyRequest{};

    const id = auth.KeyId.generate(ctx.io);
    var secret = auth.Token.generate(ctx.io);
    var secret_buf: [auth.token_hex_len]u8 = undefined;
    const secret_text = secret.encode(&secret_buf);
    const now = nowOf(ctx);
    store.createKey(id.slice(), secret.digest(), ctx.principal.user_id, request.label, now) catch
        return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});
    store.audit(.@"key.create", ctx.principal.name, id.slice(), "{}", now);

    // The bearer secret appears exactly once, in the create response.
    const bearer = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ id.slice(), secret_text });
    try ctx.respondJson(.ok, .{ .id = id.slice(), .label = request.label, .secret = bearer });
}

pub fn revokeKey(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const store = &app.store.?;
    const id = ctx.param orelse
        return app_mod.respondEntry(ctx, server_reports.unknown_route, &.{});
    store.revokeKey(id, ctx.principal.user_id, ctx.principal.role == .administrator) catch |err| switch (err) {
        error.NotFound => return app_mod.respondEntry(ctx, server_reports.unknown_route, &.{}),
        else => return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{}),
    };
    store.audit(.@"key.revoke", ctx.principal.name, id, "{}", nowOf(ctx));
    try ctx.respondBytes(.no_content, &.{}, "");
}

const KeyRequest = struct { label: []const u8 = "api key" };

// --------------------------------------------------------- helpers

const Credentials = struct { name: []const u8, password: []const u8 };
const PasswordChange = struct { new_password: []const u8 };

fn nowOf(ctx: *Context) i64 {
    return std.Io.Clock.now(.real, ctx.io).toSeconds();
}

pub fn roleName(role: auth.Role) []const u8 {
    return switch (role) {
        .anonymous => "anonymous",
        .user => "user",
        .administrator => "administrator",
    };
}

fn headerValue(ctx: *Context, name: []const u8) ?[]const u8 {
    var iterator = ctx.request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn cookieValue(ctx: *Context, name: []const u8) ?[]const u8 {
    const cookies = headerValue(ctx, "cookie") orelse return null;
    var it = std.mem.tokenizeSequence(u8, cookies, "; ");
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn peerText(ctx: *Context) []const u8 {
    return std.fmt.allocPrint(ctx.arena, "{f}", .{ctx.peer}) catch "unknown";
}
