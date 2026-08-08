//! Allocation-aware inline escaping helpers for the Markdown renderer.

const std = @import("std");
const assert = std.debug.assert;
const support = @import("writer_support.zig");

const Error = error{OutOfMemory};

pub fn appendClose(renderer: anytype, close: anytype) Error!void {
    if (!close.styled) {
        try renderer.inline_buffer.appendSlice(renderer.gpa, close.text);
        return;
    }
    const buffer = &renderer.inline_buffer;
    const delimiter_len = close.text.len;
    assert(delimiter_len <= 2);
    assert(close.open_start + delimiter_len <= buffer.items.len);

    var trailing: usize = 0;
    while (buffer.items.len - trailing > close.open_start + delimiter_len and
        buffer.items[buffer.items.len - trailing - 1] == ' ')
    {
        trailing += 1;
    }
    buffer.items.len -= trailing;
    const leading = leadingSpaces(buffer.items, close.open_start, delimiter_len);
    if (leading > 0) moveOpeningDelimiter(
        buffer.items,
        close.open_start,
        delimiter_len,
        leading,
    );

    const content_start = close.open_start + leading + delimiter_len;
    if (buffer.items.len == content_start) {
        buffer.items.len = close.open_start + leading;
    } else {
        try buffer.appendSlice(renderer.gpa, close.text);
    }
    try buffer.appendNTimes(renderer.gpa, ' ', trailing);
}

fn leadingSpaces(buffer: []const u8, start: u32, delimiter_len: usize) usize {
    var leading: usize = 0;
    while (start + delimiter_len + leading < buffer.len and
        buffer[start + delimiter_len + leading] == ' ')
    {
        leading += 1;
    }
    return leading;
}

fn moveOpeningDelimiter(
    buffer: []u8,
    start: u32,
    delimiter_len: usize,
    leading: usize,
) void {
    assert(delimiter_len <= 2);
    assert(start + delimiter_len + leading <= buffer.len);
    var delimiter: [2]u8 = undefined;
    @memcpy(delimiter[0..delimiter_len], buffer[start..][0..delimiter_len]);
    @memset(buffer[start..][0..leading], ' ');
    @memcpy(buffer[start + leading ..][0..delimiter_len], delimiter[0..delimiter_len]);
}

pub fn linkSuffix(
    renderer: anytype,
    url: []const u8,
    title: []const u8,
) Error![]const u8 {
    var suffix: std.ArrayList(u8) = .empty;
    defer suffix.deinit(renderer.gpa);
    try suffix.appendSlice(renderer.gpa, "](");
    const brackets = std.mem.indexOfAny(u8, url, " <>\n") != null;
    if (brackets) try suffix.append(renderer.gpa, '<');
    for (url) |byte| {
        if (!brackets and (byte == '(' or byte == ')')) {
            try suffix.append(renderer.gpa, '\\');
        }
        try suffix.append(renderer.gpa, byte);
    }
    if (brackets) try suffix.append(renderer.gpa, '>');
    if (title.len > 0) try appendTitle(renderer.gpa, &suffix, title);
    try suffix.append(renderer.gpa, ')');
    return suffix.toOwnedSlice(renderer.gpa);
}

fn appendTitle(
    gpa: std.mem.Allocator,
    suffix: *std.ArrayList(u8),
    title: []const u8,
) Error!void {
    try suffix.appendSlice(gpa, " \"");
    for (title) |byte| {
        if (byte == '"') try suffix.append(gpa, '\\');
        try suffix.append(gpa, byte);
    }
    try suffix.append(gpa, '"');
}

pub fn renderCodeSpan(renderer: anytype, text: []const u8, table_cell: bool) Error!void {
    const fence_len = support.longestRun(text, '`') + 1;
    const pad = text.len == 0 or text[0] == '`' or text[text.len - 1] == '`' or
        text[0] == ' ' or text[text.len - 1] == ' ';
    try renderer.inline_buffer.appendNTimes(renderer.gpa, '`', fence_len);
    if (pad) try renderer.inline_buffer.append(renderer.gpa, ' ');
    for (text) |byte| {
        if (table_cell and byte == '|') {
            try renderer.inline_buffer.appendSlice(renderer.gpa, "\\|");
        } else {
            try renderer.inline_buffer.append(renderer.gpa, byte);
        }
    }
    if (pad) try renderer.inline_buffer.append(renderer.gpa, ' ');
    try renderer.inline_buffer.appendNTimes(renderer.gpa, '`', fence_len);
}

pub fn escapeText(renderer: anytype, text: []const u8, table_cell: bool) Error!void {
    for (text, 0..) |byte, index| {
        const line_start = renderer.inline_buffer.items.len == 0 or
            renderer.inline_buffer.items[renderer.inline_buffer.items.len - 1] == '\n';
        const escape = switch (byte) {
            '\\', '`', '*', '[', ']' => true,
            '_' => support.atWordBoundary(text, index),
            '#', '>', '+', '-' => line_start,
            '.', ')' => support.startsOrderedList(
                renderer.inline_buffer.items,
                text,
                index,
            ),
            '!' => index + 1 < text.len and text[index + 1] == '[',
            '|' => table_cell,
            '<' => true,
            '&' => support.looksLikeEntity(text[index..]),
            else => false,
        };
        if (escape) try renderer.inline_buffer.append(renderer.gpa, '\\');
        try renderer.inline_buffer.append(renderer.gpa, byte);
    }
}
