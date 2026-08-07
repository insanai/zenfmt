//! Sparse rich-document facets (ZDS 0013, Sparse Facets).
//!
//! Facets are stand-off annotation: typed rows keyed by `EntityId`, stored
//! in append-only side tables outside the kernel node arrays. By the facet
//! erasure axiom (ZDS 0013, Axiom 1) they refine kernel semantics and never
//! carry primary content, so a writer that ignores every facet table is
//! still correct. Rows are sorted by entity (the builder sorts each build's
//! suffix at `finish`), so lookup during writing is one binary search, and
//! a conversion that attaches nothing allocates nothing here.
//!
//! Strings referenced by facet rows live in the document text pool; the
//! plugin-facing `*Data` structs carry plain slices and the builder appends
//! them on attach.

const std = @import("std");
const ast = @import("ast.zig");

const ByteRange = ast.ByteRange;
const EntityId = ast.EntityId;

/// How much a reader trusts the structure it attached the facet to: DOCX
/// paragraphs are facts; PDF paragraphs are projections.
pub const Confidence = enum(u8) { exact, projected };

pub const Provenance = struct {
    entity: EntityId,
    /// Producing plugin id.
    plugin: ByteRange,
    /// Source member: an archive part name, spine item, page label.
    member: ByteRange,
    byte_start: u64,
    byte_len: u64,
    confidence: Confidence,
};

pub const ProvenanceData = struct {
    plugin: []const u8,
    member: []const u8 = "",
    byte_start: u64 = 0,
    byte_len: u64 = 0,
    confidence: Confidence = .exact,
};

pub const Direction = enum(u8) { inherit, ltr, rtl };

pub const Style = struct {
    entity: EntityId,
    /// Named style from the source's catalog, e.g. "Heading 2".
    name: ByteRange,
    /// Semantic role beyond the kernel tag, when the source declares one.
    role: ByteRange,
    /// BCP 47 language tag.
    language: ByteRange,
    direction: Direction,
};

pub const StyleData = struct {
    name: []const u8,
    role: []const u8 = "",
    language: []const u8 = "",
    direction: Direction = .inherit,
};

pub const Surface = enum(u8) { page, slide, canvas };

/// Geometry in EMU (1/914400 inch), top-left origin (ZDS 0013, One
/// coordinate system). Readers normalize at read time; original units, when
/// they matter, belong in `Provenance`.
pub const Layout = struct {
    entity: EntityId,
    surface: Surface,
    /// Zero-based page or slide index.
    surface_index: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    z_order: i32,
};

pub const LayoutData = struct {
    surface: Surface,
    surface_index: u32,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    z_order: i32 = 0,
};

pub const ValueType = enum(u8) { empty, text, number, boolean, error_value, date };

pub const Grid = struct {
    entity: EntityId,
    sheet: ByteRange,
    /// Zero-based coordinates in the sheet.
    row: u32,
    col: u32,
    value_type: ValueType,
    /// Formula source text, empty when the cell holds a literal.
    formula: ByteRange,
    /// The cached formula result as the source spelled it.
    cached: ByteRange,
    merge_rows: u16,
    merge_cols: u16,
};

pub const GridData = struct {
    sheet: []const u8,
    row: u32,
    col: u32,
    value_type: ValueType = .text,
    formula: []const u8 = "",
    cached: []const u8 = "",
    merge_rows: u16 = 1,
    merge_cols: u16 = 1,
};

pub const RevisionKind = enum(u8) { insertion, deletion, comment, bookmark };

pub const Revision = struct {
    entity: EntityId,
    kind: RevisionKind,
    author: ByteRange,
    /// The source's timestamp string, uninterpreted.
    timestamp: ByteRange,
    /// Comment text or bookmark name.
    note: ByteRange,
};

pub const RevisionData = struct {
    kind: RevisionKind,
    author: []const u8 = "",
    timestamp: []const u8 = "",
    note: []const u8 = "",
};

/// Binary search for the single row bound to `entity` in a sorted facet
/// table. Single-valued facets (style, layout, grid, provenance) use this.
pub fn find(comptime Row: type, rows: []const Row, entity: EntityId) ?Row {
    var lo: usize = 0;
    var hi: usize = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_entity = rows[mid].entity.raw();
        if (mid_entity == entity.raw()) return rows[mid];
        if (mid_entity < entity.raw()) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// The contiguous run of rows bound to `entity`, for multi-valued facets
/// (revision). Empty when none.
pub fn findAll(comptime Row: type, rows: []const Row, entity: EntityId) []const Row {
    var lo: usize = 0;
    var hi: usize = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (rows[mid].entity.raw() < entity.raw()) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < rows.len and rows[end].entity == entity) end += 1;
    return rows[lo..end];
}

test "find and findAll agree on a sorted table" {
    const rows = [_]Revision{
        .{ .entity = @enumFromInt(1), .kind = .insertion, .author = .empty, .timestamp = .empty, .note = .empty },
        .{ .entity = @enumFromInt(3), .kind = .comment, .author = .empty, .timestamp = .empty, .note = .empty },
        .{ .entity = @enumFromInt(3), .kind = .deletion, .author = .empty, .timestamp = .empty, .note = .empty },
        .{ .entity = @enumFromInt(7), .kind = .bookmark, .author = .empty, .timestamp = .empty, .note = .empty },
    };
    try std.testing.expectEqual(@as(usize, 2), findAll(Revision, &rows, @enumFromInt(3)).len);
    try std.testing.expectEqual(@as(usize, 0), findAll(Revision, &rows, @enumFromInt(2)).len);
    try std.testing.expectEqual(RevisionKind.bookmark, find(Revision, &rows, @enumFromInt(7)).?.kind);
    try std.testing.expectEqual(@as(?Revision, null), find(Revision, &rows, @enumFromInt(0)));
}
