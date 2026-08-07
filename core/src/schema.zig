//! The node schema table (ZDS 0013, The Semantic Kernel).
//!
//! One comptime table, one row per tag. Content kind, placement rules,
//! payload kind, and debug names are all read from the same row, so a
//! property that used to live in five coordinated switches is now stated
//! once and derived everywhere. A new tag is one new row; forgetting the
//! row is a compile error, and the derived predicates cannot disagree with
//! one another because they share it.
//!
//! The table deliberately holds *facts about tags*, not construction code:
//! views and builders stay in `payload.zig` and `builder.zig`, where the
//! compiler still enforces coverage through exhaustive switches over the
//! same enums.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");

const BlockTag = ast.BlockTag;
const InlineTag = ast.InlineTag;

/// What a block node's children are.
pub const ContentKind = enum {
    /// Leaf in the block tree; children are an inline range.
    inlines,
    /// Container in the block tree; descendants follow in preorder.
    blocks,
    /// True leaf: no children of either kind.
    none,
};

/// Which payload side table a tag's `payload` column indexes.
pub const PayloadKind = enum {
    /// No payload; the column must be zero.
    none,
    heading,
    list,
    /// A `ByteRange` literal: `code_block`, `code`.
    literal,
    raw,
    table,
    table_body,
    table_cell,
    /// A `ByteRange` text span: `text` inlines.
    span,
    math,
    /// Link and image targets.
    target,
    /// A block forest outside the body: `note`.
    note_blocks,
    citation,
    /// The payload column IS the `QuoteKind` value.
    quote_kind,
    extension,
};

/// What a container block accepts as children.
pub const ChildRule = union(enum) {
    /// Any non-structural block: flow content.
    flow,
    /// Exactly these structural tags, nothing else.
    only: []const BlockTag,
    /// These structural tags, or any non-structural block.
    flow_plus: []const BlockTag,
    /// Inline content; no block children.
    inline_content,
    /// No children of either kind.
    none,
};

pub const BlockRow = struct {
    tag: BlockTag,
    payload: PayloadKind,
    children: ChildRule,
};

pub const InlineRow = struct {
    tag: InlineTag,
    payload: PayloadKind,
    has_children: bool,
};

/// The block table, in enum order (checked below). Public flow tags first,
/// then the private structural tags, exactly as `BlockTag` declares them.
pub const block_schema = [_]BlockRow{
    .{ .tag = .plain, .payload = .none, .children = .inline_content },
    .{ .tag = .paragraph, .payload = .none, .children = .inline_content },
    .{ .tag = .line_block, .payload = .none, .children = .{ .only = &.{.line} } },
    .{ .tag = .heading, .payload = .heading, .children = .inline_content },
    .{ .tag = .code_block, .payload = .literal, .children = .none },
    .{ .tag = .raw_block, .payload = .raw, .children = .none },
    .{ .tag = .quote, .payload = .none, .children = .flow },
    .{ .tag = .list, .payload = .list, .children = .{ .only = &.{.list_item} } },
    .{ .tag = .definition_list, .payload = .none, .children = .{ .only = &.{.definition_entry} } },
    .{ .tag = .thematic_break, .payload = .none, .children = .none },
    .{ .tag = .table, .payload = .table, .children = .{ .only = &.{ .caption, .table_head, .table_body, .table_foot } } },
    .{ .tag = .figure, .payload = .none, .children = .{ .flow_plus = &.{.caption} } },
    .{ .tag = .container, .payload = .none, .children = .flow },
    .{ .tag = .extension, .payload = .extension, .children = .flow },
    .{ .tag = .line, .payload = .none, .children = .inline_content },
    .{ .tag = .list_item, .payload = .none, .children = .flow },
    .{ .tag = .definition_entry, .payload = .none, .children = .{ .only = &.{ .definition_term, .definition_body } } },
    .{ .tag = .definition_term, .payload = .none, .children = .inline_content },
    .{ .tag = .definition_body, .payload = .none, .children = .flow },
    .{ .tag = .caption, .payload = .none, .children = .flow },
    .{ .tag = .table_head, .payload = .none, .children = .{ .only = &.{.table_row} } },
    .{ .tag = .table_body, .payload = .table_body, .children = .{ .only = &.{.table_row} } },
    .{ .tag = .table_foot, .payload = .none, .children = .{ .only = &.{.table_row} } },
    .{ .tag = .table_row, .payload = .none, .children = .{ .only = &.{.table_cell} } },
    .{ .tag = .table_cell, .payload = .table_cell, .children = .flow },
};

