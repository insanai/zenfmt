//! The zenfmt server interface module (ZDS 0016, The Web Interface).
//!
//! Compiled to `wasm32-freestanding` and embedded in the server binary;
//! compiled natively for the golden tests. The module owns every page,
//! every fragment of markup, and all interface state. The glue owns the
//! browser: it forwards events in as length-prefixed JSON and executes the
//! returned command list. The network stays in the glue — this module
//! decides *what* to request, never *how*.
//!
//! The interface is client number one of the public REST API: it calls
//! exactly the routes ZDS 0016 specifies, with no private endpoints.

const std = @import("std");
const builtin = @import("builtin");

const render = @import("render.zig");
pub const Commands = @import("commands.zig").Commands;

/// The command protocol version; the glue refuses a mismatch at load.
pub const abi_version: u32 = 1;

pub const Theme = enum { system, light, dark };
pub const Scheme = enum { light, dark };
pub const Mode = enum { unknown, open, secure };
pub const Role = enum { anonymous, user, administrator };

pub const fetch_formats_id: u32 = 1;
pub const fetch_convert_id: u32 = 2;
pub const fetch_session_id: u32 = 3;
pub const fetch_login_id: u32 = 4;
pub const fetch_password_id: u32 = 5;
pub const fetch_users_id: u32 = 6;
pub const fetch_create_user_id: u32 = 7;
pub const fetch_patch_user_id: u32 = 8;
pub const fetch_delete_user_id: u32 = 9;
pub const fetch_audit_id: u32 = 10;
pub const fetch_status_id: u32 = 11;
pub const fetch_keys_id: u32 = 12;
pub const fetch_create_key_id: u32 = 13;
pub const fetch_revoke_key_id: u32 = 14;
pub const fetch_logout_id: u32 = 15;

pub const max_file_name = 256;
pub const max_artifact_preview = 256 * 1024;

/// One conversion outcome, retained until the next conversion.
pub const Result = struct {
    ok: bool,
    artifact: []const u8,
    artifact_name: []const u8,
    report_count: usize,
    /// Pre-rendered report panels (escaped HTML).
    reports_html: []const u8,
};

pub const UserSummary = struct {
    name: []const u8,
    role: []const u8,
    disabled: bool,
    must_change_password: bool,
    created_at: i64,
};

pub const AuditRecord = struct {
    at: i64,
    actor: []const u8,
    action: []const u8,
    subject: []const u8,
};

pub const KeySummary = struct {
    id: []const u8,
    label: []const u8,
    disabled: bool,
    created_at: i64,
};

/// The whole interface state; one instance lives for the page's lifetime.
pub const State = struct {
    gpa: std.mem.Allocator,
    path: []const u8 = "/",
    mode: Mode = .unknown,
    authenticated: bool = false,
    session_name: []const u8 = "",
    role: Role = .anonymous,
    csrf: []const u8 = "",
    must_change_password: bool = false,
    stored_theme: Theme = .system,
    system_scheme: Scheme = .light,
    file_name_buf: [max_file_name]u8 = undefined,
    file_name_len: usize = 0,
    file_size: u64 = 0,
    busy: bool = false,
    writers: []const []const u8 = &.{},
    formats_loaded: bool = false,
    selected_to: []const u8 = "markdown",
    selected_strict: []const u8 = "off",
    result: ?Result = null,
    failure_html: ?[]const u8 = null,
    users: []const UserSummary = &.{},
    audit: []const AuditRecord = &.{},
    keys: []const KeySummary = &.{},
    selected_user: []const u8 = "",
    user_query: []const u8 = "",
    user_role_filter: []const u8 = "all",
    user_status_filter: []const u8 = "all",
    one_time_secret: []const u8 = "",
    one_time_subject: []const u8 = "",
    notice: []const u8 = "",

    pub fn fileName(state: *const State) ?[]const u8 {
        if (state.file_name_len == 0) return null;
        return state.file_name_buf[0..state.file_name_len];
    }

    pub fn effectiveScheme(state: *const State) Scheme {
        return switch (state.stored_theme) {
            .system => state.system_scheme,
            .light => .light,
            .dark => .dark,
        };
    }

    pub fn isAdministrator(state: *const State) bool {
        return state.role == .administrator;
    }
};

