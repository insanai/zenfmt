//! The zenfmt server application (ZDS 0016, Design Overview).
//!
//! `App` is the type plugged into the zenserve kernel: it owns the route
//! table, the middleware order (request id, timing, principal, role,
//! handler, metrics, log — straight-line code, fixed at compile time), the
//! metric registry, the logger, and the conversion admission counter.
//! `run` owns the process: bind, announce, wait for a signal, drain, exit
//! with the conventional 128-plus-signal code.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const zenfmt = @import("zenfmt");
const build_info = @import("zenfmt_build");
const zenserve = @import("zenserve");
const zaxonlite = @import("zaxonlite");

const root = @import("root.zig");
const app_metrics = @import("metrics.zig");
const envelope = @import("envelope.zig");
const server_reports = @import("reports.zig");
const convert_api = @import("api/convert.zig");
const formats_api = @import("api/formats.zig");
const status_api = @import("api/status.zig");
const admin_api = @import("api/admin.zig");
const ui = @import("ui.zig");
const secure = @import("secure.zig");
const store_mod = @import("store/store.zig");
const schema = @import("store/schema.zig");

const Context = zenserve.Context;
const HandlerError = zenserve.HandlerError;

/// A route plus its mode: `secure` routes are compiled in but answer 404 in
/// open mode, so the role matrix is the single authorization mechanism in
/// both postures (ZDS 0016).
const ModeRoute = struct {
    route: zenserve.Route,
    secure_only: bool = false,
};

fn open(
    method: std.http.Method,
    path: []const u8,
    role: zenserve.Role,
    handler: anytype,
) ModeRoute {
    return .{ .route = .{ .method = method, .path = path, .role = role, .handler = handler } };
}

fn secured(
    method: std.http.Method,
    path: []const u8,
    role: zenserve.Role,
    handler: anytype,
) ModeRoute {
    return .{
        .route = .{ .method = method, .path = path, .role = role, .handler = handler },
        .secure_only = true,
    };
}

const mode_routes = [_]ModeRoute{
    open(.POST, "/api/v1/convert", .user, convert_api.handle),
    open(.POST, "/api/v1/convert/batch", .user, convert_api.handleBatch),
    open(.GET, "/api/v1/formats", .user, formats_api.handle),
    open(.GET, "/api/v1/status", .user, status_api.handle),
    open(.GET, "/healthz", .anonymous, healthzHandler),
    open(.GET, "/readyz", .anonymous, readyzHandler),
    open(.GET, "/metrics", .anonymous, metricsHandler),
    // The shell itself is public. In secure mode the wasm application probes
    // the session endpoint and renders the login page when no session exists;
    // all data and mutations remain protected by the API role matrix.
    open(.GET, "/", .anonymous, ui.shellHandler),
    open(.GET, "/login", .anonymous, ui.shellHandler),
    open(.GET, "/account", .anonymous, ui.shellHandler),
    open(.GET, "/admin/users", .anonymous, ui.shellHandler),
    open(.GET, "/admin/audit", .anonymous, ui.shellHandler),
    open(.GET, "/admin/status", .anonymous, ui.shellHandler),
    open(.GET, "/docs", .anonymous, ui.shellHandler),
    open(.GET, "/openapi.json", .anonymous, ui.openapiHandler),
    open(.GET, "/assets/{name}", .anonymous, ui.assetHandler),
    // Secure-only: sessions, keys, users, audit.
    secured(.POST, "/api/v1/session", .anonymous, secure.login),
    secured(.DELETE, "/api/v1/session", .user, secure.logout),
    secured(.GET, "/api/v1/session", .user, secure.sessionInfo),
    secured(.POST, "/api/v1/session/password", .user, secure.changePassword),
    secured(.GET, "/api/v1/keys", .user, secure.keys),
    secured(.POST, "/api/v1/keys", .user, secure.keys),
    secured(.DELETE, "/api/v1/keys/{id}", .user, secure.revokeKey),
    secured(.GET, "/api/v1/users", .administrator, admin_api.users),
    secured(.POST, "/api/v1/users", .administrator, admin_api.users),
    secured(.PATCH, "/api/v1/users/{name}", .administrator, admin_api.patchUser),
    secured(.DELETE, "/api/v1/users/{name}", .administrator, admin_api.deleteUser),
    secured(.GET, "/api/v1/audit", .administrator, admin_api.audit),
};

