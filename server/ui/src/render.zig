//! HTML rendering for the interface module (ZDS 0016, The Web Interface).
//!
//! In the manner of autodoc's `html_render.zig`: every interpolation is
//! escaped by construction, daisyUI class names are comptime constants
//! gathered here, and the Elm-style report renderer shows every report
//! verbatim — the interface never paraphrases one.

const std = @import("std");

const main = @import("main.zig");

/// Escapes text into HTML content or attribute position.
pub fn esc(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(byte),
    };
}

/// The complete page for the current state, allocated from `arena`.
pub fn page(arena: std.mem.Allocator, state: *const main.State) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try navbar(w, state);
    if (state.notice.len > 0) {
        try w.writeAll(
            "<div class=\"alert alert-success zf-mt\" role=\"status\" " ++
                "aria-live=\"polite\">",
        );
        try esc(w, state.notice);
        try w.writeAll("</div>");
    }
    if (state.mode == .unknown) {
        try w.writeAll(
            "<div class=\"zf-mt\" role=\"status\"><span class=\"loading " ++
                "loading-spinner\"></span> Loading zenfmt</div>",
        );
    } else if (std.mem.eql(u8, state.path, "/docs")) {
        try docsPage(w, state);
    } else if (!state.authenticated) {
        try loginPage(w, state);
    } else if (std.mem.eql(u8, state.path, "/account")) {
        try accountPage(w, state);
    } else if (std.mem.eql(u8, state.path, "/admin/users") and state.isAdministrator()) {
        try usersPage(w, state);
    } else if (std.mem.eql(u8, state.path, "/admin/audit") and state.isAdministrator()) {
        try auditPage(w, state);
    } else if (std.mem.eql(u8, state.path, "/admin/status") and state.isAdministrator()) {
        try statusPage(w, state);
    } else {
        try converter(w, state);
    }
    if (state.one_time_secret.len > 0) try secretDialog(w, state);
    return out.written();
}

fn navbar(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        \\<header class="zf-header">
        \\<button class="zf-brand" data-action="nav:/" aria-label="zenfmt converter">
        \\<span class="zf-brand-mark">zenfmt</span><span class="zf-brand-product">Server</span>
        \\</button><nav class="zf-nav" aria-label="Primary navigation">
    );
    if (state.authenticated) {
        try navButton(w, state, "/", "Convert");
        if (state.mode == .secure) try navButton(w, state, "/account", "Account");
        if (state.isAdministrator()) {
            try navButton(w, state, "/admin/users", "Users");
            try navButton(w, state, "/admin/audit", "Audit");
            try navButton(w, state, "/admin/status", "Status");
        }
    } else if (state.mode == .secure) {
        try navButton(w, state, "/login", "Sign in");
    }
    try navButton(w, state, "/docs", "API docs");
    try w.writeAll("</nav><div class=\"zf-header-tools\">");
    try modeBadge(w, state);
    try themeSelector(w, state);
    if (state.authenticated and state.mode == .secure) {
        try w.writeAll("<span class=\"zf-session\">");
        try esc(w, state.session_name);
        try w.writeAll(
            "</span><button class=\"zf-button zf-button-quiet\" data-action=\"logout\">" ++
                "Log out</button>",
        );
    }
    try w.writeAll("</div></header>");
}

fn navButton(
    w: *std.Io.Writer,
    state: *const main.State,
    path: []const u8,
    label: []const u8,
) !void {
    try w.print("<button class=\"zf-nav-link{s}\" data-action=\"nav:", .{
        if (std.mem.eql(u8, state.path, path)) " zf-nav-current" else "",
    });
    try esc(w, path);
    try w.writeAll("\"");
    if (std.mem.eql(u8, state.path, path)) try w.writeAll(" aria-current=\"page\"");
    try w.writeAll(">");
    try esc(w, label);
    try w.writeAll("</button>");
}

fn modeBadge(w: *std.Io.Writer, state: *const main.State) !void {
    if (state.mode == .unknown) return;
    const label = if (state.mode == .secure) "Secure mode" else "Open mode";
    const class = if (state.mode == .secure) "zf-mode-secure" else "zf-mode-open";
    try w.print("<span class=\"zf-mode {s}\">{s}</span>", .{ class, label });
}

