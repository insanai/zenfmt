//! The document AST (ZDS 0002, The Document AST).
//!
//! Public semantics and physical storage are deliberately separate. The
//! public model is a tree: blocks nest, inlines nest, and every node may
//! carry attributes. The storage is flat preorder struct-of-arrays in one
//! arena: two `std.MultiArrayList` node arrays, a text pool, and append-only
//! side tables, with typed `u32` indices for every edge. Each node records
//! its subtree *length* (including itself), so children are found by hopping
//! and a same-kind subtree can be bulk-copied without rebasing.
//!
//! Plugins and filters see `BlockView` and `InlineView` tagged unions from
//! `payload.zig`; the raw `payload` column and the side-table layout are not
//! public API.

const std = @import("std");
const assert = std.debug.assert;
const payload = @import("payload.zig");
const facets = @import("facets.zig");
const resources_mod = @import("resources.zig");
const metadata = @import("metadata.zig");
const limits_mod = @import("limits.zig");

pub const BlockTag = enum(u8) {
    // Public tags: what `Document.block` returns for body content.
    plain,
    paragraph,
    line_block,
    heading,
    code_block,
    raw_block,
    quote,
    list,
    definition_list,
    thematic_break,
    table,
    figure,
    container,
    /// A namespaced plugin construct (ZDS 0013, Extension Nodes). Children
    /// are the mandatory source-neutral fallback subtree.
    extension,

    // Private normalized structure; appears only under its parent tag.
    line,
    list_item,
    definition_entry,
    definition_term,
    definition_body,
    caption,
    table_head,
    table_body,
    table_foot,
    table_row,
    table_cell,

    pub const first_structural: BlockTag = .line;

    pub fn isStructural(tag: BlockTag) bool {
        return @intFromEnum(tag) >= @intFromEnum(first_structural);
    }
};

pub const InlineTag = enum(u8) {
    text,
    space,
    soft_break,
    hard_break,
    emphasis,
    underline,
    strong,
    strikethrough,
    superscript,
    subscript,
    small_caps,
    quote,
    code,
    math,
    raw,
    link,
    image,
    note,
    span,
    citation,
    /// A namespaced plugin construct; children are the fallback inlines.
    extension,
};

// ------------------------------------------------------------- indices

pub const BlockIndex = enum(u32) {
    _,

    pub fn raw(index: BlockIndex) u32 {
        return @intFromEnum(index);
    }
};

pub const InlineIndex = enum(u32) {
    _,

    pub fn raw(index: InlineIndex) u32 {
        return @intFromEnum(index);
    }
};

pub const AttrsIndex = enum(u32) { _ };

pub const OptionalAttrsIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(index: OptionalAttrsIndex) ?AttrsIndex {
        if (index == .none) return null;
        return @enumFromInt(@intFromEnum(index));
    }

    pub fn from(index: AttrsIndex) OptionalAttrsIndex {
        const value: OptionalAttrsIndex = @enumFromInt(@intFromEnum(index));
        assert(value != .none);
        return value;
    }
};

pub const NodeIndex = union(enum) {
    block: BlockIndex,
    // `inline` is a Zig keyword; the escaped identifier is the field name.
    @"inline": InlineIndex,
};

/// Stable logical identity shared by a kernel node and its facets (ZDS
/// 0013, Entities). Assigned lazily, on first facet attachment; a document
/// with no facets has no entities and pays nothing.
pub const EntityId = enum(u32) {
    _,

    pub fn raw(id: EntityId) u32 {
        return @intFromEnum(id);
    }
};

/// One row of the entity side table: a node index bound to an entity. Rows
/// live outside the node arrays, ordered by node index within a snapshot's
/// range, so binding costs nothing per node and lookup is a binary search.
pub const EntityRow = struct {
    node: u32,
    entity: EntityId,
};

/// Four-byte entry in the entity-to-node index. The high bit distinguishes
/// the two entity-row tables; the remaining bits address an absolute row.
/// `max_nodes` keeps both tables far below this representation's ceiling.
pub const EntityReference = enum(u32) {
    _,

    const inline_bit: u32 = @as(u32, 1) << 31;
    const row_mask: u32 = inline_bit - 1;

    pub fn block(row_index: u32) EntityReference {
        assert(row_index <= row_mask);
        return @enumFromInt(row_index);
    }

    pub fn inlineRef(row_index: u32) EntityReference {
        assert(row_index <= row_mask);
        return @enumFromInt(row_index | inline_bit);
    }

    pub fn isInline(reference: EntityReference) bool {
        return @intFromEnum(reference) & inline_bit != 0;
    }

    pub fn row(reference: EntityReference) u32 {
        return @intFromEnum(reference) & row_mask;
    }
};