/// One glue→module event, decoded from JSON.
const Event = struct {
    event: []const u8,
    path: ?[]const u8 = null,
    stored_theme: ?[]const u8 = null,
    system_scheme: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    name: ?[]const u8 = null,
    size: ?u64 = null,
    fields: ?std.json.Value = null,
    id: ?u32 = null,
    status: ?u16 = null,
    content_type: ?[]const u8 = null,
    body: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

/// Handles one event and returns the serialized command list, allocated
/// from `arena`. This is the seam the native golden tests drive.
pub fn handleEvent(
    arena: std.mem.Allocator,
    state: *State,
    event_json: []const u8,
) ![]const u8 {
    const event = std.json.parseFromSliceLeaky(Event, arena, event_json, .{
        .ignore_unknown_fields = true,
    }) catch return "[]";
    var commands = Commands.init(arena);

    if (std.mem.eql(u8, event.event, "init")) {
        try handleInit(arena, state, event, &commands);
    } else if (std.mem.eql(u8, event.event, "route_change")) {
        try rememberPath(state, event.path orelse "/");
        try renderPage(arena, state, &commands);
        try fetchPageData(state, &commands);
    } else if (std.mem.eql(u8, event.event, "color_scheme_change")) {
        state.system_scheme = parseScheme(event.scheme orelse "light");
        if (state.stored_theme == .system) {
            try commands.themeApply(state.effectiveScheme());
        }
        try renderPage(arena, state, &commands);
    } else if (std.mem.eql(u8, event.event, "file")) {
        try handleFile(state, event);
        try renderPage(arena, state, &commands);
    } else if (std.mem.eql(u8, event.event, "action")) {
        try handleAction(arena, state, event, &commands);
    } else if (std.mem.eql(u8, event.event, "fetch_done")) {
        try handleFetchDone(arena, state, event, &commands);
    } else if (std.mem.eql(u8, event.event, "fetch_error")) {
        state.busy = false;
        if (event.id == fetch_formats_id) state.formats_loaded = true;
        state.failure_html = try render.transportFailure(
            state.gpa,
            event.message orelse "the request failed",
        );
        try renderPage(arena, state, &commands);
    }
    return commands.finish();
}

fn handleInit(
    arena: std.mem.Allocator,
    state: *State,
    event: Event,
    commands: *Commands,
) !void {
    try rememberPath(state, event.path orelse "/");
    state.stored_theme = parseTheme(event.stored_theme orelse "system");
    state.system_scheme = parseScheme(event.system_scheme orelse "light");
    try commands.title("zenfmt");
    try commands.themeApply(state.effectiveScheme());
    try renderPage(arena, state, commands);
    // A 404 means open mode because the session route is secure-only. A 401
    // means secure mode without a session. A 200 response supplies the
    // in-memory CSRF token and role. This keeps the shell public without
    // adding a private bootstrap endpoint.
    try commands.fetch(fetch_session_id, "GET", "/api/v1/session", "none");
}

fn handleFile(state: *State, event: Event) !void {
    const name = event.name orelse return;
    const len = @min(name.len, max_file_name);
    @memcpy(state.file_name_buf[0..len], name[0..len]);
    state.file_name_len = len;
    state.file_size = event.size orelse 0;
    state.failure_html = null;
}

fn handleAction(
    arena: std.mem.Allocator,
    state: *State,
    event: Event,
    commands: *Commands,
) !void {
    const name = event.name orelse return;
    if (try handleConversionAction(arena, state, event, commands, name)) return;
    if (try handleSessionAction(arena, state, event, commands, name)) return;
    if (try handleUserViewAction(arena, state, event, commands, name)) return;
    if (try handleUserMutationAction(arena, state, event, commands, name)) return;
    if (try handleDeleteUserAction(arena, state, event, commands, name)) return;
    _ = try handleKeyAction(arena, state, event, commands, name);
}

fn handleConversionAction(
    arena: std.mem.Allocator,
    state: *State,
    event: Event,
    commands: *Commands,
    name: []const u8,
) !bool {
    if (std.mem.eql(u8, name, "theme_system")) {
        try applyTheme(arena, state, .system, commands);
    } else if (std.mem.eql(u8, name, "theme_light")) {
        try applyTheme(arena, state, .light, commands);
    } else if (std.mem.eql(u8, name, "theme_dark")) {
        try applyTheme(arena, state, .dark, commands);
    } else if (std.mem.eql(u8, name, "convert")) {
        try captureFields(state, event);
        if (state.fileName() == null) {
            state.failure_html = try render.transportFailure(
                state.gpa,
                "pick or drop a document first",
            );
            try renderPage(arena, state, commands);
            return true;
        }
        clearResult(state);
        state.busy = true;
        state.failure_html = null;
        try renderPage(arena, state, commands);
        const path = try std.fmt.allocPrint(
            arena,
            "/api/v1/convert?to={s}{s}{s}",
            .{
                state.selected_to,
                if (std.mem.eql(u8, state.selected_strict, "off")) "" else "&strict=",
                if (std.mem.eql(u8, state.selected_strict, "off"))
                    ""
                else
                    state.selected_strict,
            },
        );
        try commands.fetchFile(fetch_convert_id, path, state.csrf);
    } else if (std.mem.eql(u8, name, "download")) {
        if (state.result) |result| {
            try commands.download(result.artifact_name, "text/markdown", result.artifact);
        }
    } else return false;
    return true;
}

fn clearResult(state: *State) void {
    const result = state.result orelse return;
    if (result.artifact.len > 0) state.gpa.free(result.artifact);
    if (result.artifact_name.len > 0) state.gpa.free(result.artifact_name);
    if (result.reports_html.len > 0) state.gpa.free(result.reports_html);
    state.result = null;
}

fn handleSessionAction(
    arena: std.mem.Allocator,
    state: *State,
    event: Event,
    commands: *Commands,
    name: []const u8,
) !bool {
    if (std.mem.eql(u8, name, "login")) {
        const fields = event.fields orelse return true;
        const user = fieldString(fields, "name") orelse "";
        const password = fieldString(fields, "password") orelse "";
        const body = try std.json.Stringify.valueAlloc(arena, .{
            .name = user,
            .password = password,
        }, .{});
        state.busy = true;
        state.failure_html = null;
        try renderPage(arena, state, commands);
        try commands.fetchJson(fetch_login_id, "POST", "/api/v1/session", body, "");
    } else if (std.mem.eql(u8, name, "change_password")) {
        const fields = event.fields orelse return true;
        const password = fieldString(fields, "new_password") orelse "";
        const body = try std.json.Stringify.valueAlloc(arena, .{
            .new_password = password,
        }, .{});
        try commands.fetchJson(
            fetch_password_id,
            "POST",
            "/api/v1/session/password",
            body,
            state.csrf,
        );
    } else if (std.mem.eql(u8, name, "logout")) {
        try commands.fetchJson(
            fetch_logout_id,
            "DELETE",
            "/api/v1/session",
            "",
            state.csrf,
        );
    } else if (std.mem.startsWith(u8, name, "nav:")) {
        const path = name["nav:".len..];
        if (!pathAllowed(state, path)) return true;
        try rememberPath(state, path);
        try commands.navigate(path);
        try renderPage(arena, state, commands);
        try fetchPageData(state, commands);
    } else return false;
    return true;
}

fn handleUserViewAction(
    arena: std.mem.Allocator,
    state: *State,
    event: Event,
    commands: *Commands,
    name: []const u8,
) !bool {
    if (std.mem.eql(u8, name, "create_user_dialog")) {
        state.selected_user = "";
        try renderPage(arena, state, commands);
        try commands.dialogOpen("user-dialog");
    } else if (std.mem.eql(u8, name, "filter_users")) {
        const fields = event.fields orelse return true;
        state.user_query = try state.gpa.dupe(u8, fieldString(fields, "user_query") orelse "");
        state.user_role_filter = try state.gpa.dupe(
            u8,
            fieldString(fields, "user_role_filter") orelse "all",
        );
        state.user_status_filter = try state.gpa.dupe(
            u8,
            fieldString(fields, "user_status_filter") orelse "all",
        );
        try renderPage(arena, state, commands);
    } else if (std.mem.startsWith(u8, name, "manage_user:")) {
        state.selected_user = try state.gpa.dupe(u8, name["manage_user:".len..]);
        try renderPage(arena, state, commands);
        try commands.dialogOpen("user-dialog");
    } else if (std.mem.eql(u8, name, "close_user_dialog")) {
        try commands.dialogClose("user-dialog");
    } else return false;
    return true;
}

fn handleUserMutationAction(
    arena: std.mem.Allocator,
    state: *State,
    event: Event,
    commands: *Commands,
    name: []const u8,
) !bool {
    if (std.mem.eql(u8, name, "create_user")) {
        const fields = event.fields orelse return true;
        const user = fieldString(fields, "user_name") orelse "";
        const role = fieldString(fields, "user_role") orelse "user";
        const body = try std.json.Stringify.valueAlloc(
            arena,
            .{ .name = user, .role = role },
            .{},
        );
        try commands.fetchJson(
            fetch_create_user_id,
            "POST",
            "/api/v1/users",
            body,
            state.csrf,
        );
    } else if (std.mem.eql(u8, name, "save_user")) {
        if (state.selected_user.len == 0) return true;
        const fields = event.fields orelse return true;
        const role = fieldString(fields, "manage_role") orelse "user";
        const disabled_text = fieldString(fields, "manage_disabled") orelse "false";
        const body = try std.json.Stringify.valueAlloc(arena, .{
            .role = role,
            .disabled = std.mem.eql(u8, disabled_text, "true"),
        }, .{});
        const path = try userPath(arena, state.selected_user);
        try commands.fetchJson(fetch_patch_user_id, "PATCH", path, body, state.csrf);
    } else if (std.mem.eql(u8, name, "reset_user")) {
        if (state.selected_user.len == 0) return true;
        const path = try userPath(arena, state.selected_user);
        try commands.fetchJson(
            fetch_patch_user_id,
            "PATCH",
            path,
            "{\"reset_password\":true}",
            state.csrf,
        );
    } else return false;
    return true;
}

fn handleDeleteUserAction(
    arena: std.mem.Allocator,
    state: *State,
    event: Event,
    commands: *Commands,
    name: []const u8,
) !bool {
    if (!std.mem.eql(u8, name, "delete_user")) return false;
    if (state.selected_user.len == 0) return true;
    const fields = event.fields orelse return true;
    const confirmation = fieldString(fields, "delete_confirm") orelse "";
    if (!std.mem.eql(u8, confirmation, state.selected_user)) {
        state.failure_html = try render.transportFailure(
            state.gpa,
            "Type the exact account name before deleting it.",
        );
        try renderPage(arena, state, commands);
        try commands.dialogOpen("user-dialog");
        return true;
    }
    const path = try userPath(arena, state.selected_user);
    try commands.fetchJson(fetch_delete_user_id, "DELETE", path, "", state.csrf);
    return true;
}

fn handleKeyAction(
    arena: std.mem.Allocator,
    state: *State,
    event: Event,
    commands: *Commands,
    name: []const u8,
) !bool {
    if (std.mem.eql(u8, name, "close_secret")) {
        state.one_time_secret = "";
        state.one_time_subject = "";
        try commands.dialogClose("secret-dialog");
        try renderPage(arena, state, commands);
    } else if (std.mem.eql(u8, name, "copy_secret")) {
        if (state.one_time_secret.len > 0) try commands.clipboard(state.one_time_secret);
    } else if (std.mem.eql(u8, name, "create_key")) {
        const fields = event.fields orelse return true;
        const label = fieldString(fields, "key_label") orelse "api key";
        const body = try std.json.Stringify.valueAlloc(
            arena,
            .{ .label = label },
            .{},
        );
        try commands.fetchJson(
            fetch_create_key_id,
            "POST",
            "/api/v1/keys",
            body,
            state.csrf,
        );
    } else if (std.mem.startsWith(u8, name, "revoke_key:")) {
        const id = name["revoke_key:".len..];
        const path = try std.fmt.allocPrint(arena, "/api/v1/keys/{s}", .{id});
        try commands.fetchJson(fetch_revoke_key_id, "DELETE", path, "", state.csrf);
    } else return false;
    return true;
}

fn userPath(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "/api/v1/users/{s}", .{name});
}

