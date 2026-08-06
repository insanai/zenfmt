//! Markdown line classification (ZDS 0002): the block pass's grammar of
//! line shapes, separated so the container algorithm reads as algorithm.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");

pub fn isBlank(line: []const u8) bool {
    return std.mem.indexOfNone(u8, line, " \t") == null;
}

pub fn indentWidth(line: []const u8) u32 {
    var width: u32 = 0;
    for (line) |byte| switch (byte) {
        ' ' => width += 1,
        '\t' => width += 4 - (width % 4),
        else => return width,
    };
    return width;
}

pub fn consumeIndent(line: []const u8, columns: u32) []const u8 {
    var width: u32 = 0;
    var i: usize = 0;
    while (i < line.len and width < columns) : (i += 1) {
        switch (line[i]) {
            ' ' => width += 1,
            '\t' => width += 4 - (width % 4),
            else => break,
        }
    }
    return line[i..];
}

pub fn matchQuoteMarker(line: []const u8) ?[]const u8 {
    if (indentWidth(line) >= 4) return null;
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (trimmed.len == 0 or trimmed[0] != '>') return null;
    if (trimmed.len > 1 and trimmed[1] == ' ') return trimmed[2..];
    return trimmed[1..];
}

pub const ListMarker = struct {
    char: u8,
    ordered: bool,
    start: i64,
    delimiter: core.payload.NumberDelimiter,
    /// Marker plus following spaces, in columns.
    width: u32,
    rest: []const u8,
};

pub fn matchListMarker(trimmed: []const u8) ?ListMarker {
    if (trimmed.len == 0) return null;
    var marker_len: u32 = 0;
    var ordered = false;
    var start: i64 = 1;
    var delimiter: core.payload.NumberDelimiter = .period;
    var char = trimmed[0];
    switch (trimmed[0]) {
        '-', '+', '*' => marker_len = 1,
        '0'...'9' => {
            var digits: u32 = 0;
            while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) digits += 1;
            if (digits > 9 or digits >= trimmed.len) return null;
            const delim_byte = trimmed[digits];
            if (delim_byte != '.' and delim_byte != ')') return null;
            ordered = true;
            start = std.fmt.parseInt(i64, trimmed[0..digits], 10) catch return null;
            delimiter = if (delim_byte == '.') .period else .paren;
            char = delim_byte;
            marker_len = digits + 1;
        },
        else => return null,
    }
    if (marker_len >= trimmed.len) {
        // A marker alone on the line is an empty item.
        return .{
            .char = char,
            .ordered = ordered,
            .start = start,
            .delimiter = delimiter,
            .width = marker_len + 1,
            .rest = trimmed[marker_len..],
        };
    }
    if (trimmed[marker_len] != ' ' and trimmed[marker_len] != '\t') return null;
    var spaces: u32 = 0;
    while (marker_len + spaces < trimmed.len and trimmed[marker_len + spaces] == ' ') spaces += 1;
    // More than four spaces means one space plus indented content.
    const consumed_spaces: u32 = if (spaces >= 5 or spaces == 0) 1 else spaces;
    return .{
        .char = char,
        .ordered = ordered,
        .start = start,
        .delimiter = delimiter,
        .width = marker_len + consumed_spaces,
        .rest = trimmed[@min(marker_len + consumed_spaces, trimmed.len)..],
    };
}

pub const AtxHeading = struct {
    level: u8,
    text: []const u8,
};