fn themeSelector(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll("<div class=\"zf-theme\" role=\"group\" aria-label=\"Theme\">");
    const options = [_]struct { action: []const u8, label: []const u8, theme: main.Theme }{
        .{ .action = "theme_system", .label = "System", .theme = .system },
        .{ .action = "theme_light", .label = "Light", .theme = .light },
        .{ .action = "theme_dark", .label = "Dark", .theme = .dark },
    };
    for (options) |option| {
        try w.print(
            "<button class=\"zf-theme-choice{s}\" data-action=\"{s}\">{s}</button>",
            .{
                if (state.stored_theme == option.theme) " zf-theme-active" else "",
                option.action,
                option.label,
            },
        );
    }
    try w.writeAll("</div>");
}

fn converter(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        \\<main class="zf-page">
        \\<section class="zf-page-heading"><div>
        \\<p class="zf-eyebrow">Document conversion</p>
        \\<h1>Turn a document into useful text</h1>
        \\<p class="zf-lede">The server uses the same native conversion
        \\pipeline as the zenfmt CLI.</p>
        \\</div></section>
    );
    try w.print("<div class=\"zf-converter\" data-formats-ready=\"{s}\">", .{
        if (state.formats_loaded) "true" else "false",
    });
    try dropZone(w, state);
    try converterOptions(w, state);
    try w.writeAll("</div>");

    if (state.failure_html) |failure| {
        try w.writeAll("<div class=\"zf-mt\" role=\"alert\" aria-live=\"polite\">");
        try w.writeAll(failure);
        try w.writeAll("</div>");
    }
    if (state.result) |result| try resultCard(w, result);
    try w.writeAll("</main>");
}

fn dropZone(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        \\<section class="zf-upload-card" aria-labelledby="upload-title">
        \\<div class="zf-card-heading"><div><p class="zf-step">01</p>
        \\<h2 id="upload-title">Choose a document</h2></div>
        \\<span class="zf-card-note">Processed on this server</span></div>
        \\<label class="zf-drop" data-drop for="file-input">
        \\<span class="zf-file-glyph" aria-hidden="true">DOC</span>
        \\<span class="zf-drop-copy">
    );
    if (state.fileName()) |name| {
        try w.writeAll("<strong class=\"zf-file-name\">");
        try esc(w, name);
        try w.print(
            "</strong><span class=\"zf-file-size\">{d} bytes selected</span>",
            .{state.file_size},
        );
    } else {
        try w.writeAll(
            \\<strong>Drop a document here</strong>
            \\<span>or browse from this computer</span>
        );
    }
    try w.writeAll(
        \\<input id="file-input" type="file" class="zf-hidden" />
        \\</span></label>
        \\<p class="zf-support-note">DOCX, PDF, presentations, spreadsheets,
        \\OpenDocument, EPUB, HTML, RTF, CSV, and text.</p>
        \\</section>
    );
}

fn converterOptions(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        \\<aside class="zf-options" aria-labelledby="options-title">
        \\<div class="zf-card-heading"><div><p class="zf-step">02</p>
        \\<h2 id="options-title">Conversion</h2></div></div>
        \\<label class="zf-field"><span>Output format</span>
        \\<select name="to">
    );
    if (state.writers.len == 0) {
        try w.writeAll("<option value=\"markdown\">markdown</option>");
    } else {
        for (state.writers) |writer_format| {
            try w.print("<option value=\"{s}\"{s}>{s}</option>", .{
                writer_format,
                if (std.mem.eql(u8, writer_format, state.selected_to)) " selected" else "",
                writer_format,
            });
        }
    }
    try w.writeAll(
        \\</select></label>
        \\<label class="zf-field"><span>Strictness</span>
        \\<select name="strict">
    );
    const grades = [_][]const u8{ "off", "content", "structure", "exact" };
    for (grades) |grade| {
        try w.print("<option value=\"{s}\"{s}>{s}</option>", .{
            grade,
            if (std.mem.eql(u8, grade, state.selected_strict)) " selected" else "",
            grade,
        });
    }
    try w.writeAll("</select></label>");
    if (state.busy) {
        try w.writeAll(
            \\<button class="zf-button zf-button-primary zf-convert-button" disabled>
            \\<span class="loading loading-spinner"></span>Converting</button>
        );
    } else {
        try w.writeAll(
            \\<button class="zf-button zf-button-primary zf-convert-button"
            \\ data-action="convert">Convert document</button>
        );
    }
    try w.writeAll(
        \\<p class="zf-options-note">Strictness is off by default. Higher
        \\grades fail when a conversion loses the selected kind of fidelity.</p>
        \\</aside>
    );
}

