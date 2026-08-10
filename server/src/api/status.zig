//! `GET /api/v1/status` (ZDS 0016): version, mode, uptime, and bounded
//! counters. Secure mode adds store health once the store lands.

const std = @import("std");
const build_info = @import("zenfmt_build");
const zenserve = @import("zenserve");

const app_mod = @import("../app.zig");

const Context = zenserve.Context;
const HandlerError = zenserve.HandlerError;

pub fn handle(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    const now = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    const uptime_seconds = @divTrunc(
        app.started_at.durationTo(now).raw.nanoseconds,
        std.time.ns_per_s,
    );
    try ctx.respondJson(.ok, .{
        .version = build_info.version,
        .revision = build_info.revision,
        .mode = if (app.options.secure) "secure" else "open",
        .uptime_seconds = @as(i64, @intCast(uptime_seconds)),
        .connections_active = app.kernel.activeConnections(),
        .conversions_active = app.conversions_active.load(.monotonic),
        .conversions_cap = app.conversions_cap,
    });
}