const routes = blk: {
    var array: [mode_routes.len]zenserve.Route = undefined;
    for (mode_routes, 0..) |entry, i| array[i] = entry.route;
    const frozen = array;
    break :blk frozen;
};

const Table = zenserve.router.Table(&routes);

fn isSecureOnly(index: usize) bool {
    return mode_routes[index].secure_only;
}

/// The pinned route count (ZDS 0016 acceptance): the oom suite asserts it
/// beside the static out-of-memory report.
pub const route_count = routes.len;

pub const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: root.Options,
    kernel: zenserve.Kernel(App),
    metrics: app_metrics.Registry = .init,
    health: zenserve.health.Health,
    http_ready: *std.atomic.Value(bool),
    logger: zenserve.log.Logger,
    stderr_writer: Io.File.Writer,
    stderr_buffer: [4096]u8,
    conversions_cap: u32,
    conversions_active: std.atomic.Value(u32) = .init(0),
    passwords_active: std.atomic.Value(u32) = .init(0),
    login_rates: zenserve.ratelimit.Buckets(1024) = .init,
    conversion_rates: zenserve.ratelimit.Buckets(2048) = .init,
    started_at: Io.Clock.Timestamp,
    assets: ui.Assets,
    /// The account store; present only in secure mode.
    store: ?store_mod.Store = null,

    /// The kernel calls this for connection-level refusals the handlers
    /// never see.
    pub fn onKernelEvent(app: *App, event: zenserve.kernel.KernelEvent) void {
        switch (event) {
            .busy, .shutting_down => app.metrics.counter(
                "zenfmt_http_rejected_total",
                .{ .reason = .busy },
            ).inc(),
            .head_too_large => app.metrics.counter(
                "zenfmt_http_rejected_total",
                .{ .reason = .head },
            ).inc(),
            .timeout, .malformed_head, .connection_error => {},
        }
        app.logger.emit(app.io, .debug, "http.kernel-event", &.{
            .{ .name = "event", .value = .{ .string = @tagName(event) } },
        });
    }

    /// One request: the fixed middleware order as straight-line code.
    pub fn handle(app: *App, ctx: *Context) void {
        const started = Io.Clock.Timestamp.now(app.io, .awake);
        if (app.options.secure) {
            ctx.principal = zenserve.Principal.anonymous_secure;
            secure.resolvePrincipal(app, ctx);
        } else {
            ctx.principal = zenserve.Principal.anonymous_open;
        }

        const path = zenserve.router.pathOf(ctx.request.head.target);
        const route_label = routeLabel(path);
        const admitted = rateAllowed(app, ctx, path) catch |err| {
            recover(app, ctx, err);
            return;
        };
        if (admitted) dispatch(app, ctx, path) catch |err| recover(app, ctx, err);
        if (!ctx.responded) return;

        const finished = Io.Clock.Timestamp.now(app.io, .awake);
        const nanos = started.durationTo(finished).raw.nanoseconds;
        const seconds = @as(f64, @floatFromInt(nanos)) / std.time.ns_per_s;
        const status = ctx.responded_status;
        app.metrics.counter("zenfmt_http_requests_total", .{
            .route = route_label,
            .method = app_metrics.MethodLabel.of(ctx.request.head.method),
            .status_class = app_metrics.StatusClass.of(status),
        }).inc();
        app.metrics.histogram(
            "zenfmt_http_request_duration_seconds",
            .{ .route = route_label },
        ).observe(seconds);
        app.logger.emit(app.io, .info, "http.request", &.{
            .{ .name = "request_id", .value = .{ .string = ctx.requestId() } },
            .{ .name = "method", .value = .{ .string = @tagName(ctx.request.head.method) } },
            .{ .name = "route", .value = .{ .string = @tagName(route_label) } },
            .{ .name = "status", .value = .{ .unsigned = status } },
            .{
                .name = "duration_ms",
                .value = .{ .unsigned = @intCast(@divTrunc(
                    nanos,
                    std.time.ns_per_ms,
                )) },
            },
            .{ .name = "principal", .value = .{ .string = ctx.principal.name } },
        });
    }

    fn dispatch(app: *App, ctx: *Context, path: []const u8) HandlerError!void {
        switch (Table.match(ctx.request.head.method, path)) {
            .not_found => try respondEntry(ctx, server_reports.unknown_route, &.{}),
            .method_not_allowed => {
                var allow_buf: [64]u8 = undefined;
                const allow = Table.allowedMethods(path, &allow_buf);
                try respondEntry(ctx, server_reports.method_not_allowed, &.{
                    .{ .name = "allow", .value = allow },
                });
            },
            .found => |found| {
                // A secure-only route is invisible in open mode: it answers
                // 404 exactly as a truly absent path does.
                if (!app.options.secure and isSecureOnly(found.index)) {
                    try respondEntry(ctx, server_reports.unknown_route, &.{});
                    return;
                }
                const route = Table.table[found.index];
                if (!ctx.principal.role.atLeast(route.role)) {
                    const entry = if (ctx.principal.role == .anonymous)
                        server_reports.unauthorized
                    else
                        server_reports.forbidden;
                    try respondEntry(ctx, entry, &.{});
                    return;
                }
                // CSRF on cookie-authenticated state changes.
                if (!secure.csrfOk(ctx)) {
                    try respondEntry(ctx, server_reports.forbidden, &.{});
                    return;
                }
                // A one-time password admits only the password-change route.
                if (ctx.must_change_password and !passwordChangeException(ctx, path)) {
                    try respondEntry(ctx, server_reports.password_change_required, &.{});
                    return;
                }
                ctx.param = found.param;
                try route.handler(ctx);
            },
        }
    }

    /// While a one-time password stands, only the password-change route,
    /// reading one's own session, and logging out are permitted.
    fn passwordChangeException(ctx: *Context, path: []const u8) bool {
        const method = ctx.request.head.method;
        if (method == .POST and std.mem.eql(u8, path, "/api/v1/session/password")) return true;
        if (std.mem.eql(u8, path, "/api/v1/session") and
            (method == .GET or method == .DELETE)) return true;
        return false;
    }

    fn recover(app: *App, ctx: *Context, err: HandlerError) void {
        app.logger.emit(app.io, .warn, "http.handler-error", &.{
            .{ .name = "request_id", .value = .{ .string = ctx.requestId() } },
            .{ .name = "error", .value = .{ .string = @errorName(err) } },
        });
        if (ctx.responded) return;
        switch (err) {
            error.OutOfMemory => {
                // The static, allocation-free reserve (ZDS 0016).
                ctx.respondBytes(
                    .internal_server_error,
                    &.{.{ .name = "content-type", .value = "application/json" }},
                    zenserve.report.out_of_memory_body,
                ) catch {};
            },
            // The connection is in an unknown state; the kernel closes it.
            error.WriteFailed, error.ReadFailed, error.Canceled => {},
        }
    }
};