/// A snapshot's slice of an entity row table. Like `Document.body`, the
/// range is what makes snapshots over one shared store possible: the
/// rebuild transform appends rebased rows and hands the new snapshot its
/// own range (ZDS 0013, Lemma 2).
pub const EntityRange = struct {
    start: u32,
    len: u32,

    pub const empty: EntityRange = .{ .start = 0, .len = 0 };

    pub fn end(range: EntityRange) u32 {
        return range.start + range.len;
    }
};

pub fn Range(comptime Index: type) type {
    return struct {
        start: Index,
        len: u32,

        const Self = @This();

        pub const empty: Self = .{ .start = @enumFromInt(0), .len = 0 };

        pub fn init(start: u32, len: u32) Self {
            assert(len <= std.math.maxInt(u32) - start);
            return .{ .start = @enumFromInt(start), .len = len };
        }

        pub fn startRaw(range: Self) u32 {
            return @intFromEnum(range.start);
        }

        pub fn endRaw(range: Self) u32 {
            assert(range.len <= std.math.maxInt(u32) - range.startRaw());
            return range.startRaw() + range.len;
        }

        pub fn isEmpty(range: Self) bool {
            return range.len == 0;
        }
    };
}

pub const BlockRange = Range(BlockIndex);
pub const InlineRange = Range(InlineIndex);

/// A slice of the text pool: 8 bytes, and it never dangles because the pool
/// is append-only for the life of the conversion.
pub const ByteRange = struct {
    start: u32,
    len: u32,

    pub const empty: ByteRange = .{ .start = 0, .len = 0 };

    pub fn end(range: ByteRange) u32 {
        assert(range.len <= std.math.maxInt(u32) - range.start);
        return range.start + range.len;
    }
};

/// A run of rows in `Store.strings` (each row a `ByteRange`).
pub const StringRange = struct {
    start: u32,
    len: u32,

    pub const empty: StringRange = .{ .start = 0, .len = 0 };
};

/// A run of rows in `Store.pairs`.
pub const PairRange = struct {
    start: u32,
    len: u32,

    pub const empty: PairRange = .{ .start = 0, .len = 0 };
};

/// A run of rows in `Store.plugin_namespaces`.
pub const PluginDataRange = struct {
    start: u32,
    len: u32,

    pub const empty: PluginDataRange = .{ .start = 0, .len = 0 };
};

// ---------------------------------------------------------- attributes

/// An identifier, a class list, and ordered key-value pairs. Every block and
/// inline may carry one; `code_block` keeps its language as the first class,
/// `container` and `span` keep their roles here.
pub const Attrs = struct {
    id: ByteRange,
    classes: StringRange,
    pairs: PairRange,

    pub const none: Attrs = .{
        .id = .empty,
        .classes = .empty,
        .pairs = .empty,
    };
};

pub const Pair = struct {
    key: ByteRange,
    value: ByteRange,
};

// ------------------------------------------------------------- storage

/// One block node as stored. The five columns total 21 bytes before any
/// tag-specific payload-table data; `payload` is an index into the table
/// selected by `tag` and is never read directly by public API users.
pub const Block = struct {
    tag: BlockTag,
    payload: u32,
    attrs: OptionalAttrsIndex,
    /// Inline children for inline-content tags; `.empty` otherwise.
    inlines: InlineRange,
    /// Nodes in this subtree, including this node. A leaf has length 1.
    subtree_len: u32,
};

/// One inline node as stored: 13 bytes of columns.
pub const Inline = struct {
    tag: InlineTag,
    payload: u32,
    attrs: OptionalAttrsIndex,
    subtree_len: u32,
};

/// One namespaced plugin-data value carried through a conversion. The engine
/// stores and re-encodes it; only the owning plugin interprets `json`.
pub const PluginNamespace = struct {
    /// Reverse-DNS plugin id, in the text pool.
    id: ByteRange,
    version: u32,
    /// Canonical JSON, in the raw pool.
    json: ByteRange,
};