fn applyTheme(
    arena: std.mem.Allocator,
    state: *State,
    theme: Theme,
    commands: *Commands,
) !void {
    state.stored_theme = theme;
    try commands.preferenceStore(theme);
    try commands.themeApply(state.effectiveScheme());
    try renderPage(arena, state, commands);
}

fn captureFields(state: *State, event: Event) !void {
    const fields = event.fields orelse return;
    if (fields != .object) return;
    if (fields.object.get("to")) |to| {
        if (to == .string) state.selected_to = try state.gpa.dupe(u8, to.string);
    }
    if (fields.object.get("strict")) |strict| {
        if (strict == .string) {
            state.selected_strict = try state.gpa.dupe(u8, strict.string);
        }
    }
}

fn handleFetchDone(
    arena: std.mem.Allocator,
    state: *State,
    event: Event,
    commands: *Commands,
) !void {
    const id = event.id orelse return;
    const status = event.status orelse 0;
    const body = event.body orelse "";
    switch (id) {
        fetch_session_id => try handleSessionProbe(arena, state, status, body, commands),
        fetch_login_id => try handleLoginDone(arena, state, status, body, commands),
        fetch_password_id => try handlePasswordDone(arena, state, status, body, commands),
        fetch_logout_id => try handleLogoutDone(arena, state, commands),
        fetch_formats_id => {
            state.writers = render.parseWriters(state.gpa, body) catch state.writers;
            state.formats_loaded = true;
            try renderPage(arena, state, commands);
        },
        fetch_convert_id => try handleConvertDone(arena, state, event, commands),
        fetch_users_id => try handleUsersDone(arena, state, body, commands),
        fetch_create_user_id => try handleCreateUserDone(
            arena,
            state,
            status,
            body,
            commands,
        ),
        fetch_patch_user_id => try handlePatchUserDone(
            arena,
            state,
            status,
            body,
            commands,
        ),
        fetch_delete_user_id => try handleDeleteUserDone(
            arena,
            state,
            status,
            body,
            commands,
        ),
        fetch_audit_id => {
            state.audit = render.parseAudit(state.gpa, body) catch &.{};
            try renderPage(arena, state, commands);
        },
        fetch_status_id => {
            state.notice = try render.statusSummary(state.gpa, body);
            try renderPage(arena, state, commands);
        },
        fetch_keys_id => try handleKeysDone(arena, state, body, commands),
        fetch_create_key_id => try handleCreateKeyDone(
            arena,
            state,
            status,
            body,
            commands,
        ),
        fetch_revoke_key_id => try handleRevokeKeyDone(
            arena,
            state,
            status,
            body,
            commands,
        ),
        else => {},
    }
}