fn rateAllowed(app: *App, ctx: *Context, path: []const u8) HandlerError!bool {
    const method = ctx.request.head.method;
    const login = app.options.secure and method == .POST and
        std.mem.eql(u8, path, "/api/v1/session");
    const conversion = app.options.secure and
        (method == .POST or method == .PUT) and
        (std.mem.eql(u8, path, "/api/v1/convert") or
            std.mem.eql(u8, path, "/api/v1/convert/batch"));
    if (!login and !conversion) return true;

    const now_ms = Io.Clock.Timestamp.now(app.io, .awake).raw.toMilliseconds();
    const key = rateKey(ctx);
    const decision = if (login)
        app.login_rates.allow(app.io, key, .{
            .capacity = 10,
            .refill_milli_per_second = 167,
        }, now_ms)
    else
        app.conversion_rates.allow(app.io, key, .{
            .capacity = 60,
            .refill_milli_per_second = 1000,
        }, now_ms);
    if (decision.allowed) return true;

    app.metrics.counter("zenfmt_http_rejected_total", .{ .reason = .rate }).inc();
    var retry_buf: [12]u8 = undefined;
    const retry = std.fmt.bufPrint(
        &retry_buf,
        "{d}",
        .{decision.retry_after_seconds},
    ) catch unreachable;
    try respondEntry(ctx, server_reports.rate_limited, &.{
        .{ .name = "retry-after", .value = retry },
    });
    return false;
}

