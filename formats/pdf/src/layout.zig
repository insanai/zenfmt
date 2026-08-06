//! Line-flow projection (ZDS 0011): positioned lines become headings,
//! paragraphs, tables, and images.
//!
//! Tables are claimed conservatively, two ways: a painted lattice from
//! `graphics.detectGrid` assigns line fragments to its cells by position;
//! without rules, a run of three or more consecutive lines whose fragment
//! starts align on the same two-plus columns reads as a whitespace table.
//! Everything unclaimed flows through the original heading/paragraph
//! projection. Extracted images anchor between lines in drawing order.

const std = @import("std");
const assert = std.debug.assert;
const core = @import("zenfmt_core");
const content_mod = @import("content.zig");
const graphics = @import("graphics.zig");
const reports_mod = @import("reports.zig");

const Line = content_mod.Line;

/// Heading tiers relative to the document's body font size.
const h1_ratio = 1.6;
const h2_ratio = 1.35;
const h3_ratio = 1.12;
/// Vertical gap, in multiples of the line's font size, that separates
/// paragraphs.
const paragraph_gap_ratio = 1.7;
/// Consecutive aligned lines required before whitespace columns count.
const min_column_run = 3;
/// Tables larger than this are almost certainly misdetected geometry.
const max_table_cells = 4096;

pub fn emitDocument(
    ctx: *core.ReadContext,
    machine: *content_mod.Machine,
) core.ReadError!void {
    const arena = ctx.gpa;
    const lines = machine.lines.items;
    if (lines.len == 0 and machine.placed_images.items.len == 0) return;

    try registerMedia(ctx, machine);

    const consumed = try arena.alloc(bool, lines.len);
    @memset(consumed, false);
    var tables: std.ArrayList(Planned) = .empty;
    try planGridTables(arena, machine, lines, consumed, &tables);
    try planColumnTables(arena, lines, consumed, &tables);

    const body_size = if (lines.len > 0) try medianSize(arena, lines) else 12.0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    var open_kind: LineKind = .body;
    var block_open = false;
    var previous: ?Line = null;
    var image_cursor: usize = 0;

    for (lines, 0..) |line, index| {
        if (imagesAt(machine, &image_cursor, @intCast(index))) |range| {
            if (block_open) {
                try emitBlock(ctx, open_kind, buf.items);
                buf.clearRetainingCapacity();
                block_open = false;
                previous = null;
            }
            try emitImages(ctx, machine, range);
        }
        if (tableAt(tables.items, @intCast(index))) |planned| {
            if (block_open) {
                try emitBlock(ctx, open_kind, buf.items);
                buf.clearRetainingCapacity();
                block_open = false;
                previous = null;
            }
            try emitTable(ctx, planned);
        }
        if (consumed[index]) continue;

        const kind = classify(line, body_size);
        if (block_open and blockBreak(previous, line, kind, open_kind)) {
            try emitBlock(ctx, open_kind, buf.items);
            buf.clearRetainingCapacity();
            block_open = false;
        }
        if (!block_open) {
            block_open = true;
            open_kind = kind;
        } else if (buf.items.len > 0) {
            // A hyphenated wrap joins directly with the next line.
            const last = buf.items[buf.items.len - 1];
            if (last == '-' and line.text.len > 0 and std.ascii.isLower(line.text[0])) {
                buf.items.len -= 1;
            } else {
                try buf.append(arena, ' ');
            }
        }
        try buf.appendSlice(arena, line.text);
        previous = line;
    }
    if (block_open) try emitBlock(ctx, open_kind, buf.items);
    if (imagesAt(machine, &image_cursor, @intCast(lines.len))) |range| {
        try emitImages(ctx, machine, range);
    }
}

// ------------------------------------------------------------- images

/// Registers every unique extracted image with the engine's media
/// pipeline; past the media limits, remaining images degrade to omitted.
fn registerMedia(ctx: *core.ReadContext, machine: *content_mod.Machine) core.ReadError!void {
    for (machine.unique_images.items, 0..) |unique, index| {
        ctx.out.media(unique.source, unique.bytes, unique.mime) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DepthLimitExceeded => return error.DepthLimitExceeded,
            error.LimitExceeded => {
                const remaining: u32 = @intCast(machine.unique_images.items.len - index);
                machine.images += remaining;
                machine.unique_images.items.len = index;
                try ctx.reports.add(reports_mod.mediaLimitNote(remaining));
                break;
            },
        };
    }
}

/// The placed-image range anchored before line `index`, advancing the
/// cursor past it.
fn imagesAt(
    machine: *const content_mod.Machine,
    cursor: *usize,
    index: u32,
) ?[2]usize {
    const placed = machine.placed_images.items;
    const start = cursor.*;
    var end = start;
    while (end < placed.len and placed[end].insert_at <= index) end += 1;
    if (end == start) return null;
    cursor.* = end;
    return .{ start, end };
}