pub fn matchAtxHeading(trimmed: []const u8) ?AtxHeading {
    var level: u8 = 0;
    while (level < trimmed.len and trimmed[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < trimmed.len and trimmed[level] != ' ' and trimmed[level] != '\t') return null;
    var text = std.mem.trim(u8, trimmed[level..], " \t");
    // A closing run of #s is decoration, not content.
    var end = text.len;
    while (end > 0 and text[end - 1] == '#') end -= 1;
    if (end < text.len and (end == 0 or text[end - 1] == ' ')) {
        text = std.mem.trimEnd(u8, text[0..end], " \t");
    }
    return .{ .level = level, .text = text };
}

pub const Fence = struct {
    char: u8,
    len: u32,
    info: []const u8,
};

pub fn matchFence(trimmed: []const u8) ?Fence {
    if (trimmed.len < 3) return null;
    const char = trimmed[0];
    if (char != '`' and char != '~') return null;
    var len: u32 = 0;
    while (len < trimmed.len and trimmed[len] == char) len += 1;
    if (len < 3) return null;
    const info = std.mem.trim(u8, trimmed[len..], " \t");
    // An info string on a backtick fence cannot contain a backtick.
    if (char == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    // Only the first word names the language.
    const word_end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;
    return .{ .char = char, .len = len, .info = info[0..word_end] };
}

pub fn matchSetext(trimmed: []const u8) ?u8 {
    if (trimmed.len == 0) return null;
    const char = trimmed[0];
    if (char != '=' and char != '-') return null;
    for (trimmed) |byte| {
        if (byte != char) return null;
    }
    return if (char == '=') 1 else 2;
}

pub fn matchThematicBreak(trimmed: []const u8) bool {
    if (trimmed.len == 0) return false;
    const char = trimmed[0];
    if (char != '-' and char != '*' and char != '_') return false;
    var count: u32 = 0;
    for (trimmed) |byte| {
        if (byte == char) {
            count += 1;
        } else if (byte != ' ' and byte != '\t') {
            return false;
        }
    }
    return count >= 3;
}

pub const FootnoteDef = struct {
    label: []const u8,
    rest: []const u8,
};

pub fn matchFootnoteDef(trimmed: []const u8) ?FootnoteDef {
    if (!std.mem.startsWith(u8, trimmed, "[^")) return null;
    const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return null;
    if (close < 3) return null;
    if (close + 1 >= trimmed.len or trimmed[close + 1] != ':') return null;
    return .{
        .label = trimmed[2..close],
        .rest = std.mem.trimStart(u8, trimmed[close + 2 ..], " \t"),
    };
}

pub fn looksLikeHtmlBlock(trimmed: []const u8) bool {
    assert(trimmed.len > 0 and trimmed[0] == '<');
    if (trimmed.len < 2) return false;
    const second = trimmed[1];
    return std.ascii.isAlphabetic(second) or second == '/' or second == '!' or second == '?';
}

pub fn pipeCount(line: []const u8) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
        } else if (line[i] == '|') {
            count += 1;
        }
    }
    return count;
}

/// `| :--- | :---: |` and friends. The caller owns the returned slice.
pub fn delimiterRowAlignments(
    gpa: std.mem.Allocator,
    trimmed: []const u8,
) error{OutOfMemory}!?[]core.payload.Alignment {
    if (std.mem.indexOfNone(u8, trimmed, "|-: \t") != null) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '-') == null) return null;

    var alignments: std.ArrayList(core.payload.Alignment) = .empty;
    errdefer alignments.deinit(gpa);
    var cells = std.mem.splitScalar(u8, std.mem.trim(u8, trimmed, "|"), '|');
    while (cells.next()) |cell_raw| {
        const cell = std.mem.trim(u8, cell_raw, " \t");
        if (cell.len == 0) {
            alignments.deinit(gpa);
            return null;
        }
        const left = cell[0] == ':';
        const right = cell[cell.len - 1] == ':';
        const dashes = std.mem.trim(u8, cell, ":");
        if (dashes.len == 0 or std.mem.indexOfNone(u8, dashes, "-") != null) {
            alignments.deinit(gpa);
            return null;
        }
        try alignments.append(gpa, if (left and right)
            .center
        else if (left)
            .left
        else if (right)
            .right
        else
            .default);
    }
    if (alignments.items.len == 0) {
        alignments.deinit(gpa);
        return null;
    }
    return try alignments.toOwnedSlice(gpa);
}

pub const RefDefParse = struct {
    label: []const u8,
    url: []const u8,
    title: []const u8,
    consumed: usize,
};

/// A single-line `[label]: destination "title"` at the start of `text`.
pub fn parseRefDef(text: []const u8) ?RefDefParse {
    if (!std.mem.startsWith(u8, text, "[")) return null;
    const close = std.mem.indexOfScalar(u8, text, ']') orelse return null;
    if (close + 1 >= text.len or text[close + 1] != ':') return null;
    const label = text[1..close];
    if (label.len == 0 or label[0] == '^') return null;

    const line_end = std.mem.indexOfScalarPos(u8, text, close, '\n') orelse text.len;
    const remainder = std.mem.trim(u8, text[close + 2 .. line_end], " \t");
    if (remainder.len == 0) return null;

    var url = remainder;
    var title: []const u8 = "";
    if (std.mem.indexOfAny(u8, remainder, " \t")) |space| {
        const title_part = std.mem.trimStart(u8, remainder[space..], " \t");
        if (title_part.len >= 2 and
            (title_part[0] == '"' or title_part[0] == '\'') and
            title_part[title_part.len - 1] == title_part[0])
        {
            url = remainder[0..space];
            title = title_part[1 .. title_part.len - 1];
        } else {
            return null;
        }
    }
    if (url.len >= 2 and url[0] == '<' and url[url.len - 1] == '>') {
        url = url[1 .. url.len - 1];
    }
    return .{ .label = label, .url = url, .title = title, .consumed = line_end };
}
