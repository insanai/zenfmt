//! Commands emitted by the UI module for the fixed browser glue.

const std = @import("std");

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

    pub fn title(commands: *Commands, value: []const u8) !void {
        try commands.begin("title");
        try commands.stringField("text", value);
        try commands.end();
    }

    pub fn themeApply(commands: *Commands, scheme: anytype) !void {
        try commands.begin("theme_apply");
        try commands.stringField("theme", @tagName(scheme));
        try commands.end();
    }

    pub fn preferenceStore(commands: *Commands, theme: anytype) !void {
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

    pub fn fetchJson(
        commands: *Commands,
        id: u32,
        method: []const u8,
        path: []const u8,
        body: []const u8,
        csrf: []const u8,
    ) !void {
        try commands.begin("fetch");
        try commands.out.writer.print(",\"id\":{d}", .{id});
        try commands.stringField("method", method);
        try commands.stringField("path", path);
        try commands.stringField("accept", "application/json");
        try commands.stringField("body", "json");
        try commands.stringField("text", body);
        if (csrf.len > 0) try commands.stringField("csrf", csrf);
        try commands.end();
    }

    pub fn fetchFile(
        commands: *Commands,
        id: u32,
        path: []const u8,
        csrf: []const u8,
    ) !void {
        try commands.begin("fetch");
        try commands.out.writer.print(",\"id\":{d}", .{id});
        try commands.stringField("method", "POST");
        try commands.stringField("path", path);
        try commands.stringField("accept", "application/json");
        try commands.stringField("body", "file");
        if (csrf.len > 0) try commands.stringField("csrf", csrf);
        try commands.end();
    }

    pub fn navigate(commands: *Commands, path: []const u8) !void {
        try commands.begin("navigate");
        try commands.stringField("path", path);
        try commands.end();
    }

    pub fn dialogOpen(commands: *Commands, id: []const u8) !void {
        try commands.begin("dialog_open");
        try commands.stringField("id", id);
        try commands.end();
    }

    pub fn dialogClose(commands: *Commands, id: []const u8) !void {
        try commands.begin("dialog_close");
        try commands.stringField("id", id);
        try commands.end();
    }

    pub fn clipboard(commands: *Commands, value: []const u8) !void {
        try commands.begin("clipboard");
        try commands.stringField("text", value);
        try commands.end();
    }

    pub fn download(
        commands: *Commands,
        name: []const u8,
        media: []const u8,
        value: []const u8,
    ) !void {
        try commands.begin("download");
        try commands.stringField("name", name);
        try commands.stringField("media", media);
        try commands.stringField("text", value);
        try commands.end();
    }

    pub fn finish(commands: *Commands) ![]const u8 {
        if (commands.count == 0) return "[]";
        try commands.out.writer.writeAll("]");
        return commands.out.written();
    }
};

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            try writer.print("\\u{x:0>4}", .{byte});
        },
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}