/// The inline table, in enum order (checked below).
pub const inline_schema = [_]InlineRow{
    .{ .tag = .text, .payload = .span, .has_children = false },
    .{ .tag = .space, .payload = .none, .has_children = false },
    .{ .tag = .soft_break, .payload = .none, .has_children = false },
    .{ .tag = .hard_break, .payload = .none, .has_children = false },
    .{ .tag = .emphasis, .payload = .none, .has_children = true },
    .{ .tag = .underline, .payload = .none, .has_children = true },
    .{ .tag = .strong, .payload = .none, .has_children = true },
    .{ .tag = .strikethrough, .payload = .none, .has_children = true },
    .{ .tag = .superscript, .payload = .none, .has_children = true },
    .{ .tag = .subscript, .payload = .none, .has_children = true },
    .{ .tag = .small_caps, .payload = .none, .has_children = true },
    .{ .tag = .quote, .payload = .quote_kind, .has_children = true },
    .{ .tag = .code, .payload = .literal, .has_children = false },
    .{ .tag = .math, .payload = .math, .has_children = false },
    .{ .tag = .raw, .payload = .raw, .has_children = false },
    .{ .tag = .link, .payload = .target, .has_children = true },
    .{ .tag = .image, .payload = .target, .has_children = true },
    .{ .tag = .note, .payload = .note_blocks, .has_children = false },
    .{ .tag = .span, .payload = .none, .has_children = true },
    .{ .tag = .citation, .payload = .citation, .has_children = true },
    .{ .tag = .extension, .payload = .extension, .has_children = true },
};

// Totality: one row per tag, in enum order, so lookup is a direct index and
// a missing or misplaced row fails compilation, not review.
comptime {
    assert(block_schema.len == @typeInfo(BlockTag).@"enum".fields.len);
    for (block_schema, 0..) |row, index| {
        assert(@intFromEnum(row.tag) == index);
    }
    assert(inline_schema.len == @typeInfo(InlineTag).@"enum".fields.len);
    for (inline_schema, 0..) |row, index| {
        assert(@intFromEnum(row.tag) == index);
    }
    // Structural tags never carry a child rule that admits them at the
    // root, and only container rules name structural children.
    for (block_schema) |row| {
        switch (row.children) {
            .only, .flow_plus => |tags| for (tags) |child| assert(child.isStructural()),
            else => {},
        }
    }
}

pub inline fn blockRowOf(tag: BlockTag) BlockRow {
    return block_schema[@intFromEnum(tag)];
}

pub inline fn inlineRowOf(tag: InlineTag) InlineRow {
    return inline_schema[@intFromEnum(tag)];
}

// ----------------------------------------------------- derived predicates

pub fn blockContent(tag: BlockTag) ContentKind {
    return switch (blockRowOf(tag).children) {
        .inline_content => .inlines,
        .none => .none,
        .flow, .only, .flow_plus => .blocks,
    };
}

/// Child tags appear only under their parent tag. `null` is a forest root:
/// the body, a note's blocks, or a metadata block value.
pub fn blockPlacementAllowed(parent: ?BlockTag, child: BlockTag) bool {
    const parent_tag = parent orelse return !child.isStructural();
    return switch (blockRowOf(parent_tag).children) {
        .flow => !child.isStructural(),
        .only => |tags| contains(tags, child),
        .flow_plus => |tags| !child.isStructural() or contains(tags, child),
        .inline_content, .none => false,
    };
}

pub fn inlineHasChildren(tag: InlineTag) bool {
    return inlineRowOf(tag).has_children;
}

pub fn blockName(tag: BlockTag) []const u8 {
    return @tagName(tag);
}

pub fn inlineName(tag: InlineTag) []const u8 {
    return @tagName(tag);
}

fn contains(tags: []const BlockTag, child: BlockTag) bool {
    assert(tags.len >= 1);
    assert(tags.len <= 4);
    for (tags) |tag| {
        if (tag == child) return true;
    }
    return false;
}

// ---------------------------------------------------------------- tests

test "derived predicates match the recorded schema" {
    // Spot checks pinning the rules the readers and validator depend on.
    try std.testing.expectEqual(ContentKind.inlines, blockContent(.paragraph));
    try std.testing.expectEqual(ContentKind.none, blockContent(.thematic_break));
    try std.testing.expectEqual(ContentKind.blocks, blockContent(.extension));

    try std.testing.expect(blockPlacementAllowed(null, .paragraph));
    try std.testing.expect(!blockPlacementAllowed(null, .list_item));
    try std.testing.expect(blockPlacementAllowed(.list, .list_item));
    try std.testing.expect(!blockPlacementAllowed(.list, .paragraph));
    try std.testing.expect(blockPlacementAllowed(.table_row, .table_cell));
    try std.testing.expect(!blockPlacementAllowed(.table, .table_row));
    try std.testing.expect(blockPlacementAllowed(.figure, .caption));
    try std.testing.expect(blockPlacementAllowed(.figure, .paragraph));
    try std.testing.expect(blockPlacementAllowed(.extension, .paragraph));
    try std.testing.expect(!blockPlacementAllowed(.extension, .table_row));

    try std.testing.expect(inlineHasChildren(.extension));
    try std.testing.expect(!inlineHasChildren(.text));
}

test "every tag names its own row" {
    inline for (@typeInfo(BlockTag).@"enum".fields) |field| {
        const tag: BlockTag = @enumFromInt(field.value);
        try std.testing.expectEqual(tag, blockRowOf(tag).tag);
    }
    inline for (@typeInfo(InlineTag).@"enum".fields) |field| {
        const tag: InlineTag = @enumFromInt(field.value);
        try std.testing.expectEqual(tag, inlineRowOf(tag).tag);
    }
}
