//! Typed payloads and the comptime node schema (ZDS 0002, Attributes).
//!
//! The `payload` column of a stored node is an index into a typed side table
//! selected by the tag, reached only through the views here. One schema —
//! `blockContent`, `blockPlacementAllowed`, and the payload validators — is
//! consulted by the builder, the validator, and the views, so a new tag
//! produces compile errors in every exhaustive switch rather than five
//! handwritten tables that can drift.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");

const BlockTag = ast.BlockTag;
const InlineTag = ast.InlineTag;
const ByteRange = ast.ByteRange;
const BlockRange = ast.BlockRange;
const InlineRange = ast.InlineRange;
const Store = ast.Store;

// ------------------------------------------------------- payload tables

pub const Heading = struct {
    /// 1 through 6; readers clamp deeper levels with a note.
    level: u8,
};

pub const ListKind = enum(u8) { unordered, ordered };

pub const NumberStyle = enum(u8) {
    decimal,
    lower_alpha,
    upper_alpha,
    lower_roman,
    upper_roman,
};

pub const NumberDelimiter = enum(u8) { period, paren, two_parens };

pub const ListProps = struct {
    kind: ListKind,
    /// First item number; ignored for unordered lists.
    start: i64,
    style: NumberStyle,
    delimiter: NumberDelimiter,

    pub const unordered: ListProps = .{
        .kind = .unordered,
        .start = 1,
        .style = .decimal,
        .delimiter = .period,
    };
};

pub const Raw = struct {
    /// Interned format name, e.g. "html".
    format: ByteRange,
    text: ByteRange,
};

pub const MathKind = enum(u8) { inline_math, display };

pub const Math = struct {
    kind: MathKind,
    text: ByteRange,
};

pub const Alignment = enum(u8) { default, left, center, right };

pub const ColumnSpec = struct {
    alignment: Alignment,
};

/// A run of rows in `Store.columns`.
pub const ColumnRange = struct {
    start: u32,
    len: u32,

    pub const empty: ColumnRange = .{ .start = 0, .len = 0 };
};

pub const TableProps = struct {
    columns: ColumnRange,
};

pub const TableBodyProps = struct {
    row_head_columns: u32,
    head_rows: u32,
};

pub const TableCellProps = struct {
    alignment: Alignment,
    row_span: u32,
    col_span: u32,

    pub const plain: TableCellProps = .{
        .alignment = .default,
        .row_span = 1,
        .col_span = 1,
    };
};

pub const QuoteKind = enum(u8) { single, double };

pub const Target = struct {
    url: ByteRange,
    title: ByteRange,
};

pub const CitationMode = enum(u8) { normal, in_text, suppress_author };

pub const Citation = struct {
    id: ByteRange,
    prefix: InlineRange,
    suffix: InlineRange,
    mode: CitationMode,
};

/// A run of rows in `Store.citations`.
pub const CitationRange = struct {
    start: u32,
    len: u32,
};

pub const Media = struct {
    /// Path, URL, or archive entry name; indexes the text pool.
    source: ByteRange,
    /// Extracted content; indexes `Store.media_bytes`, not the text pool.
    bytes: ByteRange,
    mime: ByteRange,
};

// -------------------------------------------------------------- schema

pub const ContentKind = enum {
    /// Leaf in the block tree; children are an inline range.
    inlines,
    /// Container in the block tree; descendants follow in preorder.
    blocks,
    /// True leaf: no children of either kind.
    none,
};

pub fn blockContent(tag: BlockTag) ContentKind {
    return switch (tag) {
        .plain, .paragraph, .heading, .line, .definition_term => .inlines,
        .code_block, .raw_block, .thematic_break => .none,
        .line_block,
        .quote,
        .list,
        .definition_list,
        .table,
        .figure,
        .container,
        .list_item,
        .definition_entry,
        .definition_body,
        .caption,
        .table_head,
        .table_body,
        .table_foot,
        .table_row,
        .table_cell,
        => .blocks,
    };
}