/// The conversion's append-only backing store. Filters append snapshots;
/// nothing is ever mutated or removed, so every index handed out stays valid
/// until the conversion arena is released.
pub const Store = struct {
    blocks: std.MultiArrayList(Block) = .empty,
    inlines: std.MultiArrayList(Inline) = .empty,
    /// All document text, decoded and UTF-8.
    text: std.ArrayList(u8) = .empty,
    /// Carried plugin-data JSON; not document text.
    raw: std.ArrayList(u8) = .empty,
    attrs: std.ArrayList(Attrs) = .empty,
    strings: std.ArrayList(ByteRange) = .empty,
    pairs: std.ArrayList(Pair) = .empty,
    /// Payload table for `text` inlines.
    spans: std.ArrayList(ByteRange) = .empty,
    /// Payload table for `code_block`, `code`.
    literals: std.ArrayList(ByteRange) = .empty,
    raws: std.ArrayList(payload.Raw) = .empty,
    maths: std.ArrayList(payload.Math) = .empty,
    headings: std.ArrayList(payload.Heading) = .empty,
    lists: std.ArrayList(payload.ListProps) = .empty,
    tables: std.ArrayList(payload.TableProps) = .empty,
    table_bodies: std.ArrayList(payload.TableBodyProps) = .empty,
    table_cells: std.ArrayList(payload.TableCellProps) = .empty,
    columns: std.ArrayList(payload.ColumnSpec) = .empty,
    targets: std.ArrayList(payload.Target) = .empty,
    citations: std.ArrayList(payload.Citation) = .empty,
    citation_ranges: std.ArrayList(payload.CitationRange) = .empty,
    /// Payload table for `note` inlines and `blocks` metadata values: each
    /// row names a block forest outside `body`.
    block_ranges: std.ArrayList(BlockRange) = .empty,
    /// Payload table for `inlines` metadata values.
    inline_ranges: std.ArrayList(InlineRange) = .empty,
    /// Payload table for `extension` blocks and inlines.
    extensions: std.ArrayList(payload.Extension) = .empty,
    /// Entity bindings for blocks and inlines (ZDS 0013, Entities). Nodes
    /// carry no entity column; snapshots own ranges of these rows.
    block_entities: std.ArrayList(EntityRow) = .empty,
    inline_entities: std.ArrayList(EntityRow) = .empty,
    /// References into the two tables above, sorted by `EntityId` within a
    /// document snapshot. This is the reverse index promised by ZDS 0013.
    entity_index: std.ArrayList(EntityReference) = .empty,
    /// The five facet tables, sorted by entity (ZDS 0013, Sparse Facets).
    provenance_facets: std.ArrayList(facets.Provenance) = .empty,
    style_facets: std.ArrayList(facets.Style) = .empty,
    style_properties: std.ArrayList(facets.StyleProperty) = .empty,
    layout_facets: std.ArrayList(facets.Layout) = .empty,
    grid_facets: std.ArrayList(facets.Grid) = .empty,
    revision_facets: std.ArrayList(facets.Revision) = .empty,
    /// The resource store (ZDS 0013): extracted binary content, digested
    /// at registration.
    resources: std.ArrayList(resources_mod.Resource) = .empty,
    /// Resource content bytes; binary, kept out of the UTF-8 text pool.
    resource_bytes: std.ArrayList(u8) = .empty,
    meta_values: std.ArrayList(metadata.MetaValue) = .empty,
    meta_entries: std.ArrayList(metadata.MetaEntry) = .empty,
    meta_maps: std.ArrayList(metadata.MetaEntryRange) = .empty,
    meta_lists: std.ArrayList(metadata.MetaItemRange) = .empty,
    meta_items: std.ArrayList(metadata.MetaValueIndex) = .empty,
    meta_ints: std.ArrayList(i64) = .empty,
    meta_floats: std.ArrayList(f64) = .empty,
    plugin_namespaces: std.ArrayList(PluginNamespace) = .empty,

    pub fn deinit(store: *Store, gpa: std.mem.Allocator) void {
        inline for (@typeInfo(Store).@"struct".fields) |field| {
            @field(store, field.name).deinit(gpa);
        }
        store.* = undefined;
    }

    pub fn textSlice(store: *const Store, range: ByteRange) []const u8 {
        assert(range.end() <= store.text.items.len);
        return store.text.items[range.start..range.end()];
    }
};