fn handleSessionProbe(
    arena: std.mem.Allocator,
    state: *State,
    status: u16,
    body: []const u8,
    commands: *Commands,
) !void {
    state.busy = false;
    if (status == 404) {
        state.mode = .open;
        state.authenticated = true;
        state.role = .user;
        if (!isPublicPath(state.path)) {
            try rememberPath(state, "/");
            try commands.navigate("/");
        }
        try renderPage(arena, state, commands);
        try commands.fetch(fetch_formats_id, "GET", "/api/v1/formats", "none");
        return;
    }
    state.mode = .secure;
    if (status != 200 or !parseSession(state, body)) {
        state.authenticated = false;
        state.role = .anonymous;
        state.csrf = "";
        if (!std.mem.eql(u8, state.path, "/docs") and
            !std.mem.eql(u8, state.path, "/login"))
        {
            try rememberPath(state, "/login");
            try commands.navigate("/login");
        }
        try renderPage(arena, state, commands);
        return;
    }
    try routeAuthenticatedSession(state, commands);
    try renderPage(arena, state, commands);
    try fetchPageData(state, commands);
}

fn routeAuthenticatedSession(state: *State, commands: *Commands) !void {
    if (state.must_change_password) {
        try rememberPath(state, "/account");
        try commands.navigate("/account");
    } else if (!pathAllowed(state, state.path) or
        std.mem.eql(u8, state.path, "/login"))
    {
        try rememberPath(state, "/");
        try commands.navigate("/");
    }
}

