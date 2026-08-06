//! Vector-path evidence for table reconstruction (ZDS 0011).
//!
//! The content machine feeds every painted `m`/`l`/`re` segment through
//! the tracker in device space; at page end `detectGrid` looks for the
//! lattice a drawn table leaves behind: at least three distinct vertical
//! and three distinct horizontal rules sharing one bounding box. One grid
//! per page — the largest — keeps detection conservative.

const std = @import("std");
const assert = std.debug.assert;

/// Segments a page may contribute; drawings beyond this stop the tracker
/// (a chart with thousands of strokes is not a table).
const max_segments = 512;
/// Path points one subpath may hold before the tracker gives up on it.
const max_pending = 64;
/// Device-space tolerance when clustering rule positions.
pub const cluster_tolerance = 2.0;
/// Fraction of the lattice extent a rule must span to count.
const span_fraction = 0.7;

pub const Seg = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// Collects painted axis-aligned segments. The caller transforms points
/// to device space before feeding them.
pub const PathTracker = struct {
    arena: std.mem.Allocator,
    horizontal: std.ArrayList(Seg) = .empty,
    vertical: std.ArrayList(Seg) = .empty,
    pending: [max_pending]Seg = undefined,
    pending_count: u32 = 0,
    current: ?[2]f64 = null,
    saturated: bool = false,

    pub fn reset(t: *PathTracker) void {
        t.horizontal.clearRetainingCapacity();
        t.vertical.clearRetainingCapacity();
        t.pending_count = 0;
        t.current = null;
        t.saturated = false;
    }

    pub fn moveTo(t: *PathTracker, x: f64, y: f64) void {
        t.current = .{ x, y };
    }

    pub fn lineTo(t: *PathTracker, x: f64, y: f64) void {
        const from = t.current orelse {
            t.current = .{ x, y };
            return;
        };
        t.pushPending(.{ .x0 = from[0], .y0 = from[1], .x1 = x, .y1 = y });
        t.current = .{ x, y };
    }

    pub fn rect(t: *PathTracker, x: f64, y: f64, w: f64, h: f64) void {
        t.pushPending(.{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y });
        t.pushPending(.{ .x0 = x, .y0 = y + h, .x1 = x + w, .y1 = y + h });
        t.pushPending(.{ .x0 = x, .y0 = y, .x1 = x, .y1 = y + h });
        t.pushPending(.{ .x0 = x + w, .y0 = y, .x1 = x + w, .y1 = y + h });
        t.current = .{ x, y };
    }

    fn pushPending(t: *PathTracker, seg: Seg) void {
        if (t.pending_count >= max_pending) return;
        t.pending[t.pending_count] = seg;
        t.pending_count += 1;
    }

    /// A painting operator ends the path; `discard` is the no-op `n`.
    pub fn paint(t: *PathTracker, discard: bool) error{OutOfMemory}!void {
        defer {
            t.pending_count = 0;
            t.current = null;
        }
        if (discard or t.saturated) return;
        for (t.pending[0..t.pending_count]) |seg| {
            const total = t.horizontal.items.len + t.vertical.items.len;
            if (total >= max_segments) {
                t.saturated = true;
                return;
            }
            if (@abs(seg.y1 - seg.y0) <= cluster_tolerance and
                @abs(seg.x1 - seg.x0) > cluster_tolerance)
            {
                try t.horizontal.append(t.arena, seg);
            } else if (@abs(seg.x1 - seg.x0) <= cluster_tolerance and
                @abs(seg.y1 - seg.y0) > cluster_tolerance)
            {
                try t.vertical.append(t.arena, seg);
            }
        }
    }
};

/// The lattice of a drawn table: sorted column edges and row edges in
/// device space. `xs.len - 1` columns by `ys.len - 1` rows.
pub const Grid = struct {
    xs: []const f64,
    ys: []const f64,

    pub fn columns(grid: Grid) u32 {
        return @intCast(grid.xs.len - 1);
    }

    pub fn rows(grid: Grid) u32 {
        return @intCast(grid.ys.len - 1);
    }

    /// The 0-based band index for a coordinate, or null when outside.
    pub fn band(edges: []const f64, value: f64) ?u32 {
        if (edges.len < 2) return null;
        if (value < edges[0] - cluster_tolerance) return null;
        if (value > edges[edges.len - 1] + cluster_tolerance) return null;
        var i: usize = 1;
        while (i < edges.len) : (i += 1) {
            if (value <= edges[i]) return @intCast(i - 1);
        }
        return @intCast(edges.len - 2);
    }
};

/// Clusters a sorted slice of positions into centers no closer than the
/// tolerance. Returns cluster centers, ascending.
pub fn cluster(
    arena: std.mem.Allocator,
    sorted: []const f64,
    tolerance: f64,
) error{OutOfMemory}![]const f64 {
    var centers: std.ArrayList(f64) = .empty;
    var i: usize = 0;
    while (i < sorted.len) {
        var j = i + 1;
        var sum = sorted[i];
        while (j < sorted.len and sorted[j] - sorted[j - 1] <= tolerance) : (j += 1) {
            sum += sorted[j];
        }
        try centers.append(arena, sum / @as(f64, @floatFromInt(j - i)));
        i = j;
    }
    return centers.items;
}