fn loginPage(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        \\<main class="zf-page zf-auth-page"><section class="zf-auth-card">
        \\<p class="zf-eyebrow">Secure server</p><h1>Sign in to zenfmt</h1>
        \\<p class="zf-lede">Use your server account to convert documents and manage API access.</p>
        \\<label class="zf-field"><span>Name</span>
        \\<input id="login-name" name="name" autocomplete="username"
        \\ /></label>
        \\<label class="zf-field"><span>Password</span>
        \\<input name="password" type="password" autocomplete="current-password"
        \\ /></label>
    );
    if (state.busy) {
        try w.writeAll(
            "<button class=\"zf-button zf-button-primary\" disabled><span class=\"loading " ++
                "loading-spinner\"></span>Signing in</button>",
        );
    } else {
        try w.writeAll(
            "<button class=\"zf-button zf-button-primary\" " ++
                "data-action=\"login\">Sign in</button>",
        );
    }
    if (state.failure_html) |failure| try w.writeAll(failure);
    try w.writeAll(
        \\<p class="zf-auth-help">Need to automate a conversion? The API docs
        \\describe bearer keys and request formats.</p>
        \\</section></main>
    );
}

fn docsPage(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        \\<main class="zf-page">
        \\<section class="zf-page-heading zf-docs-heading"><div>
        \\<p class="zf-eyebrow">OpenAPI 3.1</p>
        \\<h1>API reference</h1>
        \\<p class="zf-lede">Convert documents, inspect capabilities, and
        \\operate this zenfmt server through its public HTTP API.</p>
        \\</div><a class="zf-button zf-button-secondary" href="/openapi.json"
        \\ download>Download OpenAPI JSON</a></section>
        \\<section class="zf-docs-grid" aria-label="API overview">
        \\<article class="zf-doc-card"><p class="zf-endpoint">
        \\<span>POST</span> /api/v1/convert</p>
        \\<h2>Convert one document</h2><p>Send raw document bytes or a multipart
        \\file. Ask for Markdown bytes or a structured JSON envelope.</p></article>
        \\<article class="zf-doc-card"><p class="zf-endpoint">
        \\<span>POST</span> /api/v1/convert/batch</p>
        \\<h2>Convert a batch</h2><p>Send multipart documents and receive one
        \\JSON envelope per line as work completes.</p></article>
        \\<article class="zf-doc-card"><p class="zf-endpoint zf-endpoint-get">
        \\<span>GET</span> /api/v1/formats</p>
        \\<h2>Discover capabilities</h2><p>Read the formats and limits compiled
        \\into this server before submitting work.</p></article>
        \\<article class="zf-doc-card"><p class="zf-endpoint zf-endpoint-get">
        \\<span>GET</span> /api/v1/status</p>
        \\<h2>Inspect status</h2><p>Read the server version, mode, uptime, and
        \\active conversion capacity.</p></article>
        \\</section>
        \\<section class="zf-code-card"><div><p class="zf-step">Quick start</p>
        \\<h2>Convert to Markdown</h2></div>
        \\<pre><code>curl -s -T report.docx &#92;
        \\  "http://127.0.0.1:8998/api/v1/convert?to=markdown" &#92;
        \\  -H "Accept: text/markdown"</code></pre></section>
    );
    try docsAccess(w, state);
    try w.writeAll("</main>");
}

