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
    try converter(w, state);
    return out.written();
}

fn navbar(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll(
        \\<div class="navbar bg-base-100 rounded-box shadow-sm">
        \\<div class="navbar-start"><span class="text-xl font-bold px-2">zenfmt</span>
        \\<span class="badge badge-ghost">Convert</span></div>
        \\<div class="navbar-end zf-gap-sm">
    );
    try themeSelector(w, state);
    try w.writeAll("</div></div>");
}

fn themeSelector(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll("<div class=\"join\" role=\"group\" aria-label=\"Theme\">");
    const options = [_]struct { action: []const u8, label: []const u8, theme: main.Theme }{
        .{ .action = "theme_system", .label = "System", .theme = .system },
        .{ .action = "theme_light", .label = "Light", .theme = .light },
        .{ .action = "theme_dark", .label = "Dark", .theme = .dark },
    };
    for (options) |option| {
        try w.print(
            "<button class=\"btn btn-sm join-item{s}\" data-action=\"{s}\">{s}</button>",
            .{
                if (state.stored_theme == option.theme) " btn-active" else "",
                option.action,
                option.label,
            },
        );
    }
    try w.writeAll("</div>");
}

fn converter(w: *std.Io.Writer, state: *const main.State) !void {
    try w.writeAll("<div class=\"zf-row zf-mt\">");

    // Drop zone.
    try w.writeAll(
        \\<div class="zf-grow"><label class="zf-drop" data-drop for="file-input">
    );
    if (state.fileName()) |name| {
        try w.writeAll("<span class=\"font-bold\">");
        try esc(w, name);
        try w.print(
            "</span><br /><span class=\"text-sm opacity-70\">{d} bytes</span>",
            .{state.file_size},
        );
    } else {
        try w.writeAll(
            \\<span>Drop a document or browse</span>
        );
    }
    try w.writeAll(
        \\<input id="file-input" type="file" class="zf-hidden" />
        \\</label></div>
    );

    // Options card.
    try w.writeAll(
        \\<div class="card bg-base-100 shadow-sm"><div class="card-body zf-col">
        \\<label class="form-control"><span class="label-text">to</span>
        \\<select name="to" class="select select-bordered select-sm">
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
        \\<label class="form-control"><span class="label-text">strict</span>
        \\<select name="strict" class="select select-bordered select-sm">
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
            \\<button class="btn btn-primary" disabled>
            \\<span class="loading loading-spinner"></span>Converting</button>
        );
    } else {
        try w.writeAll(
            \\<button class="btn btn-primary" data-action="convert">Convert</button>
        );
    }
    try w.writeAll("</div></div></div>");

    if (state.failure_html) |failure| {
        try w.writeAll("<div class=\"zf-mt\" role=\"alert\" aria-live=\"polite\">");
        try w.writeAll(failure);
        try w.writeAll("</div>");
    }
    if (state.result) |result| try resultCard(w, result);
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

/// Parses the envelope JSON and pre-renders the report panels. Allocations
/// come from `gpa` because the outcome outlives the event.
pub fn parseEnvelope(gpa: std.mem.Allocator, body: []const u8) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    if (value != .object) return error.Malformed;
    const object = value.object;
    const status = object.get("status") orelse return error.Malformed;
    if (status != .string) return error.Malformed;

    var reports_out: std.Io.Writer.Allocating = .init(gpa);
    var report_count: usize = 0;
    if (object.get("reports")) |reports| {
        if (reports == .array) {
            report_count = reports.array.items.len;
            for (reports.array.items) |item| {
                try reportPanel(&reports_out.writer, item);
            }
        }
    }

    if (std.mem.eql(u8, status.string, "success")) {
        const artifact = object.get("artifact") orelse return error.Malformed;
        const name = object.get("artifact_name") orelse return error.Malformed;
        if (artifact != .string or name != .string) return error.Malformed;
        return .{ .result = .{
            .ok = true,
            .artifact = try gpa.dupe(u8, artifact.string),
            .artifact_name = try gpa.dupe(u8, name.string),
            .report_count = report_count,
            .reports_html = reports_out.written(),
        } };
    }
    return .{ .failure_html = reports_out.written() };
}

/// One Elm-style report panel: what happened, the consequence, and what
/// you can do — verbatim, escaped.
fn reportPanel(w: *std.Io.Writer, item: std.json.Value) !void {
    if (item != .object) return;
    const object = item.object;
    const severity = stringOf(object.get("severity")) orelse "error";
    const alert_class = if (std.mem.eql(u8, severity, "warning"))
        "alert-warning"
    else if (std.mem.eql(u8, severity, "note"))
        "alert-info"
    else
        "alert-error";
    try w.print("<div class=\"alert {s} zf-mt\" role=\"status\"><div>", .{alert_class});
    if (stringOf(object.get("title"))) |title| {
        try w.writeAll("<h3 class=\"font-bold\">");
        try esc(w, title);
        try w.writeAll("</h3>");
    }
    if (stringOf(object.get("code"))) |code| {
        try w.writeAll("<span class=\"badge badge-ghost\">");
        try esc(w, code);
        try w.writeAll("</span>");
    }
    if (stringOf(object.get("problem"))) |problem| {
        try w.writeAll("<p>");
        try esc(w, problem);
        try w.writeAll("</p>");
    }
    if (stringOf(object.get("consequence"))) |consequence| {
        try w.writeAll("<p>");
        try esc(w, consequence);
        try w.writeAll("</p>");
    }
    if (object.get("directions")) |directions| {
        if (directions == .array and directions.array.items.len > 0) {
            try w.writeAll("<p class=\"font-bold\">What you can do</p><ul>");
            for (directions.array.items) |direction| {
                if (direction != .object) continue;
                if (stringOf(direction.object.get("explanation"))) |explanation| {
                    try w.writeAll("<li>");
                    try esc(w, explanation);
                    try w.writeAll("</li>");
                }
            }
            try w.writeAll("</ul>");
        }
    }
    try w.writeAll("</div></div>");
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
