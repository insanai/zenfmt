//! Administrator routes (ZDS 0016): user management and the audit log.
//!
//! Every handler here sits behind the `administrator` role in the route
//! table, so authorization is the single role check; these handlers only
//! enforce the ownership invariants the role cannot express, above all the
//! last-administrator rule.

const std = @import("std");
const zenserve = @import("zenserve");

const app_mod = @import("../app.zig");
const store_mod = @import("../store/store.zig");
const secure = @import("../secure.zig");
const server_reports = @import("../reports.zig");

const auth = zenserve.auth;
const Context = zenserve.Context;
const HandlerError = zenserve.HandlerError;

/// `GET /api/v1/users` — the account table, and `POST` — create.
pub fn users(ctx: *Context) HandlerError!void {
    switch (ctx.request.head.method) {
        .GET => try listUsers(ctx),
        .POST, .PUT => try createUser(ctx),
        else => try app_mod.respondEntry(ctx, server_reports.method_not_allowed, &.{}),
    }
}

fn listUsers(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const rows = app.store.?.listUsers(ctx.arena) catch
        return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});
    try ctx.respondJson(.ok, .{ .users = rows });
}

fn createUser(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const store = &app.store.?;
    var transfer: [4096]u8 = undefined;
    const body = (try ctx.readBodyAlloc(&transfer, 64 * 1024)) orelse return;
    const request = std.json.parseFromSliceLeaky(CreateRequest, ctx.arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return app_mod.respondEntry(ctx, server_reports.invalid_credentials, &.{});
    if (request.name.len == 0) {
        return app_mod.respondEntry(ctx, server_reports.invalid_credentials, &.{});
    }
    const role = parseRole(request.role) orelse
        return app_mod.respondEntry(ctx, server_reports.invalid_credentials, &.{});

    var password: [24]u8 = undefined;
    generatePassword(ctx.io, &password);
    var phc_buf: [auth.phc_buf_len]u8 = undefined;
    const phc = auth.hashPassword(app.gpa, ctx.io, &password, &phc_buf) catch
        return error.OutOfMemory;
    const now = std.Io.Clock.now(.real, ctx.io).toSeconds();
    store.createUser(request.name, role, phc, true, now) catch |err| switch (err) {
        error.Conflict => return app_mod.respondEntry(ctx, server_reports.invalid_credentials, &.{}),
        else => return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{}),
    };
    store.audit(.@"user.create", ctx.principal.name, request.name, "{}", now);
    try ctx.respondJson(.ok, .{
        .name = request.name,
        .role = request.role,
        .password = &password,
    });
}

/// `PATCH /api/v1/users/{name}` — role, status, or a password reset.
pub fn patchUser(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const store = &app.store.?;
    const name = ctx.param orelse
        return app_mod.respondEntry(ctx, server_reports.unknown_route, &.{});
    var transfer: [4096]u8 = undefined;
    const body = (try ctx.readBodyAlloc(&transfer, 64 * 1024)) orelse return;
    const request = std.json.parseFromSliceLeaky(PatchRequest, ctx.arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return app_mod.respondEntry(ctx, server_reports.invalid_credentials, &.{});

    const target = (store.userByName(ctx.arena, name) catch
        return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{})) orelse
        return app_mod.respondEntry(ctx, server_reports.unknown_route, &.{});
    const now = std.Io.Clock.now(.real, ctx.io).toSeconds();

    if (request.role) |role_text| {
        const role = parseRole(role_text) orelse
            return app_mod.respondEntry(ctx, server_reports.invalid_credentials, &.{});
        if (target.role == .administrator and role != .administrator and
            try lastAdministrator(store))
        {
            return app_mod.respondEntry(ctx, server_reports.last_administrator, &.{});
        }
        store.setRole(target.id, role, now) catch
            return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});
        store.audit(.@"user.role", ctx.principal.name, name, "{}", now);
    }
    if (request.disabled) |disabled| {
        if (disabled and target.role == .administrator and try lastAdministrator(store)) {
            return app_mod.respondEntry(ctx, server_reports.last_administrator, &.{});
        }
        store.setDisabled(target.id, disabled, now) catch
            return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});
        if (disabled) store.revokeUserSessions(target.id, null) catch {};
        store.audit(
            if (disabled) .@"user.disable" else .@"user.enable",
            ctx.principal.name,
            name,
            "{}",
            now,
        );
    }
    if (request.reset_password) |reset| {
        if (reset) {
            var password: [24]u8 = undefined;
            generatePassword(ctx.io, &password);
            var phc_buf: [auth.phc_buf_len]u8 = undefined;
            const phc = auth.hashPassword(app.gpa, ctx.io, &password, &phc_buf) catch
                return error.OutOfMemory;
            store.setPassword(target.id, phc, true, now) catch
                return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});
            store.revokeUserSessions(target.id, null) catch {};
            store.audit(.@"user.password-reset", ctx.principal.name, name, "{}", now);
            try ctx.respondJson(.ok, .{ .name = name, .password = &password });
            return;
        }
    }
    try ctx.respondBytes(.no_content, &.{}, "");
}

/// `DELETE /api/v1/users/{name}`.
pub fn deleteUser(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const store = &app.store.?;
    const name = ctx.param orelse
        return app_mod.respondEntry(ctx, server_reports.unknown_route, &.{});
    const target = (store.userByName(ctx.arena, name) catch
        return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{})) orelse
        return app_mod.respondEntry(ctx, server_reports.unknown_route, &.{});
    if (target.role == .administrator and try lastAdministrator(store)) {
        return app_mod.respondEntry(ctx, server_reports.last_administrator, &.{});
    }
    const now = std.Io.Clock.now(.real, ctx.io).toSeconds();
    store.deleteUser(target.id) catch
        return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});
    store.audit(.@"user.delete", ctx.principal.name, name, "{}", now);
    try ctx.respondBytes(.no_content, &.{}, "");
}

/// `GET /api/v1/audit` — the audit log, newest first.
pub fn audit(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const rows = app.store.?.listAudit(ctx.arena, 100) catch
        return app_mod.respondEntry(ctx, server_reports.store_unavailable, &.{});
    try ctx.respondJson(.ok, .{ .audit = rows });
}

fn lastAdministrator(store: *store_mod.Store) HandlerError!bool {
    const count = store.administratorCount() catch return error.OutOfMemory;
    return count <= 1;
}

const CreateRequest = struct { name: []const u8, role: []const u8 };
const PatchRequest = struct {
    role: ?[]const u8 = null,
    disabled: ?bool = null,
    reset_password: ?bool = null,
};

fn parseRole(text: []const u8) ?auth.Role {
    if (std.mem.eql(u8, text, "administrator")) return .administrator;
    if (std.mem.eql(u8, text, "user")) return .user;
    return null;
}

fn generatePassword(io: std.Io, out: *[24]u8) void {
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
    var raw: [24]u8 = undefined;
    io.random(&raw);
    for (out, raw) |*slot, byte| slot.* = alphabet[byte % alphabet.len];
}