fn docsAccess(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        \\<section class="zf-doc-note"><div><p class="zf-step">Access</p>
        \\<h2>Authentication follows the server mode</h2>
    );
    if (state.mode == .open) {
        try w.writeAll(
            \\<p>This server is in open mode. Conversion requests do not need
            \\credentials. Account and administration routes are not enabled.</p>
        );
    } else {
        try w.writeAll(
            \\<p>This server is in secure mode. Browser requests use a session
            \\and CSRF token. Programs send an API key as
            \\<code>Authorization: Bearer zfk_&lt;id&gt;.&lt;secret&gt;</code>.</p>
        );
    }
    try w.writeAll(
        \\</div><a class="zf-text-link" href="/openapi.json">View the complete
        \\machine readable contract</a></section>
    );
}

fn accountPage(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll("<main class=\"zf-mt\"><h1 class=\"text-2xl font-bold\">Account</h1>");
    if (state.must_change_password) {
        try w.writeAll(
            "<div class=\"alert alert-warning zf-mt\" role=\"alert\">" ++
                "Change the one-time password before continuing.</div>",
        );
    }
    if (state.failure_html) |failure| try w.writeAll(failure);
    try w.writeAll(
        \\<section class="card bg-base-100 shadow-sm zf-mt"><div class="card-body">
        \\<h2 class="card-title">Change password</h2>
        \\<label class="form-control"><span class="label-text">New password</span>
        \\<input name="new_password" type="password" minlength="8"
        \\ autocomplete="new-password" class="input input-bordered" /></label>
        \\<button class="btn btn-primary" data-action="change_password">Change password</button>
        \\</div></section>
    );
    if (!state.must_change_password) {
        try w.writeAll(
            \\<section class="card bg-base-100 shadow-sm zf-mt"><div class="card-body">
            \\<h2 class="card-title">API keys</h2><div class="zf-row">
            \\<label class="form-control zf-grow"><span class="label-text">Label</span>
            \\<input name="key_label" class="input input-bordered" value="api key" /></label>
            \\<button class="btn btn-primary zf-self-end" data-action="create_key">
            \\Create key</button></div>
        );
        if (state.keys.len == 0) try w.writeAll("<p>No API keys.</p>");
        for (state.keys) |key| {
            try w.writeAll("<div class=\"zf-row zf-list-row\"><div class=\"zf-grow\"><strong>");
            try esc(w, key.label);
            try w.writeAll("</strong><br /><code>");
            try esc(w, key.id);
            try w.writeAll(
                "</code></div><button class=\"btn btn-error btn-sm\" " ++
                    "data-action=\"revoke_key:",
            );
            try esc(w, key.id);
            try w.writeAll("\">Revoke</button></div>");
        }
        try w.writeAll("</div></section>");
    }
    try w.writeAll("</main>");
}

fn usersPage(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        \\<main class="zf-mt"><div class="zf-row"><div class="zf-grow">
        \\<h1 class="text-2xl font-bold">Users</h1><p>Manage access to this zenfmt server.</p></div>
        \\<button class="btn btn-primary" data-action="create_user_dialog">
        \\Create user</button></div>
        \\<div class="card bg-base-100 shadow-sm zf-mt"><div class="card-body">
        \\<div class="zf-row"><input name="user_query"
        \\ class="input input-bordered input-sm zf-grow"
        \\ placeholder="Search users" value="
    );
    try esc(w, state.user_query);
    try w.writeAll(
        "\" /><select name=\"user_role_filter\" " ++
            "class=\"select select-bordered select-sm\">",
    );
    try filterOption(w, "all", "All roles", state.user_role_filter);
    try filterOption(w, "administrator", "Administrators", state.user_role_filter);
    try filterOption(w, "user", "Users", state.user_role_filter);
    try w.writeAll(
        "</select><select name=\"user_status_filter\" " ++
            "class=\"select select-bordered select-sm\">",
    );
    try filterOption(w, "all", "All status", state.user_status_filter);
    try filterOption(w, "active", "Active", state.user_status_filter);
    try filterOption(w, "disabled", "Disabled", state.user_status_filter);
    try w.writeAll(
        "</select><button class=\"btn btn-sm\" data-action=\"filter_users\">" ++
            "Apply</button></div>",
    );
    if (state.failure_html) |failure| try w.writeAll(failure);
    try w.writeAll(
        "<div class=\"overflow-x-auto\"><table class=\"table\"><thead><tr>" ++
            "<th>Name</th><th>Role</th><th>Status</th><th>Credential</th>" ++
            "<th></th></tr></thead><tbody>",
    );
    var shown: usize = 0;
    for (state.users) |user| {
        if (!userMatches(state, user)) continue;
        shown += 1;
        try w.writeAll("<tr><td>");
        try esc(w, user.name);
        try w.writeAll("</td><td><span class=\"badge badge-ghost\">");
        try esc(w, user.role);
        try w.writeAll("</span></td><td>");
        try w.writeAll(if (user.disabled) "Disabled" else "Active");
        try w.writeAll("</td><td>");
        try w.writeAll(if (user.must_change_password) "One-time password" else "Set");
        try w.writeAll("</td><td><button class=\"btn btn-sm\" data-action=\"manage_user:");
        try esc(w, user.name);
        try w.writeAll("\">Manage</button></td></tr>");
    }
    if (shown == 0) try w.writeAll("<tr><td colspan=\"5\">No users match these filters.</td></tr>");
    try w.writeAll("</tbody></table></div></div></div>");
    try userDialog(w, state);
    try w.writeAll("</main>");
}