/// The largest table lattice the page's painted rules support, if any:
/// at least three vertical and three horizontal rules whose merged spans
/// agree. Collinear segments merge first, because real producers draw a
/// table as one rectangle per cell — each edge spans one cell, but the
/// edges of a row line up into a full-width rule.
pub fn detectGrid(
    arena: std.mem.Allocator,
    horizontal: []const Seg,
    vertical: []const Seg,
) error{OutOfMemory}!?Grid {
    if (horizontal.len < 3 or vertical.len < 3) return null;

    // The drawing's overall bounding box, from every collected segment.
    var min_x = horizontal[0].x0;
    var max_x = min_x;
    var min_y = vertical[0].y0;
    var max_y = min_y;
    for (horizontal) |seg| {
        min_x = @min(min_x, @min(seg.x0, seg.x1));
        max_x = @max(max_x, @max(seg.x0, seg.x1));
    }
    for (vertical) |seg| {
        min_y = @min(min_y, @min(seg.y0, seg.y1));
        max_y = @max(max_y, @max(seg.y0, seg.y1));
    }
    const width = max_x - min_x;
    const height = max_y - min_y;
    if (width <= cluster_tolerance or height <= cluster_tolerance) return null;

    const ys = try spanningRules(arena, horizontal, .horizontal, width);
    const xs = try spanningRules(arena, vertical, .vertical, height);
    if (xs.len < 3 or ys.len < 3) return null;
    return .{ .xs = xs, .ys = ys };
}

const Axis = enum { horizontal, vertical };

/// Clusters segments by rule position, merges each cluster's members
/// into one rule, and keeps the rules whose merged extent spans the
/// lattice. Returns the kept rule positions, ascending.
fn spanningRules(
    arena: std.mem.Allocator,
    segments: []const Seg,
    axis: Axis,
    full_extent: f64,
) error{OutOfMemory}![]const f64 {
    const positions = try arena.alloc(f64, segments.len);
    for (segments, 0..) |seg, i| {
        positions[i] = switch (axis) {
            .horizontal => (seg.y0 + seg.y1) / 2,
            .vertical => (seg.x0 + seg.x1) / 2,
        };
    }
    std.mem.sort(f64, positions, {}, std.sort.asc(f64));
    const centers = try cluster(arena, positions, cluster_tolerance);

    var kept: std.ArrayList(f64) = .empty;
    for (centers) |center| {
        var lo = std.math.inf(f64);
        var hi = -std.math.inf(f64);
        for (segments) |seg| {
            const position = switch (axis) {
                .horizontal => (seg.y0 + seg.y1) / 2,
                .vertical => (seg.x0 + seg.x1) / 2,
            };
            if (@abs(position - center) > cluster_tolerance) continue;
            switch (axis) {
                .horizontal => {
                    lo = @min(lo, @min(seg.x0, seg.x1));
                    hi = @max(hi, @max(seg.x0, seg.x1));
                },
                .vertical => {
                    lo = @min(lo, @min(seg.y0, seg.y1));
                    hi = @max(hi, @max(seg.y0, seg.y1));
                },
            }
        }
        if (hi - lo >= span_fraction * full_extent) try kept.append(arena, center);
    }
    return kept.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "a drawn lattice becomes a grid; sparse strokes do not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tracker = PathTracker{ .arena = arena };
    // A 2x2 table: three horizontals, three verticals.
    tracker.moveTo(100, 700);
    tracker.lineTo(300, 700);
    try tracker.paint(false);
    tracker.moveTo(100, 650);
    tracker.lineTo(300, 650);
    try tracker.paint(false);
    tracker.moveTo(100, 600);
    tracker.lineTo(300, 600);
    try tracker.paint(false);
    inline for (.{ 100, 200, 300 }) |x| {
        tracker.moveTo(x, 700);
        tracker.lineTo(x, 600);
        try tracker.paint(false);
    }
    const grid = (try detectGrid(arena, tracker.horizontal.items, tracker.vertical.items)).?;
    try testing.expectEqual(@as(u32, 2), grid.columns());
    try testing.expectEqual(@as(u32, 2), grid.rows());
    try testing.expectEqual(@as(?u32, 0), Grid.band(grid.xs, 150));
    try testing.expectEqual(@as(?u32, 1), Grid.band(grid.xs, 250));
    try testing.expectEqual(@as(?u32, null), Grid.band(grid.xs, 400));

    // Two rules alone never make a table.
    var sparse = PathTracker{ .arena = arena };
    sparse.moveTo(0, 10);
    sparse.lineTo(100, 10);
    try sparse.paint(false);
    sparse.moveTo(0, 0);
    sparse.lineTo(0, 10);
    try sparse.paint(false);
    try testing.expectEqual(
        @as(?Grid, null),
        try detectGrid(arena, sparse.horizontal.items, sparse.vertical.items),
    );
}

test "discarded paths and rectangles route correctly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tracker = PathTracker{ .arena = arena };
    tracker.rect(10, 10, 100, 50);
    try tracker.paint(false);
    try testing.expectEqual(@as(usize, 2), tracker.horizontal.items.len);
    try testing.expectEqual(@as(usize, 2), tracker.vertical.items.len);

    tracker.moveTo(0, 0);
    tracker.lineTo(50, 0);
    try tracker.paint(true); // `n`: clipping path, never painted.
    try testing.expectEqual(@as(usize, 2), tracker.horizontal.items.len);
}