fn handleLoginDone(
    arena: std.mem.Allocator,
    state: *State,
    status: u16,
    body: []const u8,
    commands: *Commands,
) !void {
    state.busy = false;
    if (status != 200 or !parseSession(state, body)) {
        state.failure_html = try render.envelopeFailure(
            state.gpa,
            body,
            "Login failed.",
        );
        try renderPage(arena, state, commands);
        return;
    }
    state.mode = .secure;
    const next = if (state.must_change_password) "/account" else "/";
    try rememberPath(state, next);
    try commands.navigate(next);
    try renderPage(arena, state, commands);
    try fetchPageData(state, commands);
}

fn handlePasswordDone(
    arena: std.mem.Allocator,
    state: *State,
    status: u16,
    body: []const u8,
    commands: *Commands,
) !void {
    if (status == 204) {
        state.must_change_password = false;
        state.notice = "Password changed. Other sessions were revoked.";
        try renderPage(arena, state, commands);
        try commands.fetch(fetch_session_id, "GET", "/api/v1/session", "none");
    } else {
        state.failure_html = try render.envelopeFailure(
            state.gpa,
            body,
            "Password change failed.",
        );
        try renderPage(arena, state, commands);
    }
}

fn handleLogoutDone(
    arena: std.mem.Allocator,
    state: *State,
    commands: *Commands,
) !void {
    state.authenticated = false;
    state.role = .anonymous;
    state.csrf = "";
    try rememberPath(state, "/login");
    try commands.navigate("/login");
    try renderPage(arena, state, commands);
}

