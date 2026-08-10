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

/// The command protocol version; the glue refuses a mismatch at load.
pub const abi_version: u32 = 1;

pub const Theme = enum { system, light, dark };
pub const Scheme = enum { light, dark };

pub const fetch_formats_id: u32 = 1;
pub const fetch_convert_id: u32 = 2;

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

/// The whole interface state; one instance lives for the page's lifetime.
pub const State = struct {
    gpa: std.mem.Allocator,
    path: []const u8 = "/",
    stored_theme: Theme = .system,
    system_scheme: Scheme = .light,
    file_name_buf: [max_file_name]u8 = undefined,
    file_name_len: usize = 0,
    file_size: u64 = 0,
    busy: bool = false,
    writers: []const []const u8 = &.{},
    selected_to: []const u8 = "markdown",
    selected_strict: []const u8 = "off",
    result: ?Result = null,
    failure_html: ?[]const u8 = null,

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
    body: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

/// The command list builder: commands accumulate as JSON array elements.
pub const Commands = struct {
    out: std.Io.Writer.Allocating,
    count: usize = 0,

    pub fn init(arena: std.mem.Allocator) Commands {
        return .{ .out = .init(arena) };
    }

    fn begin(commands: *Commands, cmd: []const u8) !void {
        try commands.out.writer.writeAll(if (commands.count == 0) "[" else ",");
        commands.count += 1;
        try commands.out.writer.print("{{\"cmd\":\"{s}\"", .{cmd});
    }

    fn stringField(commands: *Commands, name: []const u8, value: []const u8) !void {
        try commands.out.writer.print(",\"{s}\":", .{name});
        try writeJsonString(&commands.out.writer, value);
    }

    fn end(commands: *Commands) !void {
        try commands.out.writer.writeAll("}");
    }

    pub fn patch(commands: *Commands, id: []const u8, html: []const u8) !void {
        try commands.begin("patch");
        try commands.stringField("id", id);
        try commands.stringField("html", html);
        try commands.end();
    }

    pub fn title(commands: *Commands, text: []const u8) !void {
        try commands.begin("title");
        try commands.stringField("text", text);
        try commands.end();
    }

    pub fn themeApply(commands: *Commands, scheme: Scheme) !void {
        try commands.begin("theme_apply");
        try commands.stringField("theme", @tagName(scheme));
        try commands.end();
    }

    pub fn preferenceStore(commands: *Commands, theme: Theme) !void {
        try commands.begin("preference_store");
        try commands.stringField("theme", @tagName(theme));
        try commands.end();
    }

    pub fn focus(commands: *Commands, id: []const u8) !void {
        try commands.begin("focus");
        try commands.stringField("id", id);
        try commands.end();
    }

    pub fn fetch(
        commands: *Commands,
        id: u32,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) !void {
        try commands.begin("fetch");
        try commands.out.writer.print(",\"id\":{d}", .{id});
        try commands.stringField("method", method);
        try commands.stringField("path", path);
        try commands.stringField("accept", "application/json");
        try commands.stringField("body", body);
        try commands.end();
    }

    pub fn download(
        commands: *Commands,
        name: []const u8,
        media: []const u8,
        text: []const u8,
    ) !void {
        try commands.begin("download");
        try commands.stringField("name", name);
        try commands.stringField("media", media);
        try commands.stringField("text", text);
        try commands.end();
    }

    pub fn finish(commands: *Commands) ![]const u8 {
        if (commands.count == 0) return "[]";
        try commands.out.writer.writeAll("]");
        return commands.out.written();
    }
};

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

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
    // The interface is a client of the public API: capability discovery
    // comes from the same route every other client uses.
    try commands.fetch(fetch_formats_id, "GET", "/api/v1/formats", "none");
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
            return;
        }
        state.busy = true;
        state.failure_html = null;
        try renderPage(arena, state, commands);
        const path = try std.fmt.allocPrint(
            arena,
            "/api/v1/convert?to={s}{s}{s}",
            .{
                state.selected_to,
                if (std.mem.eql(u8, state.selected_strict, "off")) "" else "&strict=",
                if (std.mem.eql(u8, state.selected_strict, "off")) "" else state.selected_strict,
            },
        );
        try commands.fetch(fetch_convert_id, "POST", path, "file");
    } else if (std.mem.eql(u8, name, "download")) {
        if (state.result) |result| {
            try commands.download(result.artifact_name, "text/markdown", result.artifact);
        }
    }
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
    const body = event.body orelse "";
    switch (id) {
        fetch_formats_id => {
            state.writers = render.parseWriters(state.gpa, body) catch state.writers;
            try renderPage(arena, state, commands);
        },
        fetch_convert_id => {
            state.busy = false;
            const outcome = render.parseEnvelope(state.gpa, body) catch {
                state.failure_html = try render.transportFailure(
                    state.gpa,
                    "the server's answer could not be read",
                );
                try renderPage(arena, state, commands);
                return;
            };
            state.result = outcome.result;
            state.failure_html = outcome.failure_html;
            try renderPage(arena, state, commands);
        },
        else => {},
    }
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

// ---------------------------------------------------------------- tests

const testing = std.testing;

test {
    _ = render;
}

fn testState(arena: std.mem.Allocator) State {
    return .{ .gpa = arena };
}

test "init renders the converter and discovers capabilities" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);

    const commands = try handleEvent(arena, &state,
        \\{"event":"init","path":"/","stored_theme":"system","system_scheme":"dark"}
    );
    try testing.expect(std.mem.indexOf(u8, commands, "\"cmd\":\"title\"") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "\"cmd\":\"patch\"") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "Drop a document") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "/api/v1/formats") != null);
    // System preference resolves to the dark scheme.
    try testing.expect(std.mem.indexOf(u8, commands, "\"theme\":\"dark\"") != null);
    try testing.expectEqual(Theme.system, state.stored_theme);
}