fn filterOption(
    w: *std.Io.Writer,
    value: []const u8,
    label: []const u8,
    selected: []const u8,
) !void {
    try w.print("<option value=\"{s}\"{s}>{s}</option>", .{
        value,
        if (std.mem.eql(u8, value, selected)) " selected" else "",
        label,
    });
}

fn userMatches(state: *const main.State, user: main.UserSummary) bool {
    if (state.user_query.len > 0 and
        std.ascii.indexOfIgnoreCase(user.name, state.user_query) == null)
    {
        return false;
    }
    if (!std.mem.eql(u8, state.user_role_filter, "all") and
        !std.mem.eql(u8, state.user_role_filter, user.role)) return false;
    if (std.mem.eql(u8, state.user_status_filter, "active") and user.disabled) return false;
    if (std.mem.eql(u8, state.user_status_filter, "disabled") and !user.disabled) return false;
    return true;
}

fn selectedUser(state: *const main.State) ?main.UserSummary {
    for (state.users) |user| {
        if (std.mem.eql(u8, user.name, state.selected_user)) return user;
    }
    return null;
}

fn isLastActiveAdministrator(state: *const main.State, selected: main.UserSummary) bool {
    if (selected.disabled or !std.mem.eql(u8, selected.role, "administrator")) return false;
    var count: usize = 0;
    for (state.users) |user| {
        if (!user.disabled and std.mem.eql(u8, user.role, "administrator")) count += 1;
    }
    return count == 1;
}

fn userDialog(w: *std.Io.Writer, state: *const main.State) !void {
    const selected = selectedUser(state);
    try w.writeAll("<dialog id=\"user-dialog\" class=\"modal\"><div class=\"modal-box\">");
    if (state.failure_html) |failure| try w.writeAll(failure);
    if (selected) |user| {
        const last_administrator = isLastActiveAdministrator(state, user);
        try w.writeAll("<h2 class=\"text-xl font-bold\">Manage ");
        try esc(w, user.name);
        try w.writeAll("</h2>");
        if (last_administrator) try w.writeAll(
            "<div class=\"alert alert-warning zf-mt\">This is the last active " ++
                "administrator. Its role, status, and account cannot be " ++
                "removed.</div>",
        );
        try w.writeAll(
            "<label class=\"form-control\"><span class=\"label-text\">Role" ++
                "</span><select name=\"manage_role\" " ++
                "class=\"select select-bordered\"",
        );
        if (last_administrator) try w.writeAll(" disabled");
        try w.writeAll(">");
        try filterOption(w, "user", "User", user.role);
        try filterOption(w, "administrator", "Administrator", user.role);
        try w.writeAll(
            "</select></label><label class=\"form-control\"><span " ++
                "class=\"label-text\">Status</span><select " ++
                "name=\"manage_disabled\" class=\"select select-bordered\"",
        );
        if (last_administrator) try w.writeAll(" disabled");
        try w.writeAll(">");
        try filterOption(w, "false", "Active", if (user.disabled) "true" else "false");
        try filterOption(w, "true", "Disabled", if (user.disabled) "true" else "false");
        try w.writeAll(
            "</select></label><label class=\"form-control\"><span " ++
                "class=\"label-text\">Type the account name to confirm " ++
                "deletion</span><input name=\"delete_confirm\" " ++
                "class=\"input input-bordered\"",
        );
        if (last_administrator) try w.writeAll(" disabled");
        try w.writeAll(
            " /></label><div class=\"modal-action zf-wrap\"><button " ++
                "class=\"btn btn-primary\" data-action=\"save_user\">Save" ++
                "</button><button class=\"btn\" data-action=\"reset_user\">" ++
                "Reset password</button><button class=\"btn btn-error\" " ++
                "data-action=\"delete_user\"",
        );
        if (last_administrator) try w.writeAll(" disabled");
        try w.writeAll(">Delete</button>");
    } else {
        try w.writeAll(
            \\<h2 class="text-xl font-bold">Create user</h2>
            \\<label class="form-control"><span class="label-text">Name</span>
            \\<input id="user-name" name="user_name" maxlength="64"
            \\ class="input input-bordered" /></label>
            \\<label class="form-control"><span class="label-text">Role</span>
            \\<select name="user_role" class="select select-bordered">
            \\<option value="user">User</option>
            \\<option value="administrator">Administrator</option></select></label>
            \\<div class="modal-action"><button class="btn btn-primary"
            \\ data-action="create_user">Create</button>
        );
    }
    try w.writeAll(
        "<button class=\"btn\" data-action=\"close_user_dialog\">Cancel" ++
            "</button></div></div></dialog>",
    );
}