// ------------------------------------------------------------ document

/// A cheap snapshot into the store: ranges and metadata roots. Earlier
/// snapshots remain valid while filters append later ones.
pub const Document = struct {
    store: *const Store,
    body: BlockRange,
    meta: metadata.MetaMapIndex,
    plugin_data: PluginDataRange,
    /// This snapshot's entity bindings; empty when nothing carries facets.
    block_entities: EntityRange = .empty,
    inline_entities: EntityRange = .empty,
    /// Reverse index over both entity-row ranges, sorted by `EntityId`.
    entity_index: EntityRange = .empty,

    pub fn block(doc: *const Document, index: BlockIndex) payload.BlockView {
        return payload.blockView(doc.store, index.raw());
    }

    pub fn blockAs(
        doc: *const Document,
        index: BlockIndex,
        comptime tag: BlockTag,
    ) ?payload.BlockPayload(tag) {
        const tags = doc.store.blocks.items(.tag);
        assert(index.raw() < tags.len);
        if (tags[index.raw()] != tag) return null;
        return @field(doc.block(index).content, @tagName(tag));
    }

    pub fn inlineView(doc: *const Document, index: InlineIndex) payload.InlineView {
        return payload.inlineViewOf(doc.store, index.raw());
    }

    pub fn inlineAs(
        doc: *const Document,
        index: InlineIndex,
        comptime tag: InlineTag,
    ) ?payload.InlinePayload(tag) {
        const tags = doc.store.inlines.items(.tag);
        assert(index.raw() < tags.len);
        if (tags[index.raw()] != tag) return null;
        return @field(doc.inlineView(index).content, @tagName(tag));
    }

    pub fn text(doc: *const Document, range: ByteRange) []const u8 {
        return doc.store.textSlice(range);
    }

    pub fn blockTag(doc: *const Document, index: BlockIndex) BlockTag {
        const tags = doc.store.blocks.items(.tag);
        assert(index.raw() < tags.len);
        return tags[index.raw()];
    }

    pub fn inlineTag(doc: *const Document, index: InlineIndex) InlineTag {
        const tags = doc.store.inlines.items(.tag);
        assert(index.raw() < tags.len);
        return tags[index.raw()];
    }

    pub fn attrsOf(doc: *const Document, index: OptionalAttrsIndex) Attrs {
        const attrs_index = index.unwrap() orelse return .none;
        assert(@intFromEnum(attrs_index) < doc.store.attrs.items.len);
        return doc.store.attrs.items[@intFromEnum(attrs_index)];
    }

    /// Direct children of a container block, by subtree hopping.
    pub fn blockChildren(doc: *const Document, index: BlockIndex) ChildIterator(BlockIndex) {
        return childIterator(BlockIndex, doc.store.blocks.items(.subtree_len), index.raw());
    }

    pub fn inlineChildren(doc: *const Document, index: InlineIndex) ChildIterator(InlineIndex) {
        return childIterator(InlineIndex, doc.store.inlines.items(.subtree_len), index.raw());
    }

    /// The roots of a forest range, by subtree hopping.
    pub fn blockRoots(doc: *const Document, range: BlockRange) ChildIterator(BlockIndex) {
        return rootIterator(
            BlockIndex,
            doc.store.blocks.items(.subtree_len),
            range.startRaw(),
            range.endRaw(),
        );
    }

    pub fn inlineRoots(doc: *const Document, range: InlineRange) ChildIterator(InlineIndex) {
        return rootIterator(
            InlineIndex,
            doc.store.inlines.items(.subtree_len),
            range.startRaw(),
            range.endRaw(),
        );
    }

    pub fn metaValue(doc: *const Document, index: metadata.MetaValueIndex) metadata.MetaView {
        const values = doc.store.meta_values.items;
        assert(@intFromEnum(index) < values.len);
        const value = values[@intFromEnum(index)];
        return switch (value.tag) {
            .null => .null,
            .boolean => .{ .boolean = value.payload != 0 },
            .integer => .{ .integer = doc.store.meta_ints.items[value.payload] },
            .float => .{ .float = doc.store.meta_floats.items[value.payload] },
            .string => .{ .string = doc.store.spans.items[value.payload] },
            .inlines => .{ .inlines = doc.store.inline_ranges.items[value.payload] },
            .blocks => .{ .blocks = doc.store.block_ranges.items[value.payload] },
            .map => .{ .map = @enumFromInt(value.payload) },
            .list => .{ .list = doc.store.meta_lists.items[value.payload] },
        };
    }

    pub fn metaEntries(
        doc: *const Document,
        map: metadata.MetaMapIndex,
    ) []const metadata.MetaEntry {
        const maps = doc.store.meta_maps.items;
        assert(@intFromEnum(map) < maps.len);
        const range = maps[@intFromEnum(map)];
        assert(range.start + range.len <= doc.store.meta_entries.items.len);
        return doc.store.meta_entries.items[range.start .. range.start + range.len];
    }

    pub fn pluginNamespaces(doc: *const Document) []const PluginNamespace {
        const range = doc.plugin_data;
        assert(range.start + range.len <= doc.store.plugin_namespaces.items.len);
        return doc.store.plugin_namespaces.items[range.start .. range.start + range.len];
    }

    // ---------------------------------------------------- entities, facets

    /// The entity bound to a block, when one exists. Binary search over
    /// this snapshot's rows: no per-node cost when nothing carries facets.
    pub fn blockEntity(doc: *const Document, index: BlockIndex) ?EntityId {
        return entityLookup(doc.store.block_entities.items, doc.block_entities, index.raw());
    }

    pub fn inlineEntity(doc: *const Document, index: InlineIndex) ?EntityId {
        return entityLookup(doc.store.inline_entities.items, doc.inline_entities, index.raw());
    }

    pub fn entityNode(doc: *const Document, entity: EntityId) ?NodeIndex {
        const store = doc.store;
        const end = doc.entity_index.end();
        assert(end <= store.entity_index.items.len);
        var low: usize = doc.entity_index.start;
        var high: usize = end;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const reference = store.entity_index.items[middle];
            const row = entityRow(store, reference);
            if (row.entity == entity) return entityNodeFrom(reference, row.node);
            if (row.entity.raw() < entity.raw()) low = middle + 1 else high = middle;
        }
        return null;
    }

    pub fn provenanceOf(doc: *const Document, entity: EntityId) ?facets.Provenance {
        return facets.find(facets.Provenance, doc.store.provenance_facets.items, entity);
    }

    pub fn styleOf(doc: *const Document, entity: EntityId) ?facets.Style {
        return facets.find(facets.Style, doc.store.style_facets.items, entity);
    }

    pub fn layoutOf(doc: *const Document, entity: EntityId) ?facets.Layout {
        return facets.find(facets.Layout, doc.store.layout_facets.items, entity);
    }

    pub fn gridOf(doc: *const Document, entity: EntityId) ?facets.Grid {
        return facets.find(facets.Grid, doc.store.grid_facets.items, entity);
    }

    pub fn revisionsOf(doc: *const Document, entity: EntityId) []const facets.Revision {
        return facets.findAll(facets.Revision, doc.store.revision_facets.items, entity);
    }
};