test "an explicit theme choice persists and applies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try handleEvent(arena, &state,
        \\{"event":"init","path":"/","stored_theme":"system","system_scheme":"light"}
    );

    const commands = try handleEvent(arena, &state,
        \\{"event":"action","name":"theme_dark","fields":{}}
    );
    try testing.expect(std.mem.indexOf(
        u8,
        commands,
        "\"cmd\":\"preference_store\",\"theme\":\"dark\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        commands,
        "\"cmd\":\"theme_apply\",\"theme\":\"dark\"",
    ) != null);
    try testing.expectEqual(Theme.dark, state.stored_theme);

    // Back to system: follows the reported scheme again.
    const back = try handleEvent(arena, &state,
        \\{"event":"action","name":"theme_system","fields":{}}
    );
    try testing.expect(std.mem.indexOf(
        u8,
        back,
        "\"cmd\":\"theme_apply\",\"theme\":\"light\"",
    ) != null);
}

test "a system scheme change re-applies only under the system preference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try handleEvent(arena, &state,
        \\{"event":"init","path":"/","stored_theme":"system","system_scheme":"light"}
    );

    const commands = try handleEvent(arena, &state,
        \\{"event":"color_scheme_change","scheme":"dark"}
    );
    try testing.expect(std.mem.indexOf(u8, commands, "\"theme\":\"dark\"") != null);

    _ = try handleEvent(arena, &state,
        \\{"event":"action","name":"theme_light","fields":{}}
    );
    const pinned = try handleEvent(arena, &state,
        \\{"event":"color_scheme_change","scheme":"light"}
    );
    try testing.expect(std.mem.indexOf(u8, pinned, "theme_apply") == null);
}

test "convert without a file explains itself; with a file it fetches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try handleEvent(arena, &state,
        \\{"event":"init","path":"/","stored_theme":"system","system_scheme":"light"}
    );

    const refused = try handleEvent(arena, &state,
        \\{"event":"action","name":"convert","fields":{"to":"markdown","strict":"off"}}
    );
    try testing.expect(std.mem.indexOf(u8, refused, "pick or drop a document") != null);
    try testing.expect(std.mem.indexOf(u8, refused, "\"cmd\":\"fetch\"") == null);

    _ = try handleEvent(arena, &state,
        \\{"event":"file","name":"report.docx","size":1234}
    );
    const converted = try handleEvent(arena, &state,
        \\{"event":"action","name":"convert","fields":{"to":"markdown","strict":"exact"}}
    );
    try testing.expect(std.mem.indexOf(
        u8,
        converted,
        "/api/v1/convert?to=markdown&strict=exact",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, converted, "\"body\":\"file\"") != null);
    try testing.expect(state.busy);
}

test "a success envelope becomes the result card; reports render verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try handleEvent(arena, &state,
        \\{"event":"init","path":"/","stored_theme":"system","system_scheme":"light"}
    );
    _ = try handleEvent(arena, &state,
        \\{"event":"file","name":"report.docx","size":1234}
    );
    _ = try handleEvent(arena, &state,
        \\{"event":"action","name":"convert","fields":{"to":"markdown","strict":"off"}}
    );

    const envelope =
        \\{"event":"fetch_done","id":2,"status":200,"body":"{\"status\":\"success\",\"artifact\":\"# Hi\",\"artifact_name\":\"report.md\",\"reports\":[{\"severity\":\"warning\",\"code\":\"docx.comment-dropped\",\"title\":\"A COMMENT WAS DROPPED\",\"problem\":\"The comment has no Markdown form.\",\"consequence\":\"The comment is gone.\",\"directions\":[{\"title\":\"What you can do\",\"explanation\":\"Nothing; comments have no home in Markdown.\"}]}],\"exit_class\":\"conversion\"}"}
    ;
    const commands = try handleEvent(arena, &state, envelope);
    try testing.expect(!state.busy);
    try testing.expect(state.result != null);
    try testing.expectEqualStrings("report.md", state.result.?.artifact_name);
    try testing.expect(std.mem.indexOf(u8, commands, "report.md") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "docx.comment-dropped") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "A COMMENT WAS DROPPED") != null);

    const download = try handleEvent(arena, &state,
        \\{"event":"action","name":"download","fields":{}}
    );
    try testing.expect(std.mem.indexOf(u8, download, "\"cmd\":\"download\"") != null);
}

test "hostile strings in the envelope are escaped by construction" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = testState(arena);
    _ = try handleEvent(arena, &state,
        \\{"event":"init","path":"/","stored_theme":"system","system_scheme":"light"}
    );
    _ = try handleEvent(arena, &state,
        \\{"event":"file","name":"x.docx","size":1}
    );
    _ = try handleEvent(arena, &state,
        \\{"event":"action","name":"convert","fields":{}}
    );
    const commands = try handleEvent(arena, &state,
        \\{"event":"fetch_done","id":2,"status":400,"body":"{\"status\":\"failed\",\"reports\":[{\"severity\":\"error\",\"code\":\"server.invalid-query\",\"title\":\"<script>alert(1)</script>\",\"problem\":\"<img src=x>\",\"consequence\":\"c\",\"directions\":[]}],\"exit_class\":\"usage\"}"}
    );
    try testing.expect(std.mem.indexOf(u8, commands, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, commands, "&lt;script&gt;") != null);
}
