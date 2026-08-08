//! Typed payloads and views over the node schema (ZDS 0013, The Semantic
//! Kernel).
//!
//! The `payload` column of a stored node is an index into a typed side table
//! selected by the tag, reached only through the views here. The facts about
//! tags — content kind, placement, payload kind — live in one comptime table
//! in `schema.zig`; this file re-exports the derived predicates, implements
//! payload validation against the store, and constructs the typed views. A
//! new tag is one schema row plus compile errors in every exhaustive switch.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const schema = @import("schema.zig");

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
    /// Index into `Store.resources`, or `no_resource` for an external link.
    resource: u32 = no_resource,
};

pub const no_resource = std.math.maxInt(u32);

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

pub const Extension = struct {
    /// Reverse-DNS owner, the same namespace discipline as plugin ids;
    /// interned in the text pool.
    owner: ByteRange,
    /// Extension name within the owner's namespace.
    name: ByteRange,
    /// Schema version of the extension's meaning.
    version: u32,
};

// -------------------------------------------------------------- schema

pub const ContentKind = schema.ContentKind;

pub fn blockContent(tag: BlockTag) ContentKind {
    return schema.blockContent(tag);
}

/// Child tags appear only under their parent tag. `null` is a forest root:
/// the body, a note's blocks, or a metadata block value.
pub fn blockPlacementAllowed(parent: ?BlockTag, child: BlockTag) bool {
    return schema.blockPlacementAllowed(parent, child);
}

pub fn inlineHasChildren(tag: InlineTag) bool {
    return schema.inlineHasChildren(tag);
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
    return payloadKindValid(store, schema.blockRowOf(tag).payload, index);
}

pub fn inlinePayloadValid(store: *const Store, tag: InlineTag, index: u32) bool {
    return payloadKindValid(store, schema.inlineRowOf(tag).payload, index);
}

/// One validity rule per payload kind, driven by the schema row, so the
/// builder, the validator, and the views can never disagree about what a
/// tag's payload column means.
fn payloadKindValid(store: *const Store, kind: schema.PayloadKind, index: u32) bool {
    switch (kind) {
        .none => return index == 0,
        .heading => {
            if (index >= store.headings.items.len) return false;
            const heading = store.headings.items[index];
            return heading.level >= 1 and heading.level <= 6;
        },
        .list => return index < store.lists.items.len,
        .literal => return index < store.literals.items.len and
            byteRangeValid(store, store.literals.items[index]),
        .raw => return index < store.raws.items.len and
            rawValid(store, store.raws.items[index]),
        .table => {
            if (index >= store.tables.items.len) return false;
            const table = store.tables.items[index];
            return table.columns.start + table.columns.len <= store.columns.items.len;
        },
        .table_body => return index < store.table_bodies.items.len,
        .table_cell => return index < store.table_cells.items.len,
        .span => return index < store.spans.items.len and
            byteRangeValid(store, store.spans.items[index]),
        .math => return index < store.maths.items.len and
            byteRangeValid(store, store.maths.items[index].text),
        .target => return index < store.targets.items.len and
            byteRangeValid(store, store.targets.items[index].url) and
            byteRangeValid(store, store.targets.items[index].title),
        .note_blocks => return index < store.block_ranges.items.len,
        .citation => {
            if (index >= store.citation_ranges.items.len) return false;
            const range = store.citation_ranges.items[index];
            return range.start + range.len <= store.citations.items.len;
        },
        .quote_kind => return index <= @intFromEnum(QuoteKind.double),
        .extension => {
            if (index >= store.extensions.items.len) return false;
            const extension = store.extensions.items[index];
            return byteRangeValid(store, extension.owner) and
                extension.owner.len > 0 and
                byteRangeValid(store, extension.name) and
                extension.name.len > 0;
        },
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
    resource: u32,
    children: InlineRange,
};

pub const CitationView = struct {
    citations: CitationRange,
    children: InlineRange,
};

pub const ExtensionBlockView = struct {
    owner: ByteRange,
    name: ByteRange,
    version: u32,
    /// The mandatory source-neutral fallback subtree.
    fallback: BlockRange,
};

pub const ExtensionInlineView = struct {
    owner: ByteRange,
    name: ByteRange,
    version: u32,
    fallback: InlineRange,
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
        extension: ExtensionBlockView,
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
        extension: ExtensionInlineView,
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
        .extension => blk: {
            const extension = store.extensions.items[payload_index];
            break :blk .{ .extension = .{
                .owner = extension.owner,
                .name = extension.name,
                .version = extension.version,
                .fallback = blocks,
            } };
        },
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
            .resource = no_resource,
            .children = children,
        } },
        .image => .{ .image = .{
            .url = store.targets.items[payload_index].url,
            .title = store.targets.items[payload_index].title,
            .resource = store.targets.items[payload_index].resource,
            .children = children,
        } },
        .note => .{ .note = store.block_ranges.items[payload_index] },
        .span => .{ .span = children },
        .citation => .{ .citation = .{
            .citations = store.citation_ranges.items[payload_index],
            .children = children,
        } },
        .extension => blk: {
            const extension = store.extensions.items[payload_index];
            break :blk .{ .extension = .{
                .owner = extension.owner,
                .name = extension.name,
                .version = extension.version,
                .fallback = children,
            } };
        },
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