fn emitImages(
    ctx: *core.ReadContext,
    machine: *const content_mod.Machine,
    range: [2]usize,
) core.ReadError!void {
    for (machine.placed_images.items[range[0]..range[1]]) |placed| {
        // Images whose extraction was rolled back by the media limit
        // vanish from the unique list; skip their placements.
        if (placed.unique >= machine.unique_images.items.len) continue;
        const unique = machine.unique_images.items[placed.unique];
        const paragraph = try ctx.out.beginParagraph();
        const image = try ctx.out.beginImage(unique.source, "");
        ctx.out.endInline(image);
        ctx.out.endBlock(paragraph);
    }
}

// ------------------------------------------------------------- tables

const Planned = struct {
    first_line: u32,
    columns: u32,
    rows: u32,
    /// Row-major cell text.
    cells: []std.ArrayList(u8),
};

fn tableAt(tables: []const Planned, index: u32) ?*const Planned {
    for (tables) |*planned| {
        if (planned.first_line == index) return planned;
    }
    return null;
}

/// Assigns line fragments to painted-lattice cells, page by page.
fn planGridTables(
    arena: std.mem.Allocator,
    machine: *const content_mod.Machine,
    lines: []const Line,
    consumed: []bool,
    tables: *std.ArrayList(Planned),
) error{OutOfMemory}!void {
    for (machine.grids.items) |page_grid| {
        const grid = page_grid.grid;
        const columns = grid.columns();
        const rows = grid.rows();
        if (@as(u64, columns) * rows > max_table_cells) continue;

        const cells = try arena.alloc(std.ArrayList(u8), columns * rows);
        for (cells) |*cell| cell.* = .empty;
        var first_line: ?u32 = null;
        var lines_claimed: u32 = 0;

        for (lines, 0..) |line, index| {
            if (line.page != page_grid.page or consumed[index]) continue;
            const y_band = graphics.Grid.band(grid.ys, line.y) orelse continue;
            const row = rows - 1 - y_band;
            var claimed_fragment = false;
            for (line.fragments, 0..) |fragment, k| {
                const column = graphics.Grid.band(grid.xs, fragment.x) orelse continue;
                const cell = &cells[row * columns + column];
                const text = fragmentText(line, k);
                if (text.len == 0) continue;
                if (cell.items.len > 0) try cell.append(arena, ' ');
                try cell.appendSlice(arena, text);
                claimed_fragment = true;
            }
            if (claimed_fragment) {
                consumed[index] = true;
                lines_claimed += 1;
                if (first_line == null) first_line = @intCast(index);
            }
        }
        // A lattice with a single caption inside is a box, not a table.
        if (lines_claimed < 2) {
            for (lines, 0..) |line, index| {
                if (line.page != page_grid.page) continue;
                if (graphics.Grid.band(grid.ys, line.y) != null) consumed[index] = false;
            }
            continue;
        }
        try tables.append(arena, .{
            .first_line = first_line.?,
            .columns = columns,
            .rows = rows,
            .cells = cells,
        });
    }
}

/// Detects whitespace-aligned column runs among the unclaimed lines.
fn planColumnTables(
    arena: std.mem.Allocator,
    lines: []const Line,
    consumed: []bool,
    tables: *std.ArrayList(Planned),
) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < lines.len) {
        if (consumed[i] or lines[i].fragments.len < 2) {
            i += 1;
            continue;
        }
        // The maximal run of unclaimed multi-fragment lines on one page.
        var j = i + 1;
        while (j < lines.len and !consumed[j] and
            lines[j].page == lines[i].page and lines[j].fragments.len >= 2)
        {
            j += 1;
        }
        if (j - i < min_column_run) {
            i = j;
            continue;
        }
        if (try columnsOf(arena, lines[i..j])) |column_xs| {
            const columns: u32 = @intCast(column_xs.len);
            const rows: u32 = @intCast(j - i);
            const cells = try arena.alloc(std.ArrayList(u8), columns * rows);
            for (cells) |*cell| cell.* = .empty;
            for (lines[i..j], 0..) |line, row| {
                for (line.fragments, 0..) |fragment, k| {
                    const column = nearestColumn(column_xs, fragment.x);
                    const cell = &cells[row * columns + column];
                    const text = fragmentText(line, k);
                    if (text.len == 0) continue;
                    if (cell.items.len > 0) try cell.append(arena, ' ');
                    try cell.appendSlice(arena, text);
                }
                consumed[i + row] = true;
            }
            try tables.append(arena, .{
                .first_line = @intCast(i),
                .columns = columns,
                .rows = rows,
                .cells = cells,
            });
        }
        i = j;
    }
}