fn entityLookup(rows: []const EntityRow, range: EntityRange, node: u32) ?EntityId {
    assert(range.end() <= rows.len);
    const window = rows[range.start..range.end()];
    var lo: usize = 0;
    var hi: usize = window.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (window[mid].node == node) return window[mid].entity;
        if (window[mid].node < node) lo = mid + 1 else hi = mid;
    }
    return null;
}

pub fn appendEntityIndex(
    gpa: std.mem.Allocator,
    store: *Store,
    blocks: EntityRange,
    inlines: EntityRange,
) error{OutOfMemory}!EntityRange {
    assert(blocks.end() <= store.block_entities.items.len);
    assert(inlines.end() <= store.inline_entities.items.len);
    const start: u32 = @intCast(store.entity_index.items.len);
    for (blocks.start..blocks.end()) |row| {
        try store.entity_index.append(gpa, .block(@intCast(row)));
    }
    for (inlines.start..inlines.end()) |row| {
        try store.entity_index.append(gpa, .inlineRef(@intCast(row)));
    }
    const appended = store.entity_index.items[start..];
    std.mem.sort(EntityReference, appended, store, entityReferenceLessThan);
    assert(appended.len == blocks.len + inlines.len);
    return .{ .start = start, .len = @intCast(appended.len) };
}