/// Child tags appear only under their parent tag. `null` is a forest root:
/// the body, a note's blocks, or a metadata block value.
pub fn blockPlacementAllowed(parent: ?BlockTag, child: BlockTag) bool {
    const parent_tag = parent orelse return !child.isStructural();
    return switch (parent_tag) {
        .list => child == .list_item,
        .definition_list => child == .definition_entry,
        .definition_entry => child == .definition_term or child == .definition_body,
        .line_block => child == .line,
        .table => switch (child) {
            .caption, .table_head, .table_body, .table_foot => true,
            else => false,
        },
        .table_head, .table_body, .table_foot => child == .table_row,
        .table_row => child == .table_cell,
        .figure => child == .caption or !child.isStructural(),
        .quote, .container, .list_item, .definition_body, .table_cell, .caption => !child.isStructural(),
        // Inline-content and childless tags never parent a block; the forest
        // walkers never push them.
        .plain, .paragraph, .heading, .line, .definition_term => false,
        .code_block, .raw_block, .thematic_break => false,
    };
}

pub fn inlineHasChildren(tag: InlineTag) bool {
    return switch (tag) {
        .emphasis,
        .underline,
        .strong,
        .strikethrough,
        .superscript,
        .subscript,
        .small_caps,
        .quote,
        .link,
        .image,
        .span,
        .citation,
        => true,
        .text, .space, .soft_break, .hard_break, .code, .math, .raw, .note => false,
    };
}

/// The canonical nesting order required of flag-based readers, outermost
/// first (ZDS 0002, Why the tree is a tree). Stated once, here, and asserted
/// by a shared test that every flag-based reader runs.
pub const canonical_inline_order = [_]InlineTag{
    .link,
    .strong,
    .emphasis,
    .strikethrough,
    .superscript,
    .subscript,
    .small_caps,
    .underline,
};

pub fn blockPayloadValid(store: *const Store, tag: BlockTag, index: u32) bool {
    switch (tag) {
        .heading => {
            if (index >= store.headings.items.len) return false;
            const heading = store.headings.items[index];
            return heading.level >= 1 and heading.level <= 6;
        },
        .list => return index < store.lists.items.len,
        .code_block => return index < store.literals.items.len and
            byteRangeValid(store, store.literals.items[index]),
        .raw_block => return index < store.raws.items.len and
            rawValid(store, store.raws.items[index]),
        .table => {
            if (index >= store.tables.items.len) return false;
            const table = store.tables.items[index];
            return table.columns.start + table.columns.len <= store.columns.items.len;
        },
        .table_body => return index < store.table_bodies.items.len,
        .table_cell => return index < store.table_cells.items.len,
        else => return index == 0,
    }
}

pub fn inlinePayloadValid(store: *const Store, tag: InlineTag, index: u32) bool {
    switch (tag) {
        .text => return index < store.spans.items.len and
            byteRangeValid(store, store.spans.items[index]),
        .code => return index < store.literals.items.len and
            byteRangeValid(store, store.literals.items[index]),
        .math => return index < store.maths.items.len and
            byteRangeValid(store, store.maths.items[index].text),
        .raw => return index < store.raws.items.len and
            rawValid(store, store.raws.items[index]),
        .link, .image => return index < store.targets.items.len and
            byteRangeValid(store, store.targets.items[index].url) and
            byteRangeValid(store, store.targets.items[index].title),
        .note => return index < store.block_ranges.items.len,
        .citation => {
            if (index >= store.citation_ranges.items.len) return false;
            const range = store.citation_ranges.items[index];
            return range.start + range.len <= store.citations.items.len;
        },
        .quote => return index <= @intFromEnum(QuoteKind.double),
        .space, .soft_break, .hard_break => return index == 0,
        .emphasis,
        .underline,
        .strong,
        .strikethrough,
        .superscript,
        .subscript,
        .small_caps,
        .span,
        => return index == 0,
    }
}

fn byteRangeValid(store: *const Store, range: ByteRange) bool {
    return range.end() <= store.text.items.len;
}

fn rawValid(store: *const Store, raw: Raw) bool {
    return byteRangeValid(store, raw.format) and byteRangeValid(store, raw.text);
}

// --------------------------------------------------------------- views

pub const HeadingView = struct {
    level: u8,
    inlines: InlineRange,
};

pub const ListView = struct {
    kind: ListKind,
    start: i64,
    style: NumberStyle,
    delimiter: NumberDelimiter,
    /// The `list_item` children, as a descendant span; iterate with
    /// `Document.blockRoots`.
    items: BlockRange,
};