/// The shared column positions of a candidate run: fragment starts that
/// cluster to the same x on every line, at least two of them. Null means
/// the run is prose after all.
fn columnsOf(
    arena: std.mem.Allocator,
    run: []const Line,
) error{OutOfMemory}!?[]const f64 {
    assert(run.len >= min_column_run);
    var size_sum: f64 = 0;
    var all_xs: std.ArrayList(f64) = .empty;
    defer all_xs.deinit(arena);
    for (run) |line| {
        size_sum += line.size;
        for (line.fragments) |fragment| try all_xs.append(arena, fragment.x);
    }
    const tolerance = @max(4.0, 0.5 * size_sum / @as(f64, @floatFromInt(run.len)));
    std.mem.sort(f64, all_xs.items, {}, std.sort.asc(f64));
    const centers = try graphics.cluster(arena, all_xs.items, tolerance);

    // Keep the clusters every line participates in.
    var kept: std.ArrayList(f64) = .empty;
    for (centers) |center| {
        var hit_lines: u32 = 0;
        for (run) |line| {
            for (line.fragments) |fragment| {
                if (@abs(fragment.x - center) <= tolerance) {
                    hit_lines += 1;
                    break;
                }
            }
        }
        if (hit_lines == run.len) try kept.append(arena, center);
    }
    if (kept.items.len < 2) return null;
    return kept.items;
}

fn nearestColumn(centers: []const f64, x: f64) u32 {
    assert(centers.len > 0);
    var best: u32 = 0;
    var best_distance = @abs(centers[0] - x);
    for (centers[1..], 1..) |center, index| {
        const distance = @abs(center - x);
        if (distance < best_distance) {
            best_distance = distance;
            best = @intCast(index);
        }
    }
    return best;
}

/// One fragment's text within its line, trailing separator trimmed.
fn fragmentText(line: Line, index: usize) []const u8 {
    const start = line.fragments[index].offset;
    const end = if (index + 1 < line.fragments.len)
        line.fragments[index + 1].offset
    else
        line.text.len;
    return std.mem.trim(u8, line.text[start..end], " \t");
}

/// All rows go to the table body: PDF has no header semantics, and
/// guessing one from typography would be wrong more often than right.
fn emitTable(ctx: *core.ReadContext, planned: *const Planned) core.ReadError!void {
    const arena = ctx.gpa;
    var alignments: std.ArrayList(core.payload.Alignment) = .empty;
    defer alignments.deinit(arena);
    try alignments.appendNTimes(arena, .default, planned.columns);
    const table = try ctx.out.beginTable(alignments.items);
    const body = try ctx.out.beginTableBody(.{ .row_head_columns = 0, .head_rows = 0 });
    var row: u32 = 0;
    while (row < planned.rows) : (row += 1) {
        const row_token = try ctx.out.beginBlock(.table_row);
        var column: u32 = 0;
        while (column < planned.columns) : (column += 1) {
            const cell = try ctx.out.beginTableCell(.{
                .alignment = .default,
                .row_span = 1,
                .col_span = 1,
            });
            const plain = try ctx.out.beginPlain();
            const text = planned.cells[row * planned.columns + column].items;
            if (text.len > 0) try ctx.out.text(text);
            ctx.out.endBlock(plain);
            ctx.out.endBlock(cell);
        }
        ctx.out.endBlock(row_token);
    }
    ctx.out.endBlock(body);
    ctx.out.endBlock(table);
}

// -------------------------------------------------------- classification

const LineKind = union(enum) { body, heading: u8 };

fn emitBlock(ctx: *core.ReadContext, kind: LineKind, text: []const u8) core.ReadError!void {
    if (text.len == 0) return;
    const token = switch (kind) {
        .heading => |level| try ctx.out.beginHeading(level),
        .body => try ctx.out.beginParagraph(),
    };
    try ctx.out.text(text);
    ctx.out.endBlock(token);
}

fn classify(line: Line, body_size: f64) LineKind {
    if (line.size >= body_size * h1_ratio) return .{ .heading = 1 };
    if (line.size >= body_size * h2_ratio) return .{ .heading = 2 };
    if (line.size >= body_size * h3_ratio and line.bold) return .{ .heading = 3 };
    return .body;
}

fn blockBreak(
    previous: ?Line,
    line: Line,
    kind: LineKind,
    open_kind: LineKind,
) bool {
    const prev = previous orelse return false;
    if (!std.meta.eql(kind, open_kind)) return true;
    if (kind == .heading) {
        // Heading lines merge only when tightly stacked on one page.
        if (line.page != prev.page) return true;
        return prev.y - line.y > line.size * 1.4;
    }
    if (line.page != prev.page) return true;
    const gap = prev.y - line.y;
    if (gap < 0) return true;
    return gap > paragraph_gap_ratio * @max(line.size, 6.0);
}

/// The document's body font size: the median of all line sizes, which
/// shrugs off title pages and footnotes alike.
fn medianSize(arena: std.mem.Allocator, lines: []const Line) error{OutOfMemory}!f64 {
    assert(lines.len > 0);
    const sizes = try arena.alloc(f64, lines.len);
    for (lines, 0..) |line, i| sizes[i] = line.size;
    std.mem.sort(f64, sizes, {}, std.sort.asc(f64));
    const median = sizes[sizes.len / 2];
    return if (median > 0.5) median else 12.0;
}