fn entityReferenceLessThan(
    store: *Store,
    lhs: EntityReference,
    rhs: EntityReference,
) bool {
    return entityRow(store, lhs).entity.raw() < entityRow(store, rhs).entity.raw();
}

fn entityRow(store: *const Store, reference: EntityReference) EntityRow {
    const row = reference.row();
    return if (reference.isInline())
        store.inline_entities.items[row]
    else
        store.block_entities.items[row];
}

fn entityNodeFrom(reference: EntityReference, node: u32) NodeIndex {
    return if (reference.isInline())
        .{ .@"inline" = @enumFromInt(node) }
    else
        .{ .block = @enumFromInt(node) };
}

// ----------------------------------------------------------- traversal

/// Hops across a node's direct children: start one past the parent, and from
/// each child add its `subtree_len`, stopping at the parent's subtree end.
/// There is no child list to allocate and no parent pointer to maintain.
pub fn ChildIterator(comptime Index: type) type {
    return struct {
        lengths: []const u32,
        cursor: u32,
        bound: u32,

        const Self = @This();

        pub fn next(it: *Self) ?Index {
            assert(it.cursor <= it.bound);
            if (it.cursor == it.bound) return null;
            const index = it.cursor;
            assert(it.lengths[index] >= 1);
            it.cursor += it.lengths[index];
            assert(it.cursor > index);
            return @enumFromInt(index);
        }
    };
}

fn childIterator(comptime Index: type, lengths: []const u32, parent: u32) ChildIterator(Index) {
    assert(parent < lengths.len);
    assert(lengths[parent] >= 1);
    return .{
        .lengths = lengths,
        .cursor = parent + 1,
        .bound = parent + lengths[parent],
    };
}

fn rootIterator(
    comptime Index: type,
    lengths: []const u32,
    start: u32,
    end: u32,
) ChildIterator(Index) {
    assert(start <= end);
    assert(end <= lengths.len);
    return .{ .lengths = lengths, .cursor = start, .bound = end };
}

// ----------------------------------------------------------- validator

pub const ValidateError = error{InvalidDocument};

/// The oracle (ZDS 0002, Invariants): checks every structural invariant of a
/// `Document`. Runs on every conversion in `Debug` and `ReleaseSafe`, after
/// every filter stage, in every test, and on every fuzz iteration. A plugin
/// that produces a structurally impossible tree fails here even when nothing
/// crashes.
pub fn validate(doc: *const Document, limits: limits_mod.Limits) ValidateError!void {
    const store = doc.store;
    if (!std.unicode.utf8ValidateSlice(store.text.items)) return error.InvalidDocument;
    if (store.text.items.len > limits.max_decoded_text_bytes) return error.InvalidDocument;
    if (store.blocks.len + store.inlines.len > limits.max_nodes) return error.InvalidDocument;

    const block_count: u32 = @intCast(store.blocks.len);
    if (doc.body.endRaw() > block_count) return error.InvalidDocument;
    try validateBlockForest(store, doc.body, limits);

    // Every note payload and metadata blocks value names a valid block
    // forest of its own.
    for (store.block_ranges.items) |range| {
        if (range.endRaw() > block_count) return error.InvalidDocument;
        try validateBlockForest(store, range, limits);
    }

    const map_count = store.meta_maps.items.len;
    if (@intFromEnum(doc.meta) >= map_count) return error.InvalidDocument;
    const plugin_count = store.plugin_namespaces.items.len;
    if (doc.plugin_data.start + doc.plugin_data.len > plugin_count) return error.InvalidDocument;

    try @import("ast_side_validation.zig").validate(doc, limits);
}

const BlockFrame = struct {
    end: u32,
    tag: BlockTag,
    /// Payload index when `tag == .extension`, so owner clashes among open
    /// extension ancestors are detectable; unused otherwise.
    extension_payload: u32,
};