fn rateKey(ctx: *const Context) u64 {
    if (ctx.principal.user_id != 0) return @bitCast(ctx.principal.user_id);
    return switch (ctx.peer) {
        .ip4 => |ip4| std.hash.Wyhash.hash(0x7a656e666d7434, &ip4.bytes),
        .ip6 => |ip6| std.hash.Wyhash.hash(0x7a656e666d7436, &ip6.bytes),
    };
}

fn routeLabel(path: []const u8) app_metrics.RouteName {
    if (std.mem.eql(u8, path, "/api/v1/convert")) return .convert;
    if (std.mem.eql(u8, path, "/api/v1/formats")) return .formats;
    if (std.mem.eql(u8, path, "/api/v1/status")) return .status;
    if (std.mem.eql(u8, path, "/healthz")) return .healthz;
    if (std.mem.eql(u8, path, "/readyz")) return .readyz;
    if (std.mem.eql(u8, path, "/metrics")) return .metrics;
    if (std.mem.eql(u8, path, "/")) return .ui;
    return .other;
}

pub fn respondEntry(
    ctx: *Context,
    entry: server_reports.Entry,
    extra: []const std.http.Header,
) HandlerError!void {
    const body = envelope.writeServerFailure(ctx.arena, entry) catch
        return error.OutOfMemory;
    var headers_buf: [8]std.http.Header = undefined;
    assert(extra.len + 1 <= headers_buf.len);
    headers_buf[0] = .{ .name = "content-type", .value = "application/json" };
    for (extra, 0..) |header, i| headers_buf[i + 1] = header;
    ctx.request.head.expect = null;
    try ctx.respondBytes(
        @enumFromInt(entry.status),
        headers_buf[0 .. extra.len + 1],
        body,
    );
}

// ------------------------------------------------- operational plane

fn healthzHandler(ctx: *Context) HandlerError!void {
    try ctx.respondBytes(.ok, &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
    }, "ok\n");
}

fn readyzHandler(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(App);
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    const ready = app.health.writeReadiness(&writer) catch return error.WriteFailed;
    try ctx.respondBytes(if (ready) .ok else .service_unavailable, &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
    }, writer.buffered());
}