fn auditPage(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        "<main class=\"zf-mt\"><h1 class=\"text-2xl font-bold\">Audit</h1>" ++
            "<div class=\"card bg-base-100 shadow-sm zf-mt\"><div " ++
            "class=\"card-body overflow-x-auto\"><table class=\"table\">" ++
            "<thead><tr><th>Time</th><th>Actor</th><th>Action</th>" ++
            "<th>Subject</th></tr></thead><tbody>",
    );
    for (state.audit) |record| {
        try w.print("<tr><td>{d}</td><td>", .{record.at});
        try esc(w, record.actor);
        try w.writeAll("</td><td>");
        try esc(w, record.action);
        try w.writeAll("</td><td>");
        try esc(w, record.subject);
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></div></div></main>");
}

fn statusPage(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        "<main class=\"zf-mt\"><h1 class=\"text-2xl font-bold\">Server " ++
            "status</h1><div class=\"card bg-base-100 shadow-sm zf-mt\">" ++
            "<div class=\"card-body\"><p>",
    );
    if (state.notice.len > 0) try esc(w, state.notice) else try w.writeAll("Loading status.");
    try w.writeAll("</p></div></div></main>");
}

fn secretDialog(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        "<dialog id=\"secret-dialog\" class=\"modal\"><div " ++
            "class=\"modal-box\"><h2 class=\"text-xl font-bold\">Save this " ++
            "secret now</h2><p>The secret for <strong>",
    );
    try esc(w, state.one_time_subject);
    try w.writeAll(
        "</strong> is shown once.</p><input class=\"input input-bordered " ++
            "w-full\" readonly value=\"",
    );
    try esc(w, state.one_time_secret);
    try w.writeAll(
        "\" /><div class=\"modal-action\"><button class=\"btn\" " ++
            "data-action=\"copy_secret\">Copy</button><button " ++
            "class=\"btn btn-primary\" data-action=\"close_secret\">Done" ++
            "</button></div></div></dialog>",
    );
}

fn resultCard(w: *std.Io.Writer, result: main.Result) !void {
    try w.writeAll(
        \\<div class="card bg-base-100 shadow-sm zf-mt"><div class="card-body">
        \\<div class="zf-row"><span class="card-title">
    );
    try esc(w, result.artifact_name);
    try w.writeAll("</span><span class=\"zf-right\">");
    try w.writeAll(
        \\<button class="btn btn-sm" data-action="download">Download</button>
    );
    try w.writeAll("</span></div>");
    try w.writeAll(result.reports_html);
    if (result.ok) {
        try w.writeAll("<div class=\"zf-preview\">");
        const preview = result.artifact[0..@min(
            result.artifact.len,
            main.max_artifact_preview,
        )];
        try esc(w, preview);
        if (result.artifact.len > preview.len) try w.writeAll("\n…");
        try w.writeAll("</div>");
    }
    try w.writeAll("</div></div>");
}