fn validateBlockForest(
    store: *const Store,
    range: BlockRange,
    limits: limits_mod.Limits,
) ValidateError!void {
    const slice = store.blocks.slice();
    const tags = slice.items(.tag);
    const lengths = slice.items(.subtree_len);
    const payloads = slice.items(.payload);
    const attrs_column = slice.items(.attrs);
    const inline_ranges = slice.items(.inlines);

    var stack: [limits_mod.max_depth_hard_cap]BlockFrame = undefined;
    var depth: u32 = 0;
    var cursor = range.startRaw();
    const end = range.endRaw();
    assert(end <= store.blocks.len);
    assert(limits.max_depth <= limits_mod.max_depth_hard_cap);

    while (cursor < end) {
        while (depth > 0 and stack[depth - 1].end == cursor) depth -= 1;
        const parent: ?*BlockFrame = if (depth > 0) &stack[depth - 1] else null;

        const tag = tags[cursor];
        const subtree_len = lengths[cursor];
        if (subtree_len < 1) return error.InvalidDocument;
        const bound = if (parent) |frame| frame.end else end;
        if (cursor + subtree_len > bound) return error.InvalidDocument;

        const parent_tag: ?BlockTag = if (parent) |frame| frame.tag else null;
        if (!payload.blockPlacementAllowed(parent_tag, tag)) return error.InvalidDocument;

        try validateBlockNode(
            store,
            tag,
            payloads[cursor],
            attrs_column[cursor],
            inline_ranges[cursor],
            limits,
        );

        try validateBlockExtension(
            store,
            tag,
            payloads[cursor],
            subtree_len,
            stack[0..depth],
        );

        try advanceBlock(
            &stack,
            &depth,
            &cursor,
            tag,
            payloads[cursor],
            subtree_len,
            limits.max_depth,
        );
    }
    if (cursor != end) return error.InvalidDocument;
}

fn advanceBlock(
    stack: *[limits_mod.max_depth_hard_cap]BlockFrame,
    depth: *u32,
    cursor: *u32,
    tag: BlockTag,
    payload_index: u32,
    subtree_len: u32,
    max_depth: u32,
) ValidateError!void {
    switch (payload.blockContent(tag)) {
        .blocks => {
            if (subtree_len == 1) {
                cursor.* += 1;
                return;
            }
            if (depth.* >= max_depth) return error.InvalidDocument;
            stack[depth.*] = .{
                .end = cursor.* + subtree_len,
                .tag = tag,
                .extension_payload = payload_index,
            };
            depth.* += 1;
            cursor.* += 1;
        },
        .inlines, .none => {
            if (subtree_len != 1) return error.InvalidDocument;
            cursor.* += 1;
        },
    }
}

fn validateBlockExtension(
    store: *const Store,
    tag: BlockTag,
    payload_index: u32,
    subtree_len: u32,
    ancestors: []const BlockFrame,
) ValidateError!void {
    if (tag != .extension) return;
    // The fallback subtree is mandatory. An extension may not nest inside
    // an open extension owned by the same plugin namespace.
    if (subtree_len < 2) return error.InvalidDocument;
    const owner = store.extensions.items[payload_index].owner;
    for (ancestors) |frame| {
        if (frame.tag != .extension) continue;
        const open = store.extensions.items[frame.extension_payload].owner;
        if (std.mem.eql(u8, store.textSlice(open), store.textSlice(owner))) {
            return error.InvalidDocument;
        }
    }
}

fn validateBlockNode(
    store: *const Store,
    tag: BlockTag,
    payload_index: u32,
    attrs_index: OptionalAttrsIndex,
    inlines: InlineRange,
    limits: limits_mod.Limits,
) ValidateError!void {
    try validateAttrs(store, attrs_index);
    if (!payload.blockPayloadValid(store, tag, payload_index)) return error.InvalidDocument;
    switch (payload.blockContent(tag)) {
        .inlines => {
            if (inlines.endRaw() > store.inlines.len) return error.InvalidDocument;
            try validateInlineForest(store, inlines, limits);
        },
        .blocks, .none => {
            if (!inlines.isEmpty()) return error.InvalidDocument;
        },
    }
}

const InlineFrame = struct {
    end: u32,
    previous_child: ?InlineTag,
    /// Payload index when the open container is an `extension`; sentinel
    /// `maxInt` otherwise.
    extension_payload: u32,
};

const no_extension = std.math.maxInt(u32);