fn handleConvertDone(
    arena: std.mem.Allocator,
    state: *State,
    event: Event,
    commands: *Commands,
) !void {
    state.busy = false;
    const body = event.body orelse "";
    const outcome = render.parseEnvelope(state.gpa, body) catch {
        if (isSuccessfulArtifact(event.status, event.content_type, body)) {
            state.result = .{
                .ok = true,
                .artifact = try state.gpa.dupe(u8, body),
                .artifact_name = try derivedArtifactName(state.gpa, state),
                .report_count = 0,
                .reports_html = "",
            };
            state.failure_html = null;
            try renderPage(arena, state, commands);
            return;
        }
        state.failure_html = try render.transportFailure(
            state.gpa,
            "The server returned a response the interface could not read. " ++
                "Open API docs for the request and response contract.",
        );
        try renderPage(arena, state, commands);
        return;
    };
    state.result = outcome.result;
    state.failure_html = outcome.failure_html;
    try renderPage(arena, state, commands);
}

fn isSuccessfulArtifact(
    status: ?u16,
    content_type: ?[]const u8,
    body: []const u8,
) bool {
    const code = status orelse return false;
    if (code < 200 or code >= 300 or body.len == 0) return false;
    const media = content_type orelse return true;
    return std.ascii.indexOfIgnoreCase(media, "application/json") == null;
}

fn derivedArtifactName(gpa: std.mem.Allocator, state: *const State) ![]const u8 {
    const source = state.fileName() orelse "converted";
    const base = std.fs.path.basename(source);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const stem = if (dot == 0) "converted" else base[0..dot];
    const extension = if (std.mem.eql(u8, state.selected_to, "markdown"))
        "md"
    else
        state.selected_to;
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ stem, extension });
}

fn handleUsersDone(
    arena: std.mem.Allocator,
    state: *State,
    body: []const u8,
    commands: *Commands,
) !void {
    state.users = render.parseUsers(state.gpa, body) catch &.{};
    try renderPage(arena, state, commands);
    if (state.one_time_secret.len > 0) {
        try commands.dialogOpen("secret-dialog");
    }
}

fn handleCreateUserDone(
    arena: std.mem.Allocator,
    state: *State,
    status: u16,
    body: []const u8,
    commands: *Commands,
) !void {
    if (status == 200) {
        try rememberOneTimeSecret(state, body);
        state.notice = "User created.";
        try commands.dialogClose("user-dialog");
        try commands.fetch(fetch_users_id, "GET", "/api/v1/users", "none");
        try renderPage(arena, state, commands);
        try commands.dialogOpen("secret-dialog");
    } else {
        state.failure_html = try render.envelopeFailure(
            state.gpa,
            body,
            "User creation failed.",
        );
        try renderPage(arena, state, commands);
    }
}