fn metricsHandler(ctx: *Context) HandlerError!void {
    const app = ctx.appAs(App);
    app.metrics.gauge("zenfmt_http_connections_active", {})
        .set(@intCast(app.kernel.activeConnections()));
    var collected: std.Io.Writer.Allocating = .init(ctx.arena);
    app_metrics.writeBuildInfo(
        &collected.writer,
        build_info.version,
        build_info.revision,
    ) catch return error.OutOfMemory;
    app.metrics.render(&collected.writer) catch return error.OutOfMemory;
    try ctx.respondBytes(.ok, &.{
        .{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" },
    }, collected.written());
}

// ------------------------------------------------------------- process

/// A running server instance: the test seam. `run` wraps it with signal
/// handling; the loopback suite drives it directly.
pub const Instance = struct {
    app: *App,

    /// The one-time bootstrap credential, returned to `run` so it can print
    /// it to stderr exactly once, framed apart from the log stream.
    pub var last_bootstrap: ?store_mod.Bootstrap = null;

    pub fn start(
        gpa: std.mem.Allocator,
        io: Io,
        options: root.Options,
    ) !Instance {
        if (options.secure and !isLoopback(options.address) and
            !options.behind_proxy and !options.allow_insecure_network)
        {
            return error.InsecureNetwork;
        }
        const app = try createApp(gpa, io, options);
        errdefer destroyApp(app);
        last_bootstrap = try openSecureStore(app);
        errdefer if (app.store) |*store| store.close();
        try startKernel(app);
        return .{ .app = app };
    }

    pub fn port(instance: *const Instance) u16 {
        return instance.app.kernel.boundPort();
    }

    pub fn stop(instance: *Instance) void {
        const app = instance.app;
        app.http_ready.store(false, .release);
        app.logger.emit(app.io, .info, "server.stop", &.{});
        app.kernel.stop();
        if (app.store) |*store| {
            store.audit(
                .@"server.stop",
                "system",
                "server",
                "{}",
                std.Io.Clock.now(.real, app.io).toSeconds(),
            );
            store.close();
        }
        app.assets.deinit(app.gpa);
        app.gpa.destroy(app);
        instance.app = undefined;
    }
};

fn createApp(gpa: std.mem.Allocator, io: Io, options: root.Options) !*App {
    const app = try gpa.create(App);
    errdefer gpa.destroy(app);
    app.* = .{
        .gpa = gpa,
        .io = io,
        .options = options,
        .kernel = undefined,
        .health = .init,
        .http_ready = undefined,
        .logger = undefined,
        .stderr_writer = undefined,
        .stderr_buffer = undefined,
        .conversions_cap = options.conversions orelse
            @intCast(@max(1, std.Thread.getCpuCount() catch 1)),
        .started_at = Io.Clock.Timestamp.now(io, .awake),
        .assets = try ui.Assets.init(gpa),
    };
    errdefer app.assets.deinit(gpa);
    app.stderr_writer = Io.File.stderr().writerStreaming(io, &app.stderr_buffer);
    app.logger = .{
        .format = options.log_format,
        .level = switch (options.log_level) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
        },
        .out = &app.stderr_writer.interface,
    };
    app.http_ready = app.health.register("http");
    return app;
}

fn destroyApp(app: *App) void {
    app.assets.deinit(app.gpa);
    app.gpa.destroy(app);
}

fn openSecureStore(app: *App) !?store_mod.Bootstrap {
    if (!app.options.secure) return null;
    const store_ready = app.health.register("store");
    zaxonlite.durability.setSyncMode(.full);
    var bootstrap: ?store_mod.Bootstrap = null;
    app.store = try store_mod.Store.open(
        app.gpa,
        app.io,
        app.options.data_dir.?,
        &bootstrap,
    );
    app.store.?.audit(
        .@"server.start",
        "system",
        "server",
        "{}",
        std.Io.Clock.now(.real, app.io).toSeconds(),
    );
    app.store.?.pruneAudit(std.Io.Clock.now(.real, app.io).toSeconds());
    store_ready.store(true, .release);
    return bootstrap;
}

fn startKernel(app: *App) !void {
    const options = app.options;
    app.kernel = .{
        .gpa = app.gpa,
        .io = app.io,
        .app = app,
        .options = .{
            .address = options.address,
            .port = options.port,
            .connections = options.connections,
            .drain_seconds = options.drain_seconds,
            .max_body_bytes = options.max_body_bytes,
        },
    };
    try app.kernel.start();
    app.http_ready.store(true, .release);
    app.logger.emit(app.io, .info, "server.start", &.{
        .{ .name = "version", .value = .{ .string = build_info.version } },
        .{ .name = "revision", .value = .{ .string = build_info.revision } },
        .{
            .name = "mode",
            .value = .{ .string = if (options.secure) "secure" else "open" },
        },
        .{ .name = "address", .value = .{ .string = options.address } },
        .{ .name = "port", .value = .{ .unsigned = app.kernel.boundPort() } },
    });
}