fn validateInlineForest(
    store: *const Store,
    range: InlineRange,
    limits: limits_mod.Limits,
) ValidateError!void {
    const slice = store.inlines.slice();
    const tags = slice.items(.tag);
    const lengths = slice.items(.subtree_len);
    const payloads = slice.items(.payload);
    const attrs_column = slice.items(.attrs);

    var stack: [limits_mod.max_depth_hard_cap]InlineFrame = undefined;
    var depth: u32 = 0;
    var cursor = range.startRaw();
    const end = range.endRaw();
    assert(end <= store.inlines.len);
    assert(limits.max_depth <= limits_mod.max_depth_hard_cap);

    var previous_root: ?InlineTag = null;
    while (cursor < end) {
        while (depth > 0 and stack[depth - 1].end == cursor) depth -= 1;
        const parent: ?*InlineFrame = if (depth > 0) &stack[depth - 1] else null;

        const tag = tags[cursor];
        const subtree_len = lengths[cursor];
        if (subtree_len < 1) return error.InvalidDocument;
        const bound = if (parent) |frame| frame.end else end;
        if (cursor + subtree_len > bound) return error.InvalidDocument;

        // No two adjacent siblings are both `text`; readers coalesce.
        const previous = if (parent) |frame| frame.previous_child else previous_root;
        if (tag == .text and previous == .text) return error.InvalidDocument;
        if (parent) |frame| {
            frame.previous_child = tag;
        } else {
            previous_root = tag;
        }

        try validateInlineNode(
            store,
            tag,
            payloads[cursor],
            attrs_column[cursor],
        );
        try validateInlineExtension(
            store,
            tag,
            payloads[cursor],
            subtree_len,
            stack[0..depth],
        );

        if (payload.inlineHasChildren(tag) and subtree_len > 1) {
            if (depth >= limits.max_depth) return error.InvalidDocument;
            stack[depth] = .{
                .end = cursor + subtree_len,
                .previous_child = null,
                .extension_payload = if (tag == .extension) payloads[cursor] else no_extension,
            };
            depth += 1;
            cursor += 1;
        } else {
            if (!payload.inlineHasChildren(tag) and subtree_len != 1) return error.InvalidDocument;
            cursor += subtree_len;
        }
    }
    if (cursor != end) return error.InvalidDocument;
}

fn validateInlineNode(
    store: *const Store,
    tag: InlineTag,
    payload_index: u32,
    attrs_index: OptionalAttrsIndex,
) ValidateError!void {
    try validateAttrs(store, attrs_index);
    if (!payload.inlinePayloadValid(store, tag, payload_index)) {
        return error.InvalidDocument;
    }
    if (tag == .image or tag == .link) {
        const target = store.targets.items[payload_index];
        if (tag == .link and target.resource != payload.no_resource) {
            return error.InvalidDocument;
        }
        if (target.resource != payload.no_resource and
            target.resource >= store.resources.items.len)
        {
            return error.InvalidDocument;
        }
    }
    if (tag != .text) return;
    const span = store.spans.items[payload_index];
    if (span.end() > store.text.items.len) return error.InvalidDocument;
    for (store.textSlice(span)) |byte| switch (byte) {
        ' ', '\t', '\n', '\r' => return error.InvalidDocument,
        else => {},
    };
}

fn validateInlineExtension(
    store: *const Store,
    tag: InlineTag,
    payload_index: u32,
    subtree_len: u32,
    ancestors: []const InlineFrame,
) ValidateError!void {
    if (tag != .extension) return;
    if (subtree_len < 2) return error.InvalidDocument;
    const owner = store.extensions.items[payload_index].owner;
    for (ancestors) |frame| {
        if (frame.extension_payload == no_extension) continue;
        const open = store.extensions.items[frame.extension_payload].owner;
        if (std.mem.eql(u8, store.textSlice(open), store.textSlice(owner))) {
            return error.InvalidDocument;
        }
    }
}

fn validateAttrs(store: *const Store, index: OptionalAttrsIndex) ValidateError!void {
    const attrs_index = index.unwrap() orelse return;
    if (@intFromEnum(attrs_index) >= store.attrs.items.len) return error.InvalidDocument;
    const attrs = store.attrs.items[@intFromEnum(attrs_index)];
    if (attrs.id.end() > store.text.items.len) return error.InvalidDocument;
    if (attrs.classes.start + attrs.classes.len > store.strings.items.len) {
        return error.InvalidDocument;
    }
    if (attrs.pairs.start + attrs.pairs.len > store.pairs.items.len) return error.InvalidDocument;
}

test {
    _ = @import("ast_test.zig");
}
