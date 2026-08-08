//! The Markdown writer (ZDS 0002, The Markdown Writer).
//!
//! CommonMark plus the GFM extensions, and the definition of what zenfmt
//! output looks like. Escaping is the minimum that preserves meaning at the
//! position where text is emitted. Output is deterministic: `\n` always,
//! never a trailing space, exactly one blank line between blocks, exactly
//! one newline at end of file.
//!
//! The walker is non-recursive: one explicit frame stack drives block
//! nesting and line prefixes, and a second explicit stack drives inline
//! delimiters. A block's inline content is rendered into a reused buffer
//! first, because escaping depends on line-start positions that only exist
//! once the text is laid out.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const ast = core.ast;
const support = @import("writer_support.zig");
const inline_output = @import("writer_inline.zig");
const InlineMode = support.InlineMode;
const FrameKind = support.FrameKind;
const Frame = support.Frame;
const TableBuffer = support.TableBuffer;
const longestRun = support.longestRun;

const InlineDelimiters = struct {
    open: []const u8 = "",
    close: []const u8 = "",
    styled: bool = false,
};

const InlineClose = struct {
    end: u32,
    text: []const u8,
    open_start: u32,
    styled: bool,
};
pub const writer = core.Writer(.{
    .id = "ai.insan.zenfmt.markdown",
    .format = "markdown",
    .extensions = &.{ "md", "markdown" },
    .write = write,
    .capabilities = &capabilities_mod.capabilities,
});

