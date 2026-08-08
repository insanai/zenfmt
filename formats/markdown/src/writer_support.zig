//! Small, allocation-free Markdown writer policies shared by the renderer.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");

pub const InlineMode = enum { multiline, single_line, table_cell };

pub const FrameKind = enum {
    quote,
    container,
    extension,
    figure,
    caption,
    list,
    list_item,
    definition_list,
    definition_entry,
    definition_body,
};

pub const Frame = struct {
    kind: FrameKind,
    end: u32,
    prefix_restore: u32,
    emitted_child: bool = false,
    tight: bool = false,
    ordered: bool = false,
    next_number: i64 = 1,
    delimiter: core.payload.NumberDelimiter = .period,
};

pub const TableBuffer = struct {
    pub const Range = struct { start: usize, len: usize };

    bytes: std.ArrayList(u8) = .empty,
    cells: std.ArrayList(Range) = .empty,
    rows: std.ArrayList(Range) = .empty,

    pub fn deinit(table: *TableBuffer, gpa: std.mem.Allocator) void {
        table.bytes.deinit(gpa);
        table.cells.deinit(gpa);
        table.rows.deinit(gpa);
        table.* = undefined;
    }

    pub fn beginRow(table: *const TableBuffer) usize {
        return table.cells.items.len;
    }

    pub fn appendCell(
        table: *TableBuffer,
        gpa: std.mem.Allocator,
        value: []const u8,
    ) error{OutOfMemory}!void {
        const start = table.bytes.items.len;
        try table.bytes.appendSlice(gpa, value);
        try table.cells.append(gpa, .{ .start = start, .len = value.len });
    }

    pub fn finishRow(
        table: *TableBuffer,
        gpa: std.mem.Allocator,
        start: usize,
    ) error{OutOfMemory}!void {
        assert(start <= table.cells.items.len);
        try table.rows.append(gpa, .{
            .start = start,
            .len = table.cells.items.len - start,
        });
    }

    pub fn row(table: *const TableBuffer, range: Range) []const Range {
        assert(range.start + range.len <= table.cells.items.len);
        return table.cells.items[range.start..][0..range.len];
    }

    pub fn text(table: *const TableBuffer, range: Range) []const u8 {
        assert(range.start + range.len <= table.bytes.items.len);
        return table.bytes.items[range.start..][0..range.len];
    }
};

pub fn atWordBoundary(text: []const u8, index: usize) bool {
    const before_ok = index == 0 or !std.ascii.isAlphanumeric(text[index - 1]);
    const after_ok = index + 1 >= text.len or
        !std.ascii.isAlphanumeric(text[index + 1]);
    return before_ok or after_ok;
}

pub fn startsOrderedList(
    buffer: []const u8,
    text: []const u8,
    index: usize,
) bool {
    if (index == 0) return false;
    var cursor = index;
    var digits: usize = 0;
    while (cursor > 0 and std.ascii.isDigit(text[cursor - 1])) {
        cursor -= 1;
        digits += 1;
    }
    if (digits == 0 or cursor != 0) return false;
    return buffer.len == 0 or buffer[buffer.len - 1] == '\n';
}

pub fn looksLikeEntity(rest: []const u8) bool {
    assert(rest.len > 0 and rest[0] == '&');
    var cursor: usize = 1;
    if (cursor < rest.len and rest[cursor] == '#') cursor += 1;
    const start = cursor;
    while (cursor < rest.len and std.ascii.isAlphanumeric(rest[cursor])) {
        cursor += 1;
    }
    return cursor > start and cursor < rest.len and rest[cursor] == ';';
}

pub fn longestRun(text: []const u8, byte: u8) usize {
    var longest: usize = 0;
    var current: usize = 0;
    for (text) |candidate| {
        if (candidate == byte) {
            current += 1;
            longest = @max(longest, current);
        } else {
            current = 0;
        }
    }
    return longest;
}