/// A transport or interface-level failure, rendered in the report style.
pub fn transportFailure(gpa: std.mem.Allocator, message: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    try w.writeAll("<div class=\"alert alert-error\"><div><h3 class=\"font-bold\">");
    try w.writeAll("THE CONVERSION DID NOT RUN</h3><p>");
    try esc(w, message);
    try w.writeAll("</p></div></div>");
    return out.written();
}

/// The parsed outcome of a conversion response: either a result card's
/// data or pre-rendered failure panels.
pub const Outcome = struct {
    result: ?main.Result = null,
    failure_html: ?[]const u8 = null,
};

const EnvelopeDirection = struct {
    explanation: []const u8 = "",
};

const EnvelopeReport = struct {
    severity: []const u8 = "error",
    code: []const u8 = "",
    title: []const u8 = "",
    problem: []const u8 = "",
    consequence: []const u8 = "",
    directions: []const EnvelopeDirection = &.{},
};

const EnvelopeDocument = struct {
    status: []const u8,
    artifact: ?[]const u8 = null,
    artifact_name: ?[]const u8 = null,
    reports: []const EnvelopeReport = &.{},
};

/// Parses the envelope JSON and pre-renders the report panels. Allocations
/// come from `gpa` because the outcome outlives the event.
pub fn parseEnvelope(gpa: std.mem.Allocator, body: []const u8) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try std.json.parseFromSliceLeaky(
        EnvelopeDocument,
        arena,
        body,
        .{ .ignore_unknown_fields = true },
    );
    const is_success = std.mem.eql(u8, document.status, "success");
    if (is_success and
        (document.artifact == null or document.artifact_name == null))
    {
        return error.Malformed;
    }

    var reports_out: std.Io.Writer.Allocating = .init(gpa);
    for (document.reports) |report| try reportPanel(&reports_out.writer, report);
    const reports_html = try reports_out.toOwnedSlice();
    errdefer if (reports_html.len > 0) gpa.free(reports_html);

    if (is_success) {
        const artifact = try gpa.dupe(u8, document.artifact.?);
        errdefer if (artifact.len > 0) gpa.free(artifact);
        const name = try gpa.dupe(u8, document.artifact_name.?);
        return .{ .result = .{
            .ok = true,
            .artifact = artifact,
            .artifact_name = name,
            .report_count = document.reports.len,
            .reports_html = reports_html,
        } };
    }
    return .{ .failure_html = reports_html };
}

/// One Elm-style report panel: what happened, the consequence, and what
/// you can do — verbatim, escaped.
fn reportPanel(w: *std.Io.Writer, report: EnvelopeReport) !void {
    const alert_class = if (std.mem.eql(u8, report.severity, "warning"))
        "alert-warning"
    else if (std.mem.eql(u8, report.severity, "note"))
        "alert-info"
    else
        "alert-error";
    try w.print("<div class=\"alert {s} zf-mt\" role=\"status\"><div>", .{alert_class});
    if (report.title.len > 0) {
        try w.writeAll("<h3 class=\"font-bold\">");
        try esc(w, report.title);
        try w.writeAll("</h3>");
    }
    if (report.code.len > 0) {
        try w.writeAll("<span class=\"badge badge-ghost\">");
        try esc(w, report.code);
        try w.writeAll("</span>");
    }
    try reportParagraph(w, report.problem);
    try reportParagraph(w, report.consequence);
    try reportDirections(w, report.directions);
    try w.writeAll("</div></div>");
}

fn reportParagraph(w: *std.Io.Writer, text: []const u8) !void {
    if (text.len == 0) return;
    try w.writeAll("<p>");
    try esc(w, text);
    try w.writeAll("</p>");
}