pub fn write(ctx: *core.WriteContext) core.WriteError!void {
    var renderer = try Renderer.init(ctx);
    defer renderer.deinit();
    try renderer.renderForest(ctx.doc.body, null);
    try renderer.renderNotes();
}
const Renderer = struct {
    const no_note = std.math.maxInt(u32);

    gpa: std.mem.Allocator,
    doc: *const ast.Document,
    out: *std.Io.Writer,
    reports: *core.Reports,
    limits: core.Limits,
    /// The lowering plan (ZDS 0013); every degradation site records its
    /// rule hit here, and the engine prices and reports the result. Null
    /// when the writer runs outside the engine: hits then report directly.
    plan: ?*core.lowering.Plan = null,

    prefix: std.ArrayList(u8) = .empty,
    /// Replaces the tail of the prefix on the next written line: a list
    /// marker or footnote label.
    pending_marker: ?[]const u8 = null,
    inline_buffer: std.ArrayList(u8) = .empty,
    cell_buffer: std.ArrayList(u8) = .empty,
    /// Note payload indices in order of first reference; index+1 is the label.
    notes: std.ArrayList(u32) = .empty,
    /// Payload index to label, so repeated and cyclic references cannot grow
    /// the note work list. Empty for documents without note payloads.
    note_labels: []u32,
    frames: []Frame,
    inline_closes: []InlineClose,
    depth: u32 = 0,
    emitted_root: bool = false,
    fn init(ctx: *core.WriteContext) core.WriteError!Renderer {
        const count = ctx.doc.store.block_ranges.items.len;
        const labels: []u32 = if (count == 0)
            &.{}
        else
            try ctx.gpa.alloc(u32, count);
        errdefer if (labels.len > 0) ctx.gpa.free(labels);
        const frames = try ctx.gpa.alloc(Frame, ctx.limits.max_depth);
        errdefer ctx.gpa.free(frames);
        const inline_closes = try ctx.gpa.alloc(InlineClose, ctx.limits.max_depth);
        errdefer ctx.gpa.free(inline_closes);
        @memset(labels, no_note);
        return .{
            .gpa = ctx.gpa,
            .doc = ctx.doc,
            .out = ctx.out,
            .reports = ctx.reports,
            .limits = ctx.limits,
            .plan = ctx.plan,
            .note_labels = labels,
            .frames = frames,
            .inline_closes = inline_closes,
        };
    }

    fn deinit(r: *Renderer) void {
        r.prefix.deinit(r.gpa);
        r.inline_buffer.deinit(r.gpa);
        r.cell_buffer.deinit(r.gpa);
        r.notes.deinit(r.gpa);
        if (r.note_labels.len > 0) r.gpa.free(r.note_labels);
        r.gpa.free(r.frames);
        r.gpa.free(r.inline_closes);
    }

    /// Records one degradation at an emission site. Under the engine the
    /// hit lands in the lowering plan, which prices it and flushes one
    /// aggregated report per rule; standalone, the note reports directly.
    fn hit(r: *Renderer, id: capabilities_mod.RuleId) core.WriteError!void {
        if (r.plan) |plan| {
            plan.hit(@intFromEnum(id));
        } else {
            try r.reports.add(capabilities_mod.rules[@intFromEnum(id)].note());
        }
    }
    // -------------------------------------------------------- line output

    fn writeLine(r: *Renderer, line: []const u8) core.WriteError!void {
        if (r.pending_marker) |marker| {
            assert(marker.len <= r.prefix.items.len);
            const kept = r.prefix.items[0 .. r.prefix.items.len - marker.len];
            try r.out.writeAll(kept);
            try r.out.writeAll(marker);
            r.pending_marker = null;
        } else if (line.len == 0) {
            // Never a trailing space: a blank line carries a trimmed prefix.
            const trimmed = std.mem.trimEnd(u8, r.prefix.items, " ");
            try r.out.writeAll(trimmed);
        } else {
            try r.out.writeAll(r.prefix.items);
        }
        try r.out.writeAll(line);
        try r.out.writeAll("\n");
    }

    /// A blank line never consumes a pending marker: the marker belongs to
    /// the first content line that follows.
    fn writeBlank(r: *Renderer) core.WriteError!void {
        const pending_len = if (r.pending_marker) |marker| marker.len else 0;
        assert(pending_len <= r.prefix.items.len);
        const kept = r.prefix.items[0 .. r.prefix.items.len - pending_len];
        try r.out.writeAll(std.mem.trimEnd(u8, kept, " "));
        try r.out.writeAll("\n");
    }

    /// Markers stack: a list item whose first child is another list puts
    /// both markers on one line, so a new marker appends to any pending
    /// one.
    fn setPendingMarker(r: *Renderer, marker: []const u8) core.WriteError!void {
        if (r.pending_marker) |existing| {
            const combined = try std.mem.concat(r.gpa, u8, &.{ existing, marker });
            r.pending_marker = combined;
        } else {
            r.pending_marker = try r.gpa.dupe(u8, marker);
        }
    }

    fn writeBufferLines(r: *Renderer, buffer: []const u8) core.WriteError!void {
        var lines = std.mem.splitScalar(u8, buffer, '\n');
        while (lines.next()) |line| try r.writeLine(line);
    }

    // ------------------------------------------------------ block walking

    /// Renders one block forest. `initial_marker` labels the first line —
    /// a footnote definition marker; block prefixes come from frames.
    fn renderForest(
        r: *Renderer,
        range: ast.BlockRange,
        initial_marker: ?[]const u8,
    ) core.WriteError!void {
        assert(r.depth == 0);
        if (initial_marker) |marker| try r.beginMarkedForest(marker);
        const prefix_base = if (initial_marker) |marker|
            r.prefix.items.len - marker.len
        else
            r.prefix.items.len;
        var cursor = range.startRaw();
        while (cursor < range.endRaw()) {
            r.closeBlockFrames(cursor);
            try r.separate();
            try r.renderBlock(&cursor);
        }
        r.closeAllBlockFrames();
        assert(r.pending_marker == null or range.len == 0);
        r.pending_marker = null;
        r.prefix.shrinkRetainingCapacity(prefix_base);
    }

    fn beginMarkedForest(r: *Renderer, marker: []const u8) core.WriteError!void {
        assert(marker.len > 0);
        try r.prefix.appendNTimes(r.gpa, ' ', marker.len);
        try r.setPendingMarker(marker);
    }

    fn closeBlockFrames(r: *Renderer, cursor: u32) void {
        while (r.depth > 0 and r.frames[r.depth - 1].end == cursor) {
            r.prefix.shrinkRetainingCapacity(r.frames[r.depth - 1].prefix_restore);
            r.depth -= 1;
        }
    }

    fn closeAllBlockFrames(r: *Renderer) void {
        while (r.depth > 0) {
            r.prefix.shrinkRetainingCapacity(r.frames[r.depth - 1].prefix_restore);
            r.depth -= 1;
        }
    }

    fn renderBlock(r: *Renderer, cursor: *u32) core.WriteError!void {
        const tag = r.doc.store.blocks.items(.tag)[cursor.*];
        switch (tag) {
            .paragraph,
            .plain,
            .heading,
            .code_block,
            .raw_block,
            .thematic_break,
            .line_block,
            .table,
            .definition_term,
            => try r.renderLeafBlock(tag, cursor),
            .quote,
            .container,
            .extension,
            .figure,
            .caption,
            .definition_list,
            .definition_entry,
            .definition_body,
            .list,
            .list_item,
            => try r.renderContainerBlock(tag, cursor),
            .line,
            .table_head,
            .table_body,
            .table_foot,
            .table_row,
            .table_cell,
            => unreachable,
        }
    }

    fn renderLeafBlock(
        r: *Renderer,
        tag: ast.BlockTag,
        cursor: *u32,
    ) core.WriteError!void {
        const subtree_len = r.doc.store.blocks.items(.subtree_len)[cursor.*];
        switch (tag) {
            .paragraph, .plain => {
                const view = r.doc.block(@enumFromInt(cursor.*));
                const inlines = switch (view.content) {
                    .paragraph, .plain => |value| value,
                    else => unreachable,
                };
                try r.writeBufferLines(try r.renderInlines(inlines, .multiline));
                cursor.* += 1;
            },
            .heading => try r.renderHeading(cursor.*, cursor),
            .code_block => try r.renderCodeBlock(cursor.*, cursor),
            .raw_block => try r.renderRawBlock(cursor.*, cursor),
            .thematic_break => {
                try r.writeLine("---");
                cursor.* += 1;
            },
            .line_block => {
                try r.renderLineBlock(cursor.*);
                cursor.* += subtree_len;
            },
            .table => {
                try r.renderTable(cursor.*);
                cursor.* += subtree_len;
            },
            .definition_term => try r.renderDefinitionTerm(cursor),
            else => unreachable,
        }
    }

    fn renderDefinitionTerm(r: *Renderer, cursor: *u32) core.WriteError!void {
        const term = r.doc.blockAs(@enumFromInt(cursor.*), .definition_term).?;
        const buffer = try r.renderInlines(term, .single_line);
        const bold = try std.fmt.allocPrint(r.gpa, "**{s}**", .{buffer});
        defer r.gpa.free(bold);
        try r.writeLine(bold);
        cursor.* += 1;
    }

    fn renderContainerBlock(
        r: *Renderer,
        tag: ast.BlockTag,
        cursor: *u32,
    ) core.WriteError!void {
        const end = cursor.* + r.doc.store.blocks.items(.subtree_len)[cursor.*];
        switch (tag) {
            .quote => {
                try r.push(.quote, end);
                try r.prefix.appendSlice(r.gpa, "> ");
            },
            .container => {
                try r.reportContainerAttrs(cursor.*);
                try r.push(.container, end);
            },
            .extension => {
                try r.hit(.extension_fallback);
                try r.push(.extension, end);
            },
            .figure => try r.push(.figure, end),
            .caption => try r.push(.caption, end),
            .definition_list => {
                try r.reportDefinitionList();
                try r.push(.definition_list, end);
            },
            .definition_entry => try r.push(.definition_entry, end),
            .definition_body => try r.push(.definition_body, end),
            .list => try r.pushList(cursor.*),
            .list_item => try r.pushListItem(cursor.*),
            else => unreachable,
        }
        cursor.* += 1;
    }

    /// A blank line between siblings, except within a tight list — between
    /// its items and between the blocks inside each item — and before the
    /// first child of a container.
    fn separate(r: *Renderer) core.WriteError!void {
        if (r.depth > 0) {
            const parent = &r.frames[r.depth - 1];
            if (parent.emitted_child) {
                const tight = switch (parent.kind) {
                    .list, .list_item => parent.tight,
                    else => false,
                };
                if (!tight) try r.writeBlank();
            }
            parent.emitted_child = true;
        } else {
            if (r.emitted_root) try r.writeBlank();
            r.emitted_root = true;
        }
    }

    fn push(r: *Renderer, kind: FrameKind, end: u32) core.WriteError!void {
        assert(r.depth < r.limits.max_depth);
        r.frames[r.depth] = .{
            .kind = kind,
            .end = end,
            .prefix_restore = @intCast(r.prefix.items.len),
        };
        r.depth += 1;
    }

    fn pushList(r: *Renderer, index: u32) core.WriteError!void {
        const list = r.doc.blockAs(@enumFromInt(index), .list).?;
        // A list is tight when no item leads with a `paragraph`.
        var tight = true;
        var items = r.doc.blockChildren(@enumFromInt(index));
        while (items.next()) |item| {
            var blocks = r.doc.blockChildren(item);
            if (blocks.next()) |first| {
                if (r.doc.blockTag(first) == .paragraph) tight = false;
            }
        }
        if (list.style != .decimal and list.kind == .ordered) {
            try r.hit(.number_style);
        }
        try r.push(.list, index + r.doc.store.blocks.items(.subtree_len)[index]);
        const frame = &r.frames[r.depth - 1];
        frame.tight = tight;
        frame.ordered = list.kind == .ordered;
        frame.next_number = list.start;
        frame.delimiter = list.delimiter;
    }

    fn pushListItem(r: *Renderer, index: u32) core.WriteError!void {
        assert(r.depth > 0);
        const parent = &r.frames[r.depth - 1];
        assert(parent.kind == .list);
        const list_tight = parent.tight;

        var marker_buffer: [24]u8 = undefined;
        const marker = if (parent.ordered) blk: {
            const delimiter: u8 = switch (parent.delimiter) {
                .period => '.',
                .paren, .two_parens => ')',
            };
            const text = std.fmt.bufPrint(&marker_buffer, "{d}{c} ", .{
                parent.next_number, delimiter,
            }) catch unreachable;
            parent.next_number += 1;
            break :blk text;
        } else "- ";

        const subtree_len = r.doc.store.blocks.items(.subtree_len)[index];
        try r.push(.list_item, index + subtree_len);
        r.frames[r.depth - 1].tight = list_tight;
        try r.prefix.appendNTimes(r.gpa, ' ', marker.len);
        try r.setPendingMarker(marker);
    }

    // ------------------------------------------------------- leaf blocks

    fn renderHeading(r: *Renderer, index: u32, cursor: *u32) core.WriteError!void {
        const heading = r.doc.blockAs(@enumFromInt(index), .heading).?;
        const buffer = try r.renderInlines(heading.inlines, .single_line);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(r.gpa);
        try line.appendNTimes(r.gpa, '#', heading.level);
        try line.append(r.gpa, ' ');
        try line.appendSlice(r.gpa, buffer);
        const attrs = r.doc.attrsOf(r.doc.block(@enumFromInt(index)).attrs);
        if (attrs.id.len > 0) {
            try line.appendSlice(r.gpa, " {#");
            try line.appendSlice(r.gpa, r.doc.text(attrs.id));
            try line.append(r.gpa, '}');
        }
        try r.writeLine(line.items);
        cursor.* = index + 1;
    }

    fn renderCodeBlock(r: *Renderer, index: u32, cursor: *u32) core.WriteError!void {
        const text = r.doc.text(r.doc.blockAs(@enumFromInt(index), .code_block).?);
        const attrs = r.doc.attrsOf(r.doc.block(@enumFromInt(index)).attrs);

        // The fence must be longer than any backtick run in the content.
        const fence_len = @max(3, longestRun(text, '`') + 1);
        var fence: std.ArrayList(u8) = .empty;
        defer fence.deinit(r.gpa);
        try fence.appendNTimes(r.gpa, '`', fence_len);
        if (attrs.classes.len > 0) {
            const language = r.doc.store.strings.items[attrs.classes.start];
            try fence.appendSlice(r.gpa, r.doc.text(language));
        }
        try r.writeLine(fence.items);
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (lines.next()) |line| try r.writeLine(line);
        try r.writeLine(fence.items[0..fence_len]);
        cursor.* = index + 1;
    }

    fn renderRawBlock(r: *Renderer, index: u32, cursor: *u32) core.WriteError!void {
        const raw = r.doc.blockAs(@enumFromInt(index), .raw_block).?;
        const format = r.doc.text(raw.format);
        if (std.mem.eql(u8, format, "markdown") or std.mem.eql(u8, format, "html")) {
            const text = std.mem.trimEnd(u8, r.doc.text(raw.text), "\n");
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| try r.writeLine(line);
        } else {
            try r.hit(.raw_dropped);
        }
        cursor.* = index + 1;
    }

    fn renderLineBlock(r: *Renderer, index: u32) core.WriteError!void {
        var assembled: std.ArrayList(u8) = .empty;
        defer assembled.deinit(r.gpa);
        var children = r.doc.blockChildren(@enumFromInt(index));
        var first = true;
        while (children.next()) |child| {
            const inlines = r.doc.blockAs(child, .line).?;
            const buffer = try r.renderInlines(inlines, .single_line);
            if (!first) try assembled.appendSlice(r.gpa, "\\\n");
            try assembled.appendSlice(r.gpa, buffer);
            first = false;
        }
        try r.writeBufferLines(assembled.items);
    }

    // ------------------------------------------------------------ tables

    const max_column_pad = 30;

    fn renderTable(r: *Renderer, index: u32) core.WriteError!void {
        const table = r.doc.blockAs(@enumFromInt(index), .table).?;
        const column_end = table.columns.start + table.columns.len;
        const alignments = r.doc.store.columns.items[table.columns.start..column_end];

        // One contiguous byte buffer avoids an arena allocation per cell.
        var rendered: TableBuffer = .{};
        defer rendered.deinit(r.gpa);
        var caption: ?ast.BlockRange = null;
        var sections = r.doc.blockChildren(@enumFromInt(index));
        while (sections.next()) |section| {
            switch (r.doc.blockTag(section)) {
                .caption => caption = switch (r.doc.block(section).content) {
                    .caption => |blocks| blocks,
                    else => unreachable,
                },
                .table_head, .table_body, .table_foot => {
                    var section_rows = r.doc.blockChildren(section);
                    while (section_rows.next()) |row| {
                        try r.renderRow(row, &rendered);
                    }
                },
                else => unreachable,
            }
        }
        if (rendered.rows.items.len == 0) {
            if (caption) |blocks| try r.writeCaption(blocks, false);
            return;
        }

        var column_count: usize = alignments.len;
        for (rendered.rows.items) |row| column_count = @max(column_count, row.len);
        assert(column_count > 0);

        // Common column widths, capped so one long cell does not pad the
        // whole document.
        const widths = try r.gpa.alloc(usize, column_count);
        defer r.gpa.free(widths);
        for (widths, 0..) |*width, column| {
            width.* = 3;
            for (rendered.rows.items) |row_range| {
                const row = rendered.row(row_range);
                if (column < row.len) {
                    width.* = @max(width.*, row[column].len);
                }
            }
            width.* = @min(width.*, max_column_pad);
        }

        try r.writeTableRow(&rendered, rendered.rows.items[0], widths);
        try r.writeSeparatorRow(alignments, widths);
        for (rendered.rows.items[1..]) |row| {
            try r.writeTableRow(&rendered, row, widths);
        }

        if (caption) |blocks| try r.writeCaption(blocks, true);
    }

    fn renderRow(
        r: *Renderer,
        row: ast.BlockIndex,
        rendered: *TableBuffer,
    ) core.WriteError!void {
        const start = rendered.beginRow();
        var children = r.doc.blockChildren(row);
        while (children.next()) |cell_index| {
            const cell = r.doc.blockAs(cell_index, .table_cell).?;
            if (cell.col_span > 1 or cell.row_span > 1) {
                try r.hit(.cell_span);
            }
            try rendered.appendCell(r.gpa, try r.renderCellText(cell.blocks));
            var extra: u32 = 1;
            while (extra < cell.col_span) : (extra += 1) {
                try rendered.appendCell(r.gpa, "");
            }
        }
        try rendered.finishRow(r.gpa, start);
    }

    /// A GFM cell is one line of inline text. Multiple blocks, or any block
    /// that is not a paragraph, are flattened with a note; a nested table
    /// becomes a placeholder and a warning.
    fn renderCellText(r: *Renderer, blocks: ast.BlockRange) core.WriteError![]const u8 {
        r.cell_buffer.clearRetainingCapacity();
        const lengths = r.doc.store.blocks.items(.subtree_len);
        var cursor = blocks.startRaw();
        while (cursor < blocks.endRaw()) {
            if (r.doc.blockTag(@enumFromInt(cursor)) == .table) {
                try r.appendCellPiece("(nested table)", false);
                try r.hit(.nested_table);
                cursor += lengths[cursor];
            } else {
                try r.appendCellBlock(cursor);
                cursor += 1;
            }
        }
        if (capabilities_mod.cellNeedsFlattening(r.doc, blocks)) {
            try r.hit(.cell_flattened);
        }
        assert(cursor == blocks.endRaw());
        assert(std.mem.indexOfScalar(u8, r.cell_buffer.items, '\n') == null);
        return r.cell_buffer.items;
    }

    fn appendCellBlock(r: *Renderer, index: u32) core.WriteError!void {
        const block_index: ast.BlockIndex = @enumFromInt(index);
        const view = r.doc.block(block_index);
        if (cellInlineContent(view)) |inlines| {
            const rendered = try r.renderInlines(inlines, .table_cell);
            try r.appendCellPiece(rendered, false);
            return;
        }
        switch (view.content) {
            .code_block => |text| try r.appendCellLiteral(r.doc.text(text), true),
            .raw_block => |raw| try r.appendCellRaw(raw),
            .container => try r.reportContainerAttrs(index),
            .extension => try r.hit(.extension_fallback),
            .definition_list => try r.reportDefinitionList(),
            .list => |list| {
                if (list.kind == .ordered and list.style != .decimal) {
                    try r.hit(.number_style);
                }
            },
            else => {},
        }
    }

    fn appendCellRaw(r: *Renderer, raw: core.payload.Raw) core.WriteError!void {
        const format = r.doc.text(raw.format);
        if (std.mem.eql(u8, format, "markdown") or
            std.mem.eql(u8, format, "html"))
        {
            try r.appendCellLiteral(r.doc.text(raw.text), false);
        } else {
            try r.hit(.raw_dropped);
        }
    }

    fn appendCellLiteral(
        r: *Renderer,
        text: []const u8,
        code: bool,
    ) core.WriteError!void {
        if (!code) return r.appendCellPiece(text, true);
        try r.beginCellPiece();
        try r.cell_buffer.append(r.gpa, '`');
        try r.appendCellBytes(text, true);
        try r.cell_buffer.append(r.gpa, '`');
    }

    fn appendCellPiece(
        r: *Renderer,
        text: []const u8,
        escape_pipe: bool,
    ) core.WriteError!void {
        if (text.len == 0) return;
        try r.beginCellPiece();
        try r.appendCellBytes(text, escape_pipe);
    }

    fn beginCellPiece(r: *Renderer) core.WriteError!void {
        if (r.cell_buffer.items.len > 0 and
            r.cell_buffer.items[r.cell_buffer.items.len - 1] != ' ')
        {
            try r.cell_buffer.append(r.gpa, ' ');
        }
    }

    fn appendCellBytes(
        r: *Renderer,
        text: []const u8,
        escape_pipe: bool,
    ) core.WriteError!void {
        const special = if (escape_pipe) "\n\r\t|" else "\n\r\t";
        if (std.mem.indexOfAny(u8, text, special) == null) {
            try r.cell_buffer.appendSlice(r.gpa, text);
            return;
        }
        var pending_space = false;
        for (text) |byte| switch (byte) {
            '\n', '\r', '\t' => pending_space = true,
            '|' => {
                if (pending_space) try r.appendCellSpace();
                pending_space = false;
                if (escape_pipe) try r.cell_buffer.append(r.gpa, '\\');
                try r.cell_buffer.append(r.gpa, '|');
            },
            else => {
                if (pending_space) try r.appendCellSpace();
                pending_space = false;
                try r.cell_buffer.append(r.gpa, byte);
            },
        };
    }

    fn appendCellSpace(r: *Renderer) core.WriteError!void {
        if (r.cell_buffer.items.len == 0 or
            r.cell_buffer.items[r.cell_buffer.items.len - 1] == ' ')
        {
            return;
        }
        try r.cell_buffer.append(r.gpa, ' ');
    }

    fn cellInlineContent(view: core.BlockView) ?ast.InlineRange {
        return switch (view.content) {
            .paragraph, .plain, .line, .definition_term => |inlines| inlines,
            .heading => |heading| heading.inlines,
            else => null,
        };
    }

    fn renderCaption(r: *Renderer, blocks: ast.BlockRange) core.WriteError!void {
        r.cell_buffer.clearRetainingCapacity();
        const lengths = r.doc.store.blocks.items(.subtree_len);
        var cursor = blocks.startRaw();
        while (cursor < blocks.endRaw()) {
            if (r.doc.blockTag(@enumFromInt(cursor)) == .table) {
                try r.appendCellPiece("(nested table)", false);
                try r.hit(.nested_table);
                cursor += lengths[cursor];
            } else {
                try r.appendCellBlock(cursor);
                cursor += 1;
            }
        }
        assert(cursor == blocks.endRaw());
        try r.writeLine(r.cell_buffer.items);
    }

    fn writeCaption(
        r: *Renderer,
        blocks: ast.BlockRange,
        after_table: bool,
    ) core.WriteError!void {
        if (after_table) try r.writeBlank();
        try r.hit(.table_caption);
        try r.renderCaption(blocks);
    }

    fn writeTableRow(
        r: *Renderer,
        rendered: *const TableBuffer,
        row_range: TableBuffer.Range,
        widths: []const usize,
    ) core.WriteError!void {
        const row = rendered.row(row_range);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(r.gpa);
        try line.append(r.gpa, '|');
        for (widths, 0..) |width, column| {
            try line.append(r.gpa, ' ');
            const cell = if (column < row.len) rendered.text(row[column]) else "";
            try line.appendSlice(r.gpa, cell);
            if (cell.len < width) try line.appendNTimes(r.gpa, ' ', width - cell.len);
            try line.appendSlice(r.gpa, " |");
        }
        try r.writeLine(std.mem.trimEnd(u8, line.items, " "));
    }

    fn writeSeparatorRow(
        r: *Renderer,
        alignments: []const core.payload.ColumnSpec,
        widths: []const usize,
    ) core.WriteError!void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(r.gpa);
        try line.append(r.gpa, '|');
        for (widths, 0..) |width, column| {
            const alignment: core.payload.Alignment = if (column < alignments.len)
                alignments[column].alignment
            else
                .default;
            try line.append(r.gpa, ' ');
            const dash_count = @max(width, 3);
            switch (alignment) {
                .default => try line.appendNTimes(r.gpa, '-', dash_count),
                .left => {
                    try line.append(r.gpa, ':');
                    try line.appendNTimes(r.gpa, '-', dash_count - 1);
                },
                .right => {
                    try line.appendNTimes(r.gpa, '-', dash_count - 1);
                    try line.append(r.gpa, ':');
                },
                .center => {
                    try line.append(r.gpa, ':');
                    try line.appendNTimes(r.gpa, '-', dash_count - 2);
                    try line.append(r.gpa, ':');
                },
            }
            try line.appendSlice(r.gpa, " |");
        }
        try r.writeLine(line.items);
    }

    // ------------------------------------------------------------- notes

    fn renderNotes(r: *Renderer) core.WriteError!void {
        assert(r.notes.items.len <= r.note_labels.len);
        var i: usize = 0;
        while (i < r.notes.items.len) : (i += 1) {
            const range = r.doc.store.block_ranges.items[r.notes.items[i]];
            var marker_buffer: [24]u8 = undefined;
            const marker = std.fmt.bufPrint(&marker_buffer, "[^{d}]: ", .{i + 1}) catch unreachable;
            // The forest's own root separation emits the blank line before
            // the definition.
            try r.renderForest(range, marker);
        }
        assert(i <= r.note_labels.len);
    }

    // ----------------------------------------------------------- inlines

    /// Renders an inline forest into the reused buffer and returns it. The
    /// result is valid until the next call.
    fn renderInlines(
        r: *Renderer,
        range: ast.InlineRange,
        mode: InlineMode,
    ) core.WriteError![]const u8 {
        r.inline_buffer.clearRetainingCapacity();
        const slice = r.doc.store.inlines.slice();
        const tags = slice.items(.tag);
        const lengths = slice.items(.subtree_len);
        const payloads = slice.items(.payload);
        const closes = r.inline_closes;
        var close_depth: u32 = 0;
        var cursor = range.startRaw();
        while (cursor < range.endRaw()) {
            while (close_depth > 0 and closes[close_depth - 1].end == cursor) {
                try inline_output.appendClose(r, closes[close_depth - 1]);
                close_depth -= 1;
            }
            const tag = tags[cursor];
            const subtree_len = lengths[cursor];
            const view = r.doc.inlineView(@enumFromInt(cursor));
            if (core.payload.inlineHasChildren(tag)) {
                const delimiters = try r.renderInlineContainer(view);
                try r.pushInlineClose(
                    closes,
                    &close_depth,
                    cursor + subtree_len,
                    delimiters,
                );
                cursor += 1;
            } else {
                try r.renderInlineLeaf(view, payloads[cursor], mode);
                cursor += subtree_len;
            }
        }
        while (close_depth > 0) {
            try inline_output.appendClose(r, closes[close_depth - 1]);
            close_depth -= 1;
        }
        return r.inline_buffer.items;
    }

    fn pushInlineClose(
        r: *Renderer,
        closes: []InlineClose,
        depth: *u32,
        end: u32,
        delimiters: InlineDelimiters,
    ) core.WriteError!void {
        assert(depth.* < r.limits.max_depth);
        const start: u32 = @intCast(r.inline_buffer.items.len);
        try r.inline_buffer.appendSlice(r.gpa, delimiters.open);
        closes[depth.*] = .{
            .end = end,
            .text = delimiters.close,
            .open_start = start,
            .styled = delimiters.styled,
        };
        depth.* += 1;
    }

    fn renderInlineLeaf(
        r: *Renderer,
        view: core.InlineView,
        payload_index: u32,
        mode: InlineMode,
    ) core.WriteError!void {
        switch (view.content) {
            .text => |text| try inline_output.escapeText(
                r,
                r.doc.text(text),
                mode == .table_cell,
            ),
            .space => try r.inline_buffer.append(r.gpa, ' '),
            .soft_break => try r.renderBreak(mode, false),
            .hard_break => try r.renderBreak(mode, true),
            .code => |text| try inline_output.renderCodeSpan(
                r,
                r.doc.text(text),
                mode == .table_cell,
            ),
            .math => |math| try r.renderMath(math),
            .raw => |raw| try r.renderRawInline(raw),
            .note => try r.renderNoteReference(payload_index),
            else => unreachable,
        }
    }

    fn renderBreak(r: *Renderer, mode: InlineMode, hard: bool) core.WriteError!void {
        switch (mode) {
            .multiline => if (hard)
                try r.inline_buffer.appendSlice(r.gpa, "\\\n")
            else
                try r.inline_buffer.append(r.gpa, '\n'),
            .single_line, .table_cell => try r.inline_buffer.append(r.gpa, ' '),
        }
    }

    fn renderMath(r: *Renderer, math: core.payload.Math) core.WriteError!void {
        const mark: []const u8 = switch (math.kind) {
            .inline_math => "$",
            .display => "$$",
        };
        try r.inline_buffer.appendSlice(r.gpa, mark);
        try r.inline_buffer.appendSlice(r.gpa, r.doc.text(math.text));
        try r.inline_buffer.appendSlice(r.gpa, mark);
    }

    fn renderRawInline(r: *Renderer, raw: core.payload.Raw) core.WriteError!void {
        const format = r.doc.text(raw.format);
        if (std.mem.eql(u8, format, "markdown") or
            std.mem.eql(u8, format, "html"))
        {
            try r.inline_buffer.appendSlice(r.gpa, r.doc.text(raw.text));
        } else {
            try r.hit(.raw_dropped);
        }
    }

    fn renderNoteReference(r: *Renderer, note: u32) core.WriteError!void {
        assert(note < r.note_labels.len);
        var label_index = r.note_labels[note];
        if (label_index == no_note) {
            assert(r.notes.items.len < r.note_labels.len);
            label_index = @intCast(r.notes.items.len);
            try r.notes.append(r.gpa, note);
            r.note_labels[note] = label_index;
        }
        var label: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&label, "[^{d}]", .{label_index + 1}) catch unreachable;
        try r.inline_buffer.appendSlice(r.gpa, text);
    }

    fn renderInlineContainer(
        r: *Renderer,
        view: core.InlineView,
    ) core.WriteError!InlineDelimiters {
        return switch (view.content) {
            .emphasis => .{ .open = "_", .close = "_", .styled = true },
            .strong => .{ .open = "**", .close = "**", .styled = true },
            .strikethrough => .{ .open = "~~", .close = "~~", .styled = true },
            .superscript, .subscript, .underline, .small_caps => value: {
                try r.hit(.style_dropped);
                break :value .{};
            },
            .span => .{},
            .extension => value: {
                try r.hit(.extension_fallback);
                break :value .{};
            },
            .quote => |quote| quote: {
                const mark: []const u8 = if (quote.kind == .single) "'" else "\"";
                break :quote .{ .open = mark, .close = mark };
            },
            .link => |target| .{
                .open = "[",
                .close = try inline_output.linkSuffix(
                    r,
                    r.doc.text(target.url),
                    r.doc.text(target.title),
                ),
            },
            .image => |target| .{
                .open = "![",
                .close = try inline_output.linkSuffix(
                    r,
                    r.doc.text(target.url),
                    r.doc.text(target.title),
                ),
            },
            .citation => value: {
                try r.hit(.citation_dropped);
                break :value .{};
            },
            else => unreachable,
        };
    }

    fn reportContainerAttrs(r: *Renderer, index: u32) core.WriteError!void {
        const view = r.doc.block(@enumFromInt(index));
        if (view.attrs == .none) return;
        try r.hit(.container_attrs);
    }

    fn reportDefinitionList(r: *Renderer) core.WriteError!void {
        try r.hit(.definition_list);
    }
};

// The capability declaration and rule table (ZDS 0013) live in
// `capabilities.zig`; the report constructors in `writer_reports.zig`;
// tests in `writer_test.zig`.
const capabilities_mod = @import("capabilities.zig");