fn handlePatchUserDone(
    arena: std.mem.Allocator,
    state: *State,
    status: u16,
    body: []const u8,
    commands: *Commands,
) !void {
    if (status == 200) {
        try rememberOneTimeSecret(state, body);
        state.notice = "A new one-time password was created.";
        try commands.dialogClose("user-dialog");
        try commands.fetch(fetch_users_id, "GET", "/api/v1/users", "none");
        try renderPage(arena, state, commands);
        try commands.dialogOpen("secret-dialog");
    } else if (status == 204) {
        state.notice = "User updated.";
        try commands.dialogClose("user-dialog");
        try commands.fetch(fetch_users_id, "GET", "/api/v1/users", "none");
    } else {
        state.failure_html = try render.envelopeFailure(
            state.gpa,
            body,
            "User update failed.",
        );
        try renderPage(arena, state, commands);
    }
}

fn handleDeleteUserDone(
    arena: std.mem.Allocator,
    state: *State,
    status: u16,
    body: []const u8,
    commands: *Commands,
) !void {
    if (status == 204) {
        state.notice = "User deleted.";
        state.selected_user = "";
        try commands.dialogClose("user-dialog");
        try commands.fetch(fetch_users_id, "GET", "/api/v1/users", "none");
    } else {
        state.failure_html = try render.envelopeFailure(
            state.gpa,
            body,
            "User deletion failed.",
        );
        try renderPage(arena, state, commands);
    }
}

fn handleKeysDone(
    arena: std.mem.Allocator,
    state: *State,
    body: []const u8,
    commands: *Commands,
) !void {
    state.keys = render.parseKeys(state.gpa, body) catch &.{};
    try renderPage(arena, state, commands);
    if (state.one_time_secret.len > 0) {
        try commands.dialogOpen("secret-dialog");
    }
}

fn handleCreateKeyDone(
    arena: std.mem.Allocator,
    state: *State,
    status: u16,
    body: []const u8,
    commands: *Commands,
) !void {
    if (status == 200) {
        try rememberKeySecret(state, body);
        try commands.fetch(fetch_keys_id, "GET", "/api/v1/keys", "none");
        try renderPage(arena, state, commands);
        try commands.dialogOpen("secret-dialog");
    } else {
        state.failure_html = try render.envelopeFailure(
            state.gpa,
            body,
            "API key creation failed.",
        );
        try renderPage(arena, state, commands);
    }
}

fn handleRevokeKeyDone(
    arena: std.mem.Allocator,
    state: *State,
    status: u16,
    body: []const u8,
    commands: *Commands,
) !void {
    if (status == 204) {
        state.notice = "API key revoked.";
        try commands.fetch(fetch_keys_id, "GET", "/api/v1/keys", "none");
    } else {
        state.failure_html = try render.envelopeFailure(
            state.gpa,
            body,
            "API key revocation failed.",
        );
        try renderPage(arena, state, commands);
    }
}

fn fieldString(fields: std.json.Value, name: []const u8) ?[]const u8 {
    if (fields != .object) return null;
    const value = fields.object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn pathAllowed(state: *const State, path: []const u8) bool {
    if (std.mem.eql(u8, path, "/docs")) return true;
    if (std.mem.eql(u8, path, "/login")) return state.mode != .open;
    if (std.mem.eql(u8, path, "/")) return state.authenticated;
    if (std.mem.eql(u8, path, "/account")) return state.authenticated and state.mode == .secure;
    if (std.mem.startsWith(u8, path, "/admin/")) return state.isAdministrator();
    return false;
}

fn fetchPageData(state: *State, commands: *Commands) !void {
    if (!state.authenticated) return;
    if (std.mem.eql(u8, state.path, "/")) {
        try commands.fetch(fetch_formats_id, "GET", "/api/v1/formats", "none");
    } else if (std.mem.eql(u8, state.path, "/account")) {
        try commands.fetch(fetch_keys_id, "GET", "/api/v1/keys", "none");
    } else if (std.mem.eql(u8, state.path, "/admin/users")) {
        try commands.fetch(fetch_users_id, "GET", "/api/v1/users", "none");
    } else if (std.mem.eql(u8, state.path, "/admin/audit")) {
        try commands.fetch(fetch_audit_id, "GET", "/api/v1/audit", "none");
    } else if (std.mem.eql(u8, state.path, "/admin/status")) {
        try commands.fetch(fetch_status_id, "GET", "/api/v1/status", "none");
    }
}

fn parseSession(state: *State, body: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        state.gpa,
        body,
        .{},
    ) catch return false;
    if (parsed != .object) return false;
    const name = fieldString(parsed, "name") orelse return false;
    const role_text = fieldString(parsed, "role") orelse return false;
    const csrf = fieldString(parsed, "csrf") orelse return false;
    const must_change = parsed.object.get("must_change_password") orelse return false;
    if (must_change != .bool) return false;
    state.session_name = state.gpa.dupe(u8, name) catch return false;
    state.csrf = state.gpa.dupe(u8, csrf) catch return false;
    state.role = if (std.mem.eql(u8, role_text, "administrator"))
        .administrator
    else if (std.mem.eql(u8, role_text, "user"))
        .user
    else
        return false;
    state.must_change_password = must_change.bool;
    state.authenticated = true;
    return true;
}