fn reportDirections(w: *std.Io.Writer, directions: []const EnvelopeDirection) !void {
    if (directions.len == 0) return;
    try w.writeAll("<p class=\"font-bold\">What you can do</p><ul>");
    for (directions) |direction| {
        if (direction.explanation.len == 0) continue;
        try w.writeAll("<li>");
        try esc(w, direction.explanation);
        try w.writeAll("</li>");
    }
    try w.writeAll("</ul>");
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

/// The writer formats from the capability document.
pub fn parseWriters(gpa: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    if (value != .object) return error.Malformed;
    const formats = value.object.get("formats") orelse return error.Malformed;
    if (formats != .array) return error.Malformed;
    var writers: std.ArrayList([]const u8) = .empty;
    for (formats.array.items) |item| {
        if (item != .object) continue;
        const writes = item.object.get("write") orelse continue;
        if (writes != .bool or !writes.bool) continue;
        const format = stringOf(item.object.get("format")) orelse continue;
        try writers.append(gpa, try gpa.dupe(u8, format));
    }
    return writers.toOwnedSlice(gpa);
}

pub fn parseUsers(gpa: std.mem.Allocator, body: []const u8) ![]const main.UserSummary {
    const Document = struct { users: []main.UserSummary };
    const document = try std.json.parseFromSliceLeaky(Document, gpa, body, .{
        .ignore_unknown_fields = true,
    });
    return document.users;
}

pub fn parseAudit(gpa: std.mem.Allocator, body: []const u8) ![]const main.AuditRecord {
    const Document = struct { audit: []main.AuditRecord };
    const document = try std.json.parseFromSliceLeaky(Document, gpa, body, .{
        .ignore_unknown_fields = true,
    });
    return document.audit;
}

pub fn parseKeys(gpa: std.mem.Allocator, body: []const u8) ![]const main.KeySummary {
    const Document = struct { keys: []main.KeySummary };
    const document = try std.json.parseFromSliceLeaky(Document, gpa, body, .{
        .ignore_unknown_fields = true,
    });
    return document.keys;
}

pub fn envelopeFailure(
    gpa: std.mem.Allocator,
    body: []const u8,
    fallback: []const u8,
) ![]const u8 {
    const outcome = parseEnvelope(gpa, body) catch return transportFailure(gpa, fallback);
    return outcome.failure_html orelse transportFailure(gpa, fallback);
}

pub fn statusSummary(gpa: std.mem.Allocator, body: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena_state.allocator(),
        body,
        .{},
    );
    if (value != .object) return error.Malformed;
    const version = stringOf(value.object.get("version")) orelse return error.Malformed;
    const mode = stringOf(value.object.get("mode")) orelse return error.Malformed;
    const uptime = value.object.get("uptime_seconds") orelse return error.Malformed;
    const active = value.object.get("conversions_active") orelse return error.Malformed;
    const cap = value.object.get("conversions_cap") orelse return error.Malformed;
    if (uptime != .integer or active != .integer or cap != .integer) return error.Malformed;
    return std.fmt.allocPrint(
        gpa,
        "zenfmt {s}, {s} mode, uptime {d} seconds, {d} of {d} conversion slots active.",
        .{ version, mode, uptime.integer, active.integer, cap.integer },
    );
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "escaping neutralizes markup" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try esc(&w, "<a b=\"c\">&'</a>");
    try testing.expectEqualStrings(
        "&lt;a b=&quot;c&quot;&gt;&amp;&#39;&lt;/a&gt;",
        w.buffered(),
    );
}

test "parseWriters reads the capability document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const writers = try parseWriters(arena,
        \\{"formats":[{"format":"docx","read":true,"write":false},
        \\{"format":"markdown","read":true,"write":true}]}
    );
    try testing.expectEqual(@as(usize, 1), writers.len);
    try testing.expectEqualStrings("markdown", writers[0]);
}

test "a failure envelope renders panels without a result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const outcome = try parseEnvelope(arena,
        \\{"status":"failed","reports":[{"severity":"error","code":"core.x",
        \\"title":"T","problem":"P","consequence":"C","directions":[]}],
        \\"exit_class":"usage"}
    );
    try testing.expect(outcome.result == null);
    try testing.expect(std.mem.indexOf(u8, outcome.failure_html.?, "alert-error") != null);
    try testing.expect(std.mem.indexOf(u8, outcome.failure_html.?, "core.x") != null);
}