pub const TableView = struct {
    columns: ColumnRange,
    /// `caption` and section children, as a descendant span.
    content: BlockRange,
};

pub const TableBodyView = struct {
    row_head_columns: u32,
    head_rows: u32,
    rows: BlockRange,
};

pub const TableCellView = struct {
    alignment: Alignment,
    row_span: u32,
    col_span: u32,
    blocks: BlockRange,
};

pub const QuoteView = struct {
    kind: QuoteKind,
    children: InlineRange,
};

pub const TargetView = struct {
    url: ByteRange,
    title: ByteRange,
    children: InlineRange,
};

pub const CitationView = struct {
    citations: CitationRange,
    children: InlineRange,
};

pub const BlockView = struct {
    attrs: ast.OptionalAttrsIndex,
    content: union(BlockTag) {
        plain: InlineRange,
        paragraph: InlineRange,
        line_block: BlockRange,
        heading: HeadingView,
        code_block: ByteRange,
        raw_block: Raw,
        quote: BlockRange,
        list: ListView,
        definition_list: BlockRange,
        thematic_break: void,
        table: TableView,
        figure: BlockRange,
        container: BlockRange,
        line: InlineRange,
        list_item: BlockRange,
        definition_entry: BlockRange,
        definition_term: InlineRange,
        definition_body: BlockRange,
        caption: BlockRange,
        table_head: BlockRange,
        table_body: TableBodyView,
        table_foot: BlockRange,
        table_row: BlockRange,
        table_cell: TableCellView,
    },
};

pub const InlineView = struct {
    attrs: ast.OptionalAttrsIndex,
    content: union(InlineTag) {
        text: ByteRange,
        space: void,
        soft_break: void,
        hard_break: void,
        emphasis: InlineRange,
        underline: InlineRange,
        strong: InlineRange,
        strikethrough: InlineRange,
        superscript: InlineRange,
        subscript: InlineRange,
        small_caps: InlineRange,
        quote: QuoteView,
        code: ByteRange,
        math: Math,
        raw: Raw,
        link: TargetView,
        image: TargetView,
        note: BlockRange,
        span: InlineRange,
        citation: CitationView,
    },
};

pub fn BlockPayload(comptime tag: BlockTag) type {
    const Content = @FieldType(BlockView, "content");
    return @FieldType(Content, @tagName(tag));
}

pub fn InlinePayload(comptime tag: InlineTag) type {
    const Content = @FieldType(InlineView, "content");
    return @FieldType(Content, @tagName(tag));
}

/// The descendant span of a container node: everything after it in its
/// subtree. Direct children are recovered by hopping.
fn descendants(comptime Index: type, index: u32, subtree_len: u32) ast.Range(Index) {
    assert(subtree_len >= 1);
    return ast.Range(Index).init(index + 1, subtree_len - 1);
}

pub fn blockView(store: *const Store, index: u32) BlockView {
    const slice = store.blocks.slice();
    assert(index < slice.len);
    const tag = slice.items(.tag)[index];
    const payload_index = slice.items(.payload)[index];
    const attrs = slice.items(.attrs)[index];
    const inlines = slice.items(.inlines)[index];
    const subtree_len = slice.items(.subtree_len)[index];

    const blocks = descendants(ast.BlockIndex, index, subtree_len);
    return .{ .attrs = attrs, .content = switch (tag) {
        .plain => .{ .plain = inlines },
        .paragraph => .{ .paragraph = inlines },
        .line_block => .{ .line_block = blocks },
        .heading => .{ .heading = .{
            .level = store.headings.items[payload_index].level,
            .inlines = inlines,
        } },
        .code_block => .{ .code_block = store.literals.items[payload_index] },
        .raw_block => .{ .raw_block = store.raws.items[payload_index] },
        .quote => .{ .quote = blocks },
        .list => blk: {
            const props = store.lists.items[payload_index];
            break :blk .{ .list = .{
                .kind = props.kind,
                .start = props.start,
                .style = props.style,
                .delimiter = props.delimiter,
                .items = blocks,
            } };
        },
        .definition_list => .{ .definition_list = blocks },
        .thematic_break => .thematic_break,
        .table => .{ .table = .{
            .columns = store.tables.items[payload_index].columns,
            .content = blocks,
        } },
        .figure => .{ .figure = blocks },
        .container => .{ .container = blocks },
        .line => .{ .line = inlines },
        .list_item => .{ .list_item = blocks },
        .definition_entry => .{ .definition_entry = blocks },
        .definition_term => .{ .definition_term = inlines },
        .definition_body => .{ .definition_body = blocks },
        .caption => .{ .caption = blocks },
        .table_head => .{ .table_head = blocks },
        .table_body => blk: {
            const props = store.table_bodies.items[payload_index];
            break :blk .{ .table_body = .{
                .row_head_columns = props.row_head_columns,
                .head_rows = props.head_rows,
                .rows = blocks,
            } };
        },
        .table_foot => .{ .table_foot = blocks },
        .table_row => .{ .table_row = blocks },
        .table_cell => blk: {
            const props = store.table_cells.items[payload_index];
            break :blk .{ .table_cell = .{
                .alignment = props.alignment,
                .row_span = props.row_span,
                .col_span = props.col_span,
                .blocks = blocks,
            } };
        },
    } };
}

