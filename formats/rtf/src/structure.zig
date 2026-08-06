//! RTF paragraph structure: tables, lists, headings, and field results.
//!
//! RTF has no block tree — tables are `\cell`/`\row` terminators trailing
//! their content, lists are per-paragraph numbering properties, headings
//! are `\outlinelevel` hints. These functions synthesize the zenfmt block
//! structure from that vocabulary, operating on the reader's `Parser`.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const reader_mod = @import("reader.zig");
const reports_mod = @import("reports.zig");

const Parser = reader_mod.Parser;

/// Opens everything the next piece of paragraph content needs, outermost
/// first: table cell, list item, then the paragraph or heading block.
pub fn ensureParagraph(p: *Parser) core.ReadError!void {
    if (p.paragraph != null) return;

    if (p.para.in_table) {
        try ensureCell(p);
    } else if (p.table.token != null) {
        try closeTable(p);
    }

    if (p.para.outline == null and p.para.list) {
        try enterListItem(p);
    } else {
        try closeLists(p, listBase(p));
    }

    const token = if (p.para.outline) |outline|
        try p.ctx.out.beginHeading(@min(outline + 1, 6))
    else
        try p.ctx.out.beginParagraph();
    p.paragraph = token;
    p.open_style = .{};
    p.style_count = 0;
}

/// `\cell`: the cell's content (which opened it lazily) is complete.
pub fn onCell(p: *Parser) core.ReadError!void {
    // An empty cell never emitted text, so open its structure now.
    p.para.in_table = true;
    try ensureCell(p);
    try p.closeParagraph();
    try closeLists(p, p.cell_list_base);
    if (p.table.cell) |token| p.ctx.out.endBlock(token);
    p.table.cell = null;
}

/// `\row`: the row is complete.
pub fn onRow(p: *Parser) core.ReadError!void {
    if (p.table.token == null) return;
    if (p.table.cell != null) try onCell(p);
    if (p.table.row) |token| p.ctx.out.endBlock(token);
    p.table.row = null;
    p.row_header = false;
}

/// `{\fldrslt`: the field's display text follows; open a link when the
/// collected instruction was a `HYPERLINK`.
pub fn onFieldResult(p: *Parser) core.ReadError!void {
    if (p.field_depth == null) return;
    const url = parseHyperlinkInstruction(p.ctx.gpa, p.instr_buffer.items) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoMatch => return,
        };
    try ensureParagraph(p);
    p.closeAllStyles();
    p.field_link = try p.ctx.out.beginLink(url, "");
}

/// Closes any open cell, row, and the table itself.
pub fn closeTable(p: *Parser) core.ReadError!void {
    if (p.table.token == null) return;
    if (p.table.cell != null) try onCell(p);
    if (p.table.row != null) try onRow(p);
    if (p.table.head) |token| p.ctx.out.endBlock(token);
    if (p.table.body) |token| p.ctx.out.endBlock(token);
    if (p.table.token) |token| p.ctx.out.endBlock(token);
    p.table = .{};
}

/// End-of-input: close the table and any open lists.
pub fn closeAll(p: *Parser) core.ReadError!void {
    try closeTable(p);
    try closeLists(p, 0);
}

fn ensureCell(p: *Parser) core.ReadError!void {
    if (p.table.token == null) try openTable(p);
    if (p.table.row == null) try openRow(p);
    if (p.table.cell == null) {
        p.table.cell = try p.ctx.out.beginTableCell(.{
            .alignment = .default,
            .row_span = 1,
            .col_span = 1,
        });
        p.cell_list_base = p.list_depth;
    }
    if (p.para.nested_table and !p.nested_table_noted) {
        p.nested_table_noted = true;
        try p.ctx.reports.add(reports_mod.nestedTableNote());
    }
}

fn openTable(p: *Parser) core.ReadError!void {
    assert(p.table.token == null);
    try closeLists(p, 0);
    const columns = @max(p.row_def_cells, 1);
    var alignments: std.ArrayList(core.payload.Alignment) = .empty;
    defer alignments.deinit(p.ctx.gpa);
    try alignments.appendNTimes(p.ctx.gpa, .default, columns);
    p.table.token = try p.ctx.out.beginTable(alignments.items);
}