var requested_exit_code: std.atomic.Value(u8) = .init(0);

fn requestStop(exit_code: u8) void {
    const previous = requested_exit_code.swap(exit_code, .monotonic);
    // A second signal skips the drain entirely.
    if (previous != 0) std.process.exit(previous);
}

const PlatformSignals = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const Handler = *const fn (u32) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?Handler,
        add: windows.BOOL,
    ) callconv(.winapi) windows.BOOL;

    fn handler(kind: u32) callconv(.winapi) windows.BOOL {
        // CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT,
        // and CTRL_SHUTDOWN_EVENT all request the same bounded drain.
        switch (kind) {
            0, 1, 2, 5, 6 => {
                requestStop(130);
                return windows.BOOL.TRUE;
            },
            else => return .FALSE,
        }
    }

    fn install() void {
        _ = SetConsoleCtrlHandler(handler, windows.BOOL.TRUE);
    }
} else struct {
    fn handler(sig: std.posix.SIG) callconv(.c) void {
        requestStop(128 +| @as(u8, @intCast(@intFromEnum(sig))));
    }

    fn install() void {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }
};

/// The process entry: start, announce, wait for a signal, drain, exit.
pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    options: root.Options,
    err_out: *Io.Writer,
) u8 {
    // Open mode on a non-loopback bind is loud. Secure mode refuses that
    // posture unless TLS termination or an explicit cleartext acknowledgement
    // was selected by the operator.
    if (!options.secure and !isLoopback(options.address)) {
        zenfmt.report.renderText(
            &.{server_reports.open_network_bind},
            err_out,
            .{},
        ) catch {};
        err_out.flush() catch {};
    }

    var instance = Instance.start(gpa, io, options) catch |err| {
        err_out.print(
            "zenfmt serve: cannot start on {s}:{d}: {t}\n",
            .{ options.address, options.port, err },
        ) catch {};
        err_out.flush() catch {};
        return 1;
    };

    // The bootstrap credential prints once, framed apart from the logs.
    if (Instance.last_bootstrap) |bootstrap| {
        err_out.print(
            \\
            \\========================================================
            \\  zenfmt secure mode: first-run administrator account
            \\  name:     {s}
            \\  password: {s}
            \\  This one-time password must be changed at first login.
            \\  It will not be shown again.
            \\========================================================
            \\
            \\
        ,
            .{ bootstrap.nameSlice(), &bootstrap.password },
        ) catch {};
        err_out.flush() catch {};
    }
    requested_exit_code.store(0, .monotonic);
    PlatformSignals.install();

    while (requested_exit_code.load(.monotonic) == 0) {
        io.sleep(.fromMilliseconds(200), .awake) catch break;
    }
    const exit_code = requested_exit_code.load(.monotonic);
    instance.stop();
    return exit_code;
}

fn isLoopback(address: []const u8) bool {
    const parsed = Io.net.IpAddress.parse(address, 0) catch return false;
    const loopback6 = [1]u8{0} ** 15 ++ [1]u8{1};
    return switch (parsed) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| std.mem.eql(u8, &ip6.bytes, &loopback6),
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "route labels map the table" {
    try testing.expectEqual(app_metrics.RouteName.convert, routeLabel("/api/v1/convert"));
    try testing.expectEqual(app_metrics.RouteName.metrics, routeLabel("/metrics"));
    try testing.expectEqual(app_metrics.RouteName.other, routeLabel("/nope"));
}

test "the route count is pinned" {
    try testing.expectEqual(@as(usize, 28), route_count);
}
