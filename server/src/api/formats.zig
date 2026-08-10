//! `GET /api/v1/formats` (ZDS 0016): the capability document.
//!
//! The format tables and hard caps are comptime strings from the shared
//! capability generators — the same source every binding uses — while the
//! limits object reflects the server's runtime `--limit` overrides, so a
//! client sees the limits this deployment actually enforces.

const std = @import("std");
const zenfmt = @import("zenfmt");
const capabilities = @import("zenfmt_capabilities");
const build_info = @import("zenfmt_build");
const zenserve = @import("zenserve");

const app_mod = @import("../app.zig");

const Context = zenserve.Context;
const HandlerError = zenserve.HandlerError;

const formats_json: []const u8 = blk: {
    @setEvalBranchQuota(200_000);
    break :blk capabilities.formatsJson(
        zenfmt.Default.readers,
        zenfmt.Default.writers,
    );
};

const hard_caps_json: []const u8 = capabilities.hardCapsJson();

pub fn handle(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(app_mod.App);
    var stream = zenfmt.json.WriteStream.init(ctx.arena);
    defer stream.deinit();
    buildDocument(&stream, app) catch return error.OutOfMemory;
    const body = stream.toOwnedSlice() catch return error.OutOfMemory;
    try ctx.respondBytes(.ok, &.{
        .{ .name = "content-type", .value = "application/json" },
    }, body);
}

/// Members appear in canonical (sorted) order; the core write stream
/// enforces it.
fn buildDocument(stream: *zenfmt.json.WriteStream, app: *app_mod.App) !void {
    try stream.beginObject();
    try stream.field("default_output_format");
    try stream.string(zenfmt.default_output_format);
    try stream.field("formats");
    try stream.raw(formats_json);
    try stream.field("hard_caps");
    try stream.raw(hard_caps_json);
    try stream.field("limits");
    try writeLimits(stream, app.options.limits);
    try stream.field("mode");
    try stream.string(if (app.options.secure) "secure" else "open");
    try stream.field("revision");
    try stream.string(build_info.revision);
    try stream.field("schema");
    try stream.integer(1);
    try stream.field("version");
    try stream.string(build_info.version);
    try stream.endObject();
}

/// The limit field names, sorted at comptime for canonical member order.
const sorted_limit_fields = blk: {
    const info = @typeInfo(zenfmt.Limits).@"struct";
    var names: [info.fields.len][]const u8 = undefined;
    for (info.fields, 0..) |field, i| names[i] = field.name;
    @setEvalBranchQuota(20_000);
    std.mem.sortUnstable([]const u8, &names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    const frozen = names;
    break :blk frozen;
};

/// The runtime limits, reflecting `--limit` overrides.
fn writeLimits(stream: *zenfmt.json.WriteStream, limits: zenfmt.Limits) !void {
    try stream.beginObject();
    inline for (sorted_limit_fields) |name| {
        try stream.field(name);
        try stream.integer(@intCast(@field(limits, name)));
    }
    try stream.endObject();
}