fn openRow(p: *Parser) core.ReadError!void {
    assert(p.table.token != null);
    assert(p.table.row == null);
    if (p.row_header and p.table.body == null) {
        if (p.table.head == null) {
            p.table.head = try p.ctx.out.beginBlock(.table_head);
        }
    } else {
        if (p.table.head) |token| {
            p.ctx.out.endBlock(token);
            p.table.head = null;
        }
        if (p.table.body == null) {
            p.table.body = try p.ctx.out.beginTableBody(.{
                .row_head_columns = 0,
                .head_rows = 0,
            });
        }
    }
    p.table.row = try p.ctx.out.beginBlock(.table_row);
}

// ---------------------------------------------------------------- lists

fn listBase(p: *Parser) u32 {
    return if (p.table.cell != null) p.cell_list_base else 0;
}

/// The same inference machine as the DOCX reader, with the list kind in
/// place of a numbering identity: open on rising `\ilvl`, close on falling
/// `\ilvl` or a changed kind, open intervening levels as empty items.
fn enterListItem(p: *Parser) core.ReadError!void {
    const base = listBase(p);
    const level = p.para.ilvl;
    const ordered = resolvedKind(p) == .ordered;

    while (p.list_depth > base) {
        const current = &p.lists[p.list_depth - 1];
        const current_relative = p.list_depth - base - 1;
        if (current_relative > level) {
            closeOneList(p);
        } else if (current_relative == @as(u32, level) and current.ordered != ordered) {
            closeOneList(p);
            break;
        } else {
            break;
        }
    }

    while (p.list_depth - base <= level) {
        const relative: u8 = @intCast(p.list_depth - base);
        const target = relative == level;
        const list_token = try p.ctx.out.beginList(.{
            .kind = if (target and ordered) .ordered else .unordered,
            .start = 1,
            .style = .decimal,
            .delimiter = .period,
        });
        assert(p.list_depth < p.lists.len);
        p.lists[p.list_depth] = .{
            .level = relative,
            .ordered = if (target) ordered else false,
            .list_token = list_token,
            .item_token = null,
        };
        p.list_depth += 1;
        if (!target) {
            // An intervening level: it holds only the deeper list.
            p.lists[p.list_depth - 1].item_token = try p.ctx.out.beginBlock(.list_item);
        }
    }

    const top = &p.lists[p.list_depth - 1];
    if (top.item_token) |token| p.ctx.out.endBlock(token);
    top.item_token = try p.ctx.out.beginBlock(.list_item);
}

/// `{\*\pn}` says the kind outright; `\ls` alone does not, so the marker
/// fallback text decides — a digit means numbers, anything else a bullet.
fn resolvedKind(p: *Parser) reader_mod.ParaProps.ListKind {
    if (p.para.list_kind != .unknown) return p.para.list_kind;
    const marker = std.mem.trim(u8, p.marker_buffer.items, " \t");
    if (marker.len > 0 and std.ascii.isDigit(marker[0])) return .ordered;
    return .bullet;
}

fn closeOneList(p: *Parser) void {
    assert(p.list_depth > 0);
    const level = &p.lists[p.list_depth - 1];
    if (level.item_token) |token| p.ctx.out.endBlock(token);
    p.ctx.out.endBlock(level.list_token);
    p.list_depth -= 1;
}

pub fn closeLists(p: *Parser, base: u32) core.ReadError!void {
    while (p.list_depth > base) closeOneList(p);
}

// ---------------------------------------------------------------- fields

/// `HYPERLINK "url"` or `HYPERLINK url`, ignoring trailing switches. The
/// same rules as the DOCX field parser, locally owned: format libraries
/// do not import each other.
fn parseHyperlinkInstruction(
    arena: std.mem.Allocator,
    instruction: []const u8,
) error{ OutOfMemory, NoMatch }![]const u8 {
    const trimmed = std.mem.trim(u8, instruction, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "HYPERLINK")) return error.NoMatch;
    var rest = std.mem.trimStart(u8, trimmed["HYPERLINK".len..], " \t");
    if (rest.len == 0) return error.NoMatch;
    if (rest[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.NoMatch;
        return arena.dupe(u8, rest[1..close]);
    }
    const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    return arena.dupe(u8, rest[0..end]);
}
