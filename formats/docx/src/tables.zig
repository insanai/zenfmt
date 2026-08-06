//! DOCX table handlers, split out of `reader.zig` (file-size rule).
//!
//! Free functions over the reader's `Machine`: `w:tbl` opens a table after
//! counting `tblGrid` columns, `w:tr` routes leading header rows into
//! `table_head`, and `w:tc` folds `gridSpan`/`vMerge` cells with a single
//! `MERGED CELLS` note per table.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const xml = @import("zenfmt_xml");
const reader_mod = @import("reader.zig");
const util = @import("util.zig");
const reports_mod = @import("reports.zig");

const Machine = reader_mod.Machine;
const w_ns = reader_mod.w_ns;
const stringAttribute = util.stringAttribute;
const toggleValue = util.toggleValue;
const mergedCellNote = reports_mod.mergedCellNote;

pub fn onTableStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
    if (element.self_closing) return;
    try m.closeLists(m.contextListBase());

    // `tblPr` and `tblGrid` precede the rows; count the columns before
    // opening the table.
    var columns: u32 = 0;
    while (true) {
        const event = try m.next();
        switch (event) {
            .done => return,
            .element_start => |child| {
                if (child.name.is(w_ns, "tblPr")) {
                    if (!child.self_closing) try m.skipCurrent();
                } else if (child.name.is(w_ns, "tblGrid")) {
                    if (!child.self_closing) {
                        const grid_depth = m.parser.depth;
                        while (m.parser.depth >= grid_depth) {
                            const grid_event = try m.next();
                            switch (grid_event) {
                                .done => return,
                                .element_start => |grid_child| {
                                    if (grid_child.name.is(w_ns, "gridCol")) columns += 1;
                                    if (!grid_child.self_closing) try m.skipCurrent();
                                },
                                else => {},
                            }
                        }
                    }
                } else {
                    m.pending = event;
                    break;
                }
            },
            .element_end => {
                // The table ended before any row: an empty table.
                m.pending = event;
                break;
            },
            .text => {},
        }
    }

    var alignments: std.ArrayList(core.payload.Alignment) = .empty;
    defer alignments.deinit(m.arena);
    try alignments.appendNTimes(m.arena, .default, @max(columns, 1));
    const token = try m.ctx.out.beginTable(alignments.items);

    assert(m.table_depth < m.tables.len);
    m.tables[m.table_depth] = .{ .columns = columns };
    try m.push(.{
        .kind = .table,
        .block_token = token,
        .table_index = m.table_depth,
    });
    m.table_depth += 1;
}

pub fn onRowStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
    if (element.self_closing) return;
    const frame = m.top() orelse return m.push(.{ .kind = .transparent });
    if (frame.kind != .table) return m.push(.{ .kind = .transparent });
    const table = &m.tables[frame.table_index];

    // A leading header row goes under `table_head`; anything after the
    // body opens stays in the body.
    var is_header = false;
    const first = try m.next();
    if (first == .element_start and first.element_start.name.is(w_ns, "trPr")) {
        if (!first.element_start.self_closing) {
            const pr_depth = m.parser.depth;
            while (m.parser.depth >= pr_depth) {
                const pr_event = try m.next();
                switch (pr_event) {
                    .done => return,
                    .element_start => |child| {
                        if (child.name.is(w_ns, "tblHeader")) {
                            is_header = toggleValue(child.attributes);
                        }
                    },
                    else => {},
                }
            }
        }
    } else {
        m.pending = first;
    }

    if (is_header and table.body_token == null) {
        if (table.head_token == null) {
            table.head_token = try m.ctx.out.beginBlock(.table_head);
        }
    } else {
        if (table.head_token) |token| {
            m.ctx.out.endBlock(token);
            table.head_token = null;
        }
        if (table.body_token == null) {
            table.body_token = try m.ctx.out.beginTableBody(.{
                .row_head_columns = 0,
                .head_rows = 0,
            });
        }
    }
    const token = try m.ctx.out.beginBlock(.table_row);
    try m.push(.{ .kind = .table_row, .block_token = token });
}

pub fn onCellStart(m: *Machine, element: xml.ElementStart) core.ReadError!void {
    if (element.self_closing) return;
    const frame = m.top() orelse return m.push(.{ .kind = .transparent });
    if (frame.kind != .table_row) return m.push(.{ .kind = .transparent });

    var col_span: u32 = 1;
    var merged_continuation = false;
    const first = try m.next();
    if (first == .element_start and first.element_start.name.is(w_ns, "tcPr")) {
        if (!first.element_start.self_closing) {
            const pr_depth = m.parser.depth;
            while (m.parser.depth >= pr_depth) {
                const pr_event = try m.next();
                switch (pr_event) {
                    .done => return,
                    .element_start => |child| {
                        if (child.name.is(w_ns, "gridSpan")) {
                            if (stringAttribute(child.attributes, "val")) |value| {
                                col_span = std.fmt.parseInt(u32, value, 10) catch 1;
                            }
                        } else if (child.name.is(w_ns, "vMerge")) {
                            const value = stringAttribute(child.attributes, "val") orelse "continue";
                            merged_continuation = !std.mem.eql(u8, value, "restart");
                        }
                    },
                    else => {},
                }
            }
        }
    } else {
        m.pending = first;
    }

    const table = blk: {
        var i = m.depth;
        while (i > 0) {
            i -= 1;
            if (m.frames[i].kind == .table) break :blk &m.tables[m.frames[i].table_index];
        }
        unreachable;
    };
    if ((col_span > 1 or merged_continuation) and !table.spans_noted) {
        table.spans_noted = true;
        try m.ctx.reports.add(mergedCellNote());
    }
    if (merged_continuation) {
        // Fold the continuation into its originating cell: skip it.
        try m.skipCurrent();
        return;
    }

    const token = try m.ctx.out.beginTableCell(.{
        .alignment = .default,
        .row_span = 1,
        .col_span = col_span,
    });
    try m.push(.{
        .kind = .table_cell,
        .block_token = token,
        .list_base = m.list_depth,
    });
}