pub fn inlineViewOf(store: *const Store, index: u32) InlineView {
    const slice = store.inlines.slice();
    assert(index < slice.len);
    const tag = slice.items(.tag)[index];
    const payload_index = slice.items(.payload)[index];
    const attrs = slice.items(.attrs)[index];
    const subtree_len = slice.items(.subtree_len)[index];

    const children = descendants(ast.InlineIndex, index, subtree_len);
    return .{ .attrs = attrs, .content = switch (tag) {
        .text => .{ .text = store.spans.items[payload_index] },
        .space => .space,
        .soft_break => .soft_break,
        .hard_break => .hard_break,
        .emphasis => .{ .emphasis = children },
        .underline => .{ .underline = children },
        .strong => .{ .strong = children },
        .strikethrough => .{ .strikethrough = children },
        .superscript => .{ .superscript = children },
        .subscript => .{ .subscript = children },
        .small_caps => .{ .small_caps = children },
        .quote => .{ .quote = .{
            .kind = @enumFromInt(payload_index),
            .children = children,
        } },
        .code => .{ .code = store.literals.items[payload_index] },
        .math => .{ .math = store.maths.items[payload_index] },
        .raw => .{ .raw = store.raws.items[payload_index] },
        .link => .{ .link = .{
            .url = store.targets.items[payload_index].url,
            .title = store.targets.items[payload_index].title,
            .children = children,
        } },
        .image => .{ .image = .{
            .url = store.targets.items[payload_index].url,
            .title = store.targets.items[payload_index].title,
            .children = children,
        } },
        .note => .{ .note = store.block_ranges.items[payload_index] },
        .span => .{ .span = children },
        .citation => .{ .citation = .{
            .citations = store.citation_ranges.items[payload_index],
            .children = children,
        } },
    } };
}

// ---------------------------------------------------------------- tests

test "every block tag has exactly one content kind" {
    inline for (@typeInfo(BlockTag).@"enum".fields) |field| {
        const tag: BlockTag = @enumFromInt(field.value);
        _ = blockContent(tag);
    }
}

test "structural tags are rejected at the root and accepted under parents" {
    try std.testing.expect(!blockPlacementAllowed(null, .list_item));
    try std.testing.expect(blockPlacementAllowed(.list, .list_item));
    try std.testing.expect(!blockPlacementAllowed(.list, .paragraph));
    try std.testing.expect(blockPlacementAllowed(.table_row, .table_cell));
    try std.testing.expect(!blockPlacementAllowed(.table, .table_row));
    try std.testing.expect(blockPlacementAllowed(null, .paragraph));
    try std.testing.expect(blockPlacementAllowed(.quote, .quote));
}

test "canonical order covers exactly the flag-derived containers" {
    // `link` leads because a link is outermost; the styles follow. Every
    // entry must be a container, and no entry may repeat.
    for (canonical_inline_order, 0..) |tag, i| {
        try std.testing.expect(inlineHasChildren(tag));
        for (canonical_inline_order[i + 1 ..]) |later| {
            try std.testing.expect(tag != later);
        }
    }
}
