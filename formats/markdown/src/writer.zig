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

pub const writer = core.Writer(.{
    .id = "ai.insan.zenfmt.markdown",
    .format = "markdown",
    .extensions = &.{ "md", "markdown" },
    .write = write,
    .capabilities = &capabilities_mod.capabilities,
});

pub fn write(ctx: *core.WriteContext) core.WriteError!void {
    var renderer: Renderer = .{
        .gpa = ctx.gpa,
        .doc = ctx.doc,
        .out = ctx.out,
        .reports = ctx.reports,
        .limits = ctx.limits,
        .plan = ctx.plan,
    };
    defer renderer.deinit();
    try renderer.renderForest(ctx.doc.body, null);
    try renderer.renderNotes();
}

const InlineMode = enum { multiline, single_line, table_cell };

const FrameKind = enum {
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

const Frame = struct {
    kind: FrameKind,
    end: u32,
    prefix_restore: u32,
    emitted_child: bool = false,
    /// List bookkeeping; meaningful only for `.list`.
    tight: bool = false,
    ordered: bool = false,
    next_number: i64 = 1,
    delimiter: core.payload.NumberDelimiter = .period,
};

const Renderer = struct {
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
    /// Note payload rows in order of first reference; index+1 is the label.
    notes: std.ArrayList(ast.BlockRange) = .empty,
    frames: [core.limits.max_depth_hard_cap]Frame = undefined,
    depth: u32 = 0,
    emitted_root: bool = false,

    fn deinit(r: *Renderer) void {
        r.prefix.deinit(r.gpa);
        r.inline_buffer.deinit(r.gpa);
        r.cell_buffer.deinit(r.gpa);
        r.notes.deinit(r.gpa);
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
    fn renderForest(r: *Renderer, range: ast.BlockRange, initial_marker: ?[]const u8) core.WriteError!void {
        assert(r.depth == 0);
        if (initial_marker) |marker| {
            try r.prefix.appendNTimes(r.gpa, ' ', marker.len);
            try r.setPendingMarker(marker);
        }
        const prefix_base = if (initial_marker) |m| r.prefix.items.len - m.len else r.prefix.items.len;

        const slice = r.doc.store.blocks.slice();
        const tags = slice.items(.tag);
        const lengths = slice.items(.subtree_len);

        var cursor = range.startRaw();
        const end = range.endRaw();
        while (cursor < end) {
            while (r.depth > 0 and r.frames[r.depth - 1].end == cursor) {
                r.prefix.shrinkRetainingCapacity(r.frames[r.depth - 1].prefix_restore);
                r.depth -= 1;
            }
            try r.separate();

            const tag = tags[cursor];
            const subtree_len = lengths[cursor];
            switch (tag) {
                .paragraph, .plain => {
                    const view = r.doc.block(@enumFromInt(cursor));
                    const inlines = switch (view.content) {
                        .paragraph, .plain => |value| value,
                        else => unreachable,
                    };
                    const buffer = try r.renderInlines(inlines, .multiline);
                    try r.writeBufferLines(buffer);
                    cursor += 1;
                },
                .heading => try r.renderHeading(cursor, &cursor),
                .code_block => try r.renderCodeBlock(cursor, &cursor),
                .raw_block => try r.renderRawBlock(cursor, &cursor),
                .thematic_break => {
                    try r.writeLine("---");
                    cursor += 1;
                },
                .line_block => {
                    try r.renderLineBlock(cursor);
                    cursor += subtree_len;
                },
                .table => {
                    try r.renderTable(cursor);
                    cursor += subtree_len;
                },
                .definition_term => {
                    const term = r.doc.blockAs(@enumFromInt(cursor), .definition_term).?;
                    const buffer = try r.renderInlines(term, .single_line);
                    const bold = try std.fmt.allocPrint(r.gpa, "**{s}**", .{buffer});
                    defer r.gpa.free(bold);
                    try r.writeLine(bold);
                    cursor += 1;
                },
                .quote => {
                    try r.push(.quote, cursor + subtree_len);
                    try r.prefix.appendSlice(r.gpa, "> ");
                    cursor += 1;
                },
                .container => {
                    try r.reportContainerAttrs(cursor);
                    try r.push(.container, cursor + subtree_len);
                    cursor += 1;
                },
                .extension => {
                    // Markdown declares no extension namespaces: the
                    // source-neutral fallback subtree renders and the
                    // extension identity is reported as a loss.
                    try r.hit(.extension_fallback);
                    try r.push(.extension, cursor + subtree_len);
                    cursor += 1;
                },
                .figure => {
                    try r.push(.figure, cursor + subtree_len);
                    cursor += 1;
                },
                .caption => {
                    try r.push(.caption, cursor + subtree_len);
                    cursor += 1;
                },
                .definition_list => {
                    try r.reportDefinitionList();
                    try r.push(.definition_list, cursor + subtree_len);
                    cursor += 1;
                },
                .definition_entry => {
                    try r.push(.definition_entry, cursor + subtree_len);
                    cursor += 1;
                },
                .definition_body => {
                    try r.push(.definition_body, cursor + subtree_len);
                    cursor += 1;
                },
                .list => {
                    try r.pushList(cursor);
                    cursor += 1;
                },
                .list_item => {
                    try r.pushListItem(cursor);
                    cursor += 1;
                },
                // Table structure is consumed by `renderTable`; the walker
                // skips the whole subtree, so these never surface here, and
                // the validator guarantees their placement.
                .line, .table_head, .table_body, .table_foot, .table_row, .table_cell => unreachable,
            }
        }
        while (r.depth > 0) {
            r.prefix.shrinkRetainingCapacity(r.frames[r.depth - 1].prefix_restore);
            r.depth -= 1;
        }
        assert(r.pending_marker == null or range.len == 0);
        r.pending_marker = null;
        r.prefix.shrinkRetainingCapacity(prefix_base);
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
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.doc.text(raw.text), "\n"), '\n');
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
        const alignments = r.doc.store.columns.items[table.columns.start .. table.columns.start + table.columns.len];

        // Collect the rendered text of every cell, rows in order.
        var rows: std.ArrayList([]const []const u8) = .empty;
        defer {
            for (rows.items) |row| {
                for (row) |cell| r.gpa.free(cell);
                r.gpa.free(row);
            }
            rows.deinit(r.gpa);
        }
        var caption: ?ast.BlockRange = null;
        var spans_noted = false;

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
                        try rows.append(r.gpa, try r.renderRow(row, &spans_noted));
                    }
                },
                else => unreachable,
            }
        }
        if (rows.items.len == 0) return;

        var column_count: usize = alignments.len;
        for (rows.items) |row| column_count = @max(column_count, row.len);
        assert(column_count > 0);

        // Common column widths, capped so one long cell does not pad the
        // whole document.
        const widths = try r.gpa.alloc(usize, column_count);
        defer r.gpa.free(widths);
        for (widths, 0..) |*width, column| {
            width.* = 3;
            for (rows.items) |row| {
                if (column < row.len) width.* = @max(width.*, row[column].len);
            }
            width.* = @min(width.*, max_column_pad);
        }

        try r.writeTableRow(rows.items[0], widths);
        try r.writeSeparatorRow(alignments, widths);
        for (rows.items[1..]) |row| try r.writeTableRow(row, widths);

        if (caption) |blocks| {
            try r.writeBlank();
            var walked: u32 = blocks.startRaw();
            const lengths = r.doc.store.blocks.items(.subtree_len);
            var first = true;
            while (walked < blocks.endRaw()) {
                if (!first) try r.writeBlank();
                first = false;
                try r.renderFlattenedBlock(walked, &spans_noted);
                walked += lengths[walked];
            }
        }
    }

    fn renderRow(r: *Renderer, row: ast.BlockIndex, spans_noted: *bool) core.WriteError![]const []const u8 {
        var cells: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (cells.items) |cell| r.gpa.free(cell);
            cells.deinit(r.gpa);
        }
        var children = r.doc.blockChildren(row);
        while (children.next()) |cell_index| {
            const cell = r.doc.blockAs(cell_index, .table_cell).?;
            if ((cell.col_span > 1 or cell.row_span > 1) and !spans_noted.*) {
                spans_noted.* = true;
                try r.hit(.cell_span);
            }
            try cells.append(r.gpa, try r.renderCellText(cell.blocks));
            var extra: u32 = 1;
            while (extra < cell.col_span) : (extra += 1) {
                try cells.append(r.gpa, try r.gpa.dupe(u8, ""));
            }
        }
        return cells.toOwnedSlice(r.gpa);
    }

    /// A GFM cell is one line of inline text. Multiple blocks, or any block
    /// that is not a paragraph, are flattened with a note; a nested table
    /// becomes a placeholder and a warning.
    fn renderCellText(r: *Renderer, blocks: ast.BlockRange) core.WriteError![]const u8 {
        r.cell_buffer.clearRetainingCapacity();
        const lengths = r.doc.store.blocks.items(.subtree_len);
        const tags = r.doc.store.blocks.items(.tag);

        var flattened = false;
        var block_count: u32 = 0;
        var cursor = blocks.startRaw();
        while (cursor < blocks.endRaw()) {
            const tag = tags[cursor];
            block_count += 1;
            if (block_count > 1) try r.cell_buffer.appendSlice(r.gpa, " ");
            switch (tag) {
                .paragraph, .plain => {
                    const view = r.doc.block(@enumFromInt(cursor));
                    const inlines = switch (view.content) {
                        .paragraph, .plain => |value| value,
                        else => unreachable,
                    };
                    const rendered = try r.renderInlines(inlines, .table_cell);
                    try r.cell_buffer.appendSlice(r.gpa, rendered);
                    if (tag == .paragraph and block_count > 1) flattened = true;
                },
                .table => {
                    try r.cell_buffer.appendSlice(r.gpa, "(nested table)");
                    try r.hit(.nested_table);
                    flattened = true;
                },
                else => {
                    // Non-paragraph structure: keep its inline text only.
                    const view = r.doc.block(@enumFromInt(cursor));
                    switch (view.content) {
                        .code_block => |text_range| {
                            try r.cell_buffer.append(r.gpa, '`');
                            try r.cell_buffer.appendSlice(r.gpa, r.doc.text(text_range));
                            try r.cell_buffer.append(r.gpa, '`');
                        },
                        .heading => |heading| {
                            const rendered = try r.renderInlines(heading.inlines, .table_cell);
                            try r.cell_buffer.appendSlice(r.gpa, rendered);
                        },
                        else => {},
                    }
                    flattened = true;
                },
            }
            cursor += lengths[cursor];
        }
        if (block_count > 1 or flattened) {
            try r.hit(.cell_flattened);
        }
        // A cell is one line: any soft break became a space in table_cell
        // mode already.
        assert(std.mem.indexOfScalar(u8, r.cell_buffer.items, '\n') == null);
        return r.gpa.dupe(u8, r.cell_buffer.items);
    }

    fn renderFlattenedBlock(r: *Renderer, index: u32, spans_noted: *bool) core.WriteError!void {
        _ = spans_noted;
        const view = r.doc.block(@enumFromInt(index));
        switch (view.content) {
            .paragraph, .plain => |inlines| {
                const buffer = try r.renderInlines(inlines, .multiline);
                try r.writeBufferLines(buffer);
            },
            else => {},
        }
    }

    fn writeTableRow(r: *Renderer, row: []const []const u8, widths: []const usize) core.WriteError!void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(r.gpa);
        try line.append(r.gpa, '|');
        for (widths, 0..) |width, column| {
            try line.append(r.gpa, ' ');
            const cell = if (column < row.len) row[column] else "";
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
        var i: usize = 0;
        while (i < r.notes.items.len) : (i += 1) {
            const range = r.notes.items[i];
            var marker_buffer: [24]u8 = undefined;
            const marker = std.fmt.bufPrint(&marker_buffer, "[^{d}]: ", .{i + 1}) catch unreachable;
            // The forest's own root separation emits the blank line before
            // the definition.
            try r.renderForest(range, marker);
        }
    }

    // ----------------------------------------------------------- inlines

    /// Renders an inline forest into the reused buffer and returns it. The
    /// result is valid until the next call.
    fn renderInlines(r: *Renderer, range: ast.InlineRange, mode: InlineMode) core.WriteError![]const u8 {
        r.inline_buffer.clearRetainingCapacity();

        const slice = r.doc.store.inlines.slice();
        const tags = slice.items(.tag);
        const lengths = slice.items(.subtree_len);

        const Close = struct {
            end: u32,
            text: []const u8,
            /// For emphasis-like pairs: where the opening delimiter began,
            /// so edge spaces can move outside it — `** not**` does not
            /// parse as strong, `**not**` does.
            open_start: u32 = 0,
            styled: bool = false,
        };
        var closes: [core.limits.max_depth_hard_cap]Close = undefined;
        var close_depth: u32 = 0;

        var cursor = range.startRaw();
        const end = range.endRaw();
        while (cursor < end) {
            while (close_depth > 0 and closes[close_depth - 1].end == cursor) {
                try r.appendClose(closes[close_depth - 1]);
                close_depth -= 1;
            }
            const tag = tags[cursor];
            const subtree_len = lengths[cursor];
            const view = r.doc.inlineView(@enumFromInt(cursor));

            var open_text: ?[]const u8 = null;
            var close_text: ?[]const u8 = null;
            switch (view.content) {
                .text => |text_range| try r.escapeText(r.doc.text(text_range), mode),
                .space => try r.inline_buffer.append(r.gpa, ' '),
                .soft_break => switch (mode) {
                    .multiline => try r.inline_buffer.append(r.gpa, '\n'),
                    .single_line, .table_cell => try r.inline_buffer.append(r.gpa, ' '),
                },
                .hard_break => switch (mode) {
                    .multiline => try r.inline_buffer.appendSlice(r.gpa, "\\\n"),
                    .single_line, .table_cell => try r.inline_buffer.append(r.gpa, ' '),
                },
                .emphasis => {
                    open_text = "_";
                    close_text = "_";
                },
                .strong => {
                    open_text = "**";
                    close_text = "**";
                },
                .strikethrough => {
                    open_text = "~~";
                    close_text = "~~";
                },
                .superscript, .subscript, .underline, .small_caps => {
                    try r.hit(.style_dropped);
                },
                .span => {},
                .extension => try r.hit(.extension_fallback),
                .quote => |quote| {
                    const mark: []const u8 = switch (quote.kind) {
                        .single => "'",
                        .double => "\"",
                    };
                    open_text = mark;
                    close_text = mark;
                },
                .code => |text_range| try r.renderCodeSpan(r.doc.text(text_range), mode),
                .math => |math| {
                    const mark: []const u8 = switch (math.kind) {
                        .inline_math => "$",
                        .display => "$$",
                    };
                    try r.inline_buffer.appendSlice(r.gpa, mark);
                    try r.inline_buffer.appendSlice(r.gpa, r.doc.text(math.text));
                    try r.inline_buffer.appendSlice(r.gpa, mark);
                },
                .raw => |raw| {
                    const format = r.doc.text(raw.format);
                    if (std.mem.eql(u8, format, "markdown") or std.mem.eql(u8, format, "html")) {
                        try r.inline_buffer.appendSlice(r.gpa, r.doc.text(raw.text));
                    } else {
                        try r.hit(.raw_dropped);
                    }
                },
                .link => |target| {
                    open_text = "[";
                    close_text = try r.linkSuffix(target.url, target.title);
                },
                .image => |target| {
                    open_text = "![";
                    close_text = try r.linkSuffix(target.url, target.title);
                },
                .note => |blocks| {
                    try r.notes.append(r.gpa, blocks);
                    var label: [24]u8 = undefined;
                    const text = std.fmt.bufPrint(&label, "[^{d}]", .{r.notes.items.len}) catch unreachable;
                    try r.inline_buffer.appendSlice(r.gpa, text);
                },
                .citation => |citation| {
                    _ = citation;
                    try r.hit(.citation_dropped);
                },
            }

            if (core.payload.inlineHasChildren(tag)) {
                const open_start: u32 = @intCast(r.inline_buffer.items.len);
                if (open_text) |text| try r.inline_buffer.appendSlice(r.gpa, text);
                assert(close_depth < r.limits.max_depth);
                const styled = switch (view.content) {
                    .emphasis, .strong, .strikethrough => true,
                    else => false,
                };
                closes[close_depth] = .{
                    .end = cursor + subtree_len,
                    .text = close_text orelse "",
                    .open_start = open_start,
                    .styled = styled,
                };
                close_depth += 1;
                cursor += 1;
            } else {
                cursor += subtree_len;
            }
        }
        while (close_depth > 0) {
            try r.appendClose(closes[close_depth - 1]);
            close_depth -= 1;
        }
        return r.inline_buffer.items;
    }

    /// Emits a closing delimiter. For emphasis-like pairs, edge spaces
    /// move outside the delimiters — `**not **` does not parse as strong —
    /// and a pair left empty disappears entirely.
    fn appendClose(r: *Renderer, close: anytype) core.WriteError!void {
        if (!close.styled) {
            try r.inline_buffer.appendSlice(r.gpa, close.text);
            return;
        }
        const buffer = &r.inline_buffer;
        // Styled pairs use the same text on both sides: `_`, `**`, `~~`.
        const delim_len = close.text.len;
        assert(delim_len <= 2);
        assert(close.open_start + delim_len <= buffer.items.len);

        // Trailing spaces slide out past the closing delimiter.
        var trailing: usize = 0;
        while (buffer.items.len - trailing > close.open_start + delim_len and
            buffer.items[buffer.items.len - trailing - 1] == ' ')
        {
            trailing += 1;
        }
        buffer.items.len -= trailing;

        // Leading spaces swap with the opening delimiter.
        var leading: usize = 0;
        while (close.open_start + delim_len + leading < buffer.items.len and
            buffer.items[close.open_start + delim_len + leading] == ' ')
        {
            leading += 1;
        }
        if (leading > 0) {
            var delimiter: [2]u8 = undefined;
            @memcpy(delimiter[0..delim_len], buffer.items[close.open_start..][0..delim_len]);
            @memset(buffer.items[close.open_start..][0..leading], ' ');
            @memcpy(buffer.items[close.open_start + leading ..][0..delim_len], delimiter[0..delim_len]);
        }

        const content_start = close.open_start + leading + delim_len;
        if (buffer.items.len == content_start) {
            // Nothing left inside: the pair disappears, its spaces stay.
            buffer.items.len = close.open_start + leading;
        } else {
            try buffer.appendSlice(r.gpa, close.text);
        }
        try buffer.appendNTimes(r.gpa, ' ', trailing);
    }

    /// `](url "title")`, with the URL wrapped in angle brackets only when
    /// it needs them.
    fn linkSuffix(r: *Renderer, url_range: ast.ByteRange, title_range: ast.ByteRange) core.WriteError![]const u8 {
        const url = r.doc.text(url_range);
        const title = r.doc.text(title_range);
        var suffix: std.ArrayList(u8) = .empty;
        defer suffix.deinit(r.gpa);
        try suffix.appendSlice(r.gpa, "](");
        const needs_brackets = std.mem.indexOfAny(u8, url, " <>\n") != null;
        if (needs_brackets) try suffix.append(r.gpa, '<');
        for (url) |byte| {
            if (!needs_brackets and (byte == '(' or byte == ')')) {
                try suffix.append(r.gpa, '\\');
            }
            try suffix.append(r.gpa, byte);
        }
        if (needs_brackets) try suffix.append(r.gpa, '>');
        if (title.len > 0) {
            try suffix.appendSlice(r.gpa, " \"");
            for (title) |byte| {
                if (byte == '"') try suffix.append(r.gpa, '\\');
                try suffix.append(r.gpa, byte);
            }
            try suffix.append(r.gpa, '"');
        }
        try suffix.append(r.gpa, ')');
        return suffix.toOwnedSlice(r.gpa);
    }

    fn renderCodeSpan(r: *Renderer, text: []const u8, mode: InlineMode) core.WriteError!void {
        const fence_len = longestRun(text, '`') + 1;
        const pad = text.len == 0 or text[0] == '`' or text[text.len - 1] == '`' or
            text[0] == ' ' or text[text.len - 1] == ' ';
        try r.inline_buffer.appendNTimes(r.gpa, '`', fence_len);
        if (pad) try r.inline_buffer.append(r.gpa, ' ');
        for (text) |byte| {
            if (mode == .table_cell and byte == '|') {
                try r.inline_buffer.appendSlice(r.gpa, "\\|");
            } else {
                try r.inline_buffer.append(r.gpa, byte);
            }
        }
        if (pad) try r.inline_buffer.append(r.gpa, ' ');
        try r.inline_buffer.appendNTimes(r.gpa, '`', fence_len);
    }

    /// The minimum escaping that preserves meaning at this position.
    fn escapeText(r: *Renderer, text: []const u8, mode: InlineMode) core.WriteError!void {
        for (text, 0..) |byte, i| {
            const at_line_start = r.inline_buffer.items.len == 0 or
                r.inline_buffer.items[r.inline_buffer.items.len - 1] == '\n';
            const escape = switch (byte) {
                '\\', '`', '*', '[', ']' => true,
                '_' => atWordBoundary(text, i),
                '#', '>', '+', '-' => at_line_start,
                '.', ')' => at_line_start_number: {
                    // "1." or "1)" at a line start opens an ordered list.
                    break :at_line_start_number startsOrderedList(r.inline_buffer.items, text, i);
                },
                '!' => i + 1 < text.len and text[i + 1] == '[',
                '|' => mode == .table_cell,
                '<' => true,
                '&' => looksLikeEntity(text[i..]),
                else => false,
            };
            if (escape) try r.inline_buffer.append(r.gpa, '\\');
            try r.inline_buffer.append(r.gpa, byte);
        }
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

fn atWordBoundary(text: []const u8, i: usize) bool {
    const before_ok = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
    const after_ok = i + 1 >= text.len or !std.ascii.isAlphanumeric(text[i + 1]);
    return before_ok or after_ok;
}

fn startsOrderedList(buffer: []const u8, text: []const u8, i: usize) bool {
    // The characters before position i on this line must all be digits,
    // with at least one, in this text run and back through the buffer.
    if (i == 0) return false;
    var j = i;
    var digits: usize = 0;
    while (j > 0 and std.ascii.isDigit(text[j - 1])) {
        j -= 1;
        digits += 1;
    }
    if (digits == 0 or j != 0) return false;
    // The run must begin the output line.
    return buffer.len == 0 or buffer[buffer.len - 1] == '\n';
}

fn looksLikeEntity(rest: []const u8) bool {
    assert(rest.len > 0 and rest[0] == '&');
    var i: usize = 1;
    if (i < rest.len and rest[i] == '#') i += 1;
    const start = i;
    while (i < rest.len and std.ascii.isAlphanumeric(rest[i])) i += 1;
    return i > start and i < rest.len and rest[i] == ';';
}

fn longestRun(text: []const u8, byte: u8) usize {
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

// The capability declaration and rule table (ZDS 0013) live in
// `capabilities.zig`; the report constructors in `writer_reports.zig`;
// tests in `writer_test.zig`.
const capabilities_mod = @import("capabilities.zig");