fn rememberOneTimeSecret(state: *State, body: []const u8) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, state.gpa, body, .{});
    if (parsed != .object) return error.Malformed;
    const password = fieldString(parsed, "password") orelse return error.Malformed;
    const name = fieldString(parsed, "name") orelse return error.Malformed;
    state.one_time_secret = try state.gpa.dupe(u8, password);
    state.one_time_subject = try state.gpa.dupe(u8, name);
}

fn rememberKeySecret(state: *State, body: []const u8) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, state.gpa, body, .{});
    if (parsed != .object) return error.Malformed;
    const secret = fieldString(parsed, "secret") orelse return error.Malformed;
    const id = fieldString(parsed, "id") orelse return error.Malformed;
    state.one_time_secret = try state.gpa.dupe(u8, secret);
    state.one_time_subject = try state.gpa.dupe(u8, id);
}

fn renderPage(
    arena: std.mem.Allocator,
    state: *State,
    commands: *Commands,
) !void {
    const html = try render.page(arena, state);
    try commands.patch("app", html);
}

fn rememberPath(state: *State, path: []const u8) !void {
    state.path = try state.gpa.dupe(u8, path);
}

fn isPublicPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/docs");
}

fn parseTheme(text: []const u8) Theme {
    if (std.mem.eql(u8, text, "light")) return .light;
    if (std.mem.eql(u8, text, "dark")) return .dark;
    return .system;
}

fn parseScheme(text: []const u8) Scheme {
    return if (std.mem.eql(u8, text, "dark")) .dark else .light;
}

// ------------------------------------------------------------- wasm ABI

const wasm_gpa: std.mem.Allocator = if (builtin.target.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

var global_state: State = undefined;
var global_state_ready = false;
var response_buffer: []const u8 = &.{};
var event_buffer: []u8 = &.{};
var event_arena: ?std.heap.ArenaAllocator = null;

export fn ui_abi_version() u32 {
    return abi_version;
}

/// Allocates the buffer the glue writes the next event into.
export fn ui_alloc(len: u32) [*]u8 {
    if (event_buffer.len != 0) wasm_gpa.free(event_buffer);
    event_buffer = wasm_gpa.alloc(u8, len) catch @panic("ui_alloc");
    return event_buffer.ptr;
}

/// Feeds one event; returns the command list as (pointer << 32) | length.
/// The returned buffer is owned by the module until the next call.
export fn ui_event(ptr: [*]const u8, len: u32) u64 {
    if (!global_state_ready) {
        global_state = .{ .gpa = wasm_gpa };
        global_state_ready = true;
    }
    if (event_arena) |*arena| arena.deinit();
    event_arena = std.heap.ArenaAllocator.init(wasm_gpa);
    const arena = event_arena.?.allocator();
    const commands = handleEvent(arena, &global_state, ptr[0..len]) catch "[]";
    response_buffer = commands;
    return (@as(u64, @intFromPtr(commands.ptr)) << 32) | commands.len;
}

test {
    _ = render;
    _ = @import("main_test.zig");
}
