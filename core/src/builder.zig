//! Tree construction (ZDS 0002, The Builder).
//!
//! `Builder` is the only writer of the store and is not part of the plugin
//! API. Plugins receive an `Emitter`, which delegates here after type and
//! balance checks. The builder owns the interning table and the bounded
//! open-node stacks; the engine owns the store and the arena.
//!
//! `text` is the one opinionated method, deliberately: it splits on
//! whitespace into `text` and `space` nodes and coalesces adjacent runs, so
//! a reader appending arbitrary chunks still produces a canonical tree, and
//! the whitespace invariants are held in one function instead of nine
//! readers.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const payload = @import("payload.zig");
const metadata = @import("metadata.zig");
const limits_mod = @import("limits.zig");

const Store = ast.Store;
const ByteRange = ast.ByteRange;
const BlockTag = ast.BlockTag;
const InlineTag = ast.InlineTag;

pub const Error = error{ OutOfMemory, DepthLimitExceeded };

pub const BlockToken = struct { index: u32 };
pub const InlineToken = struct { index: u32 };

/// Attributes for the next emitted node, as plugin-facing strings.
pub const AttrOptions = struct {
    id: []const u8 = "",
    classes: []const []const u8 = &.{},
    pairs: []const KeyValue = &.{},

    pub const KeyValue = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn isEmpty(options: AttrOptions) bool {
        return options.id.len == 0 and options.classes.len == 0 and options.pairs.len == 0;
    }
};

const LastSibling = enum { none, text, space };

pub const Builder = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    limits: limits_mod.Limits,

    /// Snapshot start: the first block of the document being built.
    body_start: u32,
    /// Set when note bodies begin; the body ends where they start.
    body_end: ?u32 = null,

    open_blocks: [limits_mod.max_depth_hard_cap]u32 = undefined,
    open_block_depth: u32 = 0,
    /// The one inline-content block currently open, if any, and where its
    /// inline range began.
    open_leaf: ?Leaf = null,
    open_inlines: [limits_mod.max_depth_hard_cap]u32 = undefined,
    open_inline_depth: u32 = 0,
    /// Running total of extracted media bytes, capped by the limits.
    media_bytes_total: u64 = 0,

    /// Coalescing state for `text`: what the last emitted node at the
    /// current inline nesting level was.
    last_sibling: LastSibling = .none,
    /// Index of the trailing `text` node when `last_sibling == .text`.
    coalesce_index: u32 = 0,

    /// Attributes staged for the next node.
    pending_attrs: ast.OptionalAttrsIndex = .none,

    /// Root metadata map entries, appended to the store at `finish`.
    pending_meta: std.ArrayList(metadata.MetaEntry) = .empty,

    intern_table: std.StringHashMapUnmanaged(ByteRange) = .empty,

    pub fn init(gpa: std.mem.Allocator, store: *Store, limits: limits_mod.Limits) Builder {
        assert(limits.max_depth <= limits_mod.max_depth_hard_cap);
        return .{
            .gpa = gpa,
            .store = store,
            .limits = limits,
            .body_start = @intCast(store.blocks.len),
        };
    }

    pub fn deinit(b: *Builder) void {
        b.pending_meta.deinit(b.gpa);
        var keys = b.intern_table.keyIterator();
        while (keys.next()) |key| b.gpa.free(key.*);
        b.intern_table.deinit(b.gpa);
        b.* = undefined;
    }

    const Leaf = struct {
        block: u32,
        inline_start: u32,
    };

    // ------------------------------------------------------------ blocks

    /// Opens a container block; must be matched by `closeBlock`.
    pub fn openBlock(b: *Builder, tag: BlockTag, payload_index: u32) Error!BlockToken {
        assert(payload.blockContent(tag) == .blocks);
        assert(b.open_leaf == null);
        if (b.open_block_depth >= b.limits.max_depth) return error.DepthLimitExceeded;

        const index = try b.appendBlock(tag, payload_index, .empty, 0);
        b.open_blocks[b.open_block_depth] = index;
        b.open_block_depth += 1;
        return .{ .index = index };
    }

    pub fn closeBlock(b: *Builder, token: BlockToken) void {
        assert(b.open_leaf == null);
        assert(b.open_block_depth > 0);
        const index = b.open_blocks[b.open_block_depth - 1];
        assert(index == token.index);
        b.open_block_depth -= 1;

        const lengths = b.store.blocks.items(.subtree_len);
        const block_count: u32 = @intCast(b.store.blocks.len);
        assert(lengths[index] == 0);
        lengths[index] = block_count - index;
        assert(lengths[index] >= 1);
    }

    /// Opens an inline-content block; must be matched by `closeLeaf`. Inline
    /// and text emission is legal only while a leaf is open.
    pub fn openLeaf(b: *Builder, tag: BlockTag, payload_index: u32) Error!BlockToken {
        assert(payload.blockContent(tag) == .inlines);
        assert(b.open_leaf == null);
        assert(b.open_inline_depth == 0);
        if (b.open_block_depth >= b.limits.max_depth) return error.DepthLimitExceeded;

        const index = try b.appendBlock(tag, payload_index, .empty, 1);
        b.open_leaf = .{
            .block = index,
            .inline_start = @intCast(b.store.inlines.len),
        };
        b.last_sibling = .none;
        return .{ .index = index };
    }

    pub fn closeLeaf(b: *Builder, token: BlockToken) void {
        const leaf = b.open_leaf.?;
        assert(leaf.block == token.index);
        assert(b.open_inline_depth == 0);

        const inline_count: u32 = @intCast(b.store.inlines.len);
        assert(inline_count >= leaf.inline_start);
        const ranges = b.store.blocks.items(.inlines);
        ranges[leaf.block] = ast.InlineRange.init(
            leaf.inline_start,
            inline_count - leaf.inline_start,
        );
        b.open_leaf = null;
        b.last_sibling = .none;
    }

    /// A childless block, complete on append.
    pub fn leafBlock(b: *Builder, tag: BlockTag, payload_index: u32) Error!BlockToken {
        assert(payload.blockContent(tag) == .none);
        assert(b.open_leaf == null);
        const index = try b.appendBlock(tag, payload_index, .empty, 1);
        return .{ .index = index };
    }

    fn appendBlock(
        b: *Builder,
        tag: BlockTag,
        payload_index: u32,
        inlines: ast.InlineRange,
        subtree_len: u32,
    ) Error!u32 {
        const index: u32 = @intCast(b.store.blocks.len);
        try b.store.blocks.append(b.gpa, .{
            .tag = tag,
            .payload = payload_index,
            .attrs = b.takeAttrs(),
            .inlines = inlines,
            .subtree_len = subtree_len,
        });
        return index;
    }

    // ----------------------------------------------------------- inlines

    /// Opens a container inline; must be matched by `closeInline`.
    pub fn openInline(b: *Builder, tag: InlineTag, payload_index: u32) Error!InlineToken {
        assert(payload.inlineHasChildren(tag));
        assert(b.open_leaf != null);
        if (b.open_inline_depth >= b.limits.max_depth) return error.DepthLimitExceeded;

        const index = try b.appendInline(tag, payload_index, 0);
        b.open_inlines[b.open_inline_depth] = index;
        b.open_inline_depth += 1;
        b.last_sibling = .none;
        return .{ .index = index };
    }

    pub fn closeInline(b: *Builder, token: InlineToken) void {
        assert(b.open_inline_depth > 0);
        const index = b.open_inlines[b.open_inline_depth - 1];
        assert(index == token.index);
        b.open_inline_depth -= 1;

        const lengths = b.store.inlines.items(.subtree_len);
        const inline_count: u32 = @intCast(b.store.inlines.len);
        assert(lengths[index] == 0);
        lengths[index] = inline_count - index;
        assert(lengths[index] >= 1);
        b.last_sibling = .none;
    }

    /// A childless inline, complete on append.
    pub fn leafInline(b: *Builder, tag: InlineTag, payload_index: u32) Error!InlineToken {
        assert(!payload.inlineHasChildren(tag));
        assert(b.open_leaf != null);
        const index = try b.appendInline(tag, payload_index, 1);
        b.last_sibling = if (tag == .space) .space else .none;
        return .{ .index = index };
    }

    fn appendInline(b: *Builder, tag: InlineTag, payload_index: u32, subtree_len: u32) Error!u32 {
        const index: u32 = @intCast(b.store.inlines.len);
        try b.store.inlines.append(b.gpa, .{
            .tag = tag,
            .payload = payload_index,
            .attrs = b.takeAttrs(),
            .subtree_len = subtree_len,
        });
        return index;
    }

    // -------------------------------------------------------------- text

    pub fn text(b: *Builder, bytes: []const u8) Error!void {
        assert(b.open_leaf != null);
        var i: usize = 0;
        while (i < bytes.len) {
            const in_space = isWhitespace(bytes[i]);
            var j = i + 1;
            while (j < bytes.len and isWhitespace(bytes[j]) == in_space) j += 1;
            assert(j > i);
            if (in_space) try b.spaceNode() else try b.textRun(bytes[i..j]);
            i = j;
        }
    }

    fn spaceNode(b: *Builder) Error!void {
        // Runs of whitespace collapse: adjacent `space` siblings would be
        // redundant, so a second one in a row is skipped.
        if (b.last_sibling == .space) return;
        _ = try b.leafInline(.space, 0);
    }

    fn textRun(b: *Builder, run: []const u8) Error!void {
        assert(run.len > 0);
        for (run) |byte| assert(!isWhitespace(byte));

        if (b.last_sibling == .text and b.pending_attrs == .none) {
            // The previous sibling is a text node whose bytes end the pool;
            // extend it instead of violating the adjacency invariant.
            const span_index = b.store.inlines.items(.payload)[b.coalesce_index];
            const span = &b.store.spans.items[span_index];
            assert(span.end() == b.store.text.items.len);
            try b.store.text.appendSlice(b.gpa, run);
            span.len += @as(u32, @intCast(run.len));
            return;
        }

        const range = try b.appendText(run);
        const span_index: u32 = @intCast(b.store.spans.items.len);
        try b.store.spans.append(b.gpa, range);
        const index = try b.appendInline(.text, span_index, 1);
        b.last_sibling = .text;
        b.coalesce_index = index;
    }

    pub fn softBreak(b: *Builder) Error!void {
        if (b.last_sibling == .space) return;
        _ = try b.leafInline(.soft_break, 0);
        b.last_sibling = .space;
    }

    pub fn hardBreak(b: *Builder) Error!void {
        _ = try b.leafInline(.hard_break, 0);
        b.last_sibling = .space;
    }

    fn isWhitespace(byte: u8) bool {
        return switch (byte) {
            ' ', '\t', '\n', '\r' => true,
            else => false,
        };
    }

    // -------------------------------------------------------------- pool

    /// Appends bytes to the text pool without creating a node.
    pub fn appendText(b: *Builder, bytes: []const u8) Error!ByteRange {
        const start: u32 = @intCast(b.store.text.items.len);
        try b.store.text.appendSlice(b.gpa, bytes);
        return .{ .start = start, .len = @intCast(bytes.len) };
    }

    /// Interns a small, frequently repeated string: class names, attribute
    /// keys, format names. Prose goes through `appendText` and is never
    /// hashed.
    pub fn intern(b: *Builder, bytes: []const u8) Error!ByteRange {
        const entry = try b.intern_table.getOrPut(b.gpa, bytes);
        if (entry.found_existing) return entry.value_ptr.*;
        const range = try b.appendText(bytes);
        // The map must own its key: `bytes` belongs to the caller, and a
        // slice into the text pool would dangle when the pool grows.
        entry.key_ptr.* = try b.gpa.dupe(u8, bytes);
        entry.value_ptr.* = range;
        return range;
    }

    // ------------------------------------------------------------- attrs

    /// Stages attributes for the next emitted node.
    pub fn stageAttrs(b: *Builder, options: AttrOptions) Error!void {
        assert(b.pending_attrs == .none);
        if (options.isEmpty()) return;

        const id = if (options.id.len == 0) ByteRange.empty else try b.appendText(options.id);

        const classes_start: u32 = @intCast(b.store.strings.items.len);
        for (options.classes) |class| {
            const range = try b.intern(class);
            try b.store.strings.append(b.gpa, range);
        }
        const pairs_start: u32 = @intCast(b.store.pairs.items.len);
        for (options.pairs) |pair| {
            try b.store.pairs.append(b.gpa, .{
                .key = try b.intern(pair.key),
                .value = try b.appendText(pair.value),
            });
        }

        const index: u32 = @intCast(b.store.attrs.items.len);
        try b.store.attrs.append(b.gpa, .{
            .id = id,
            .classes = .{ .start = classes_start, .len = @intCast(options.classes.len) },
            .pairs = .{ .start = pairs_start, .len = @intCast(options.pairs.len) },
        });
        b.pending_attrs = ast.OptionalAttrsIndex.from(@enumFromInt(index));
    }

    fn takeAttrs(b: *Builder) ast.OptionalAttrsIndex {
        const attrs = b.pending_attrs;
        b.pending_attrs = .none;
        return attrs;
    }

    // ------------------------------------------------------------- notes

    /// Reserves a note payload row. The reference can be emitted at once;
    /// the body arrives later through `beginNoteBody`.
    pub fn declareNote(b: *Builder) Error!u32 {
        const index: u32 = @intCast(b.store.block_ranges.items.len);
        try b.store.block_ranges.append(b.gpa, ast.BlockRange.empty);
        return index;
    }

    /// Starts the block forest of a declared note. Note bodies live after
    /// the document body: the first call fixes where the body ends. All
    /// body containers must be closed first.
    pub fn beginNoteBody(b: *Builder, note: u32) void {
        assert(note < b.store.block_ranges.items.len);
        assert(b.open_block_depth == 0);
        assert(b.open_leaf == null);
        const block_count: u32 = @intCast(b.store.blocks.len);
        if (b.body_end == null) b.body_end = block_count;
        b.store.block_ranges.items[note] = ast.BlockRange.init(block_count, 0);
    }

    pub fn endNoteBody(b: *Builder, note: u32) void {
        assert(note < b.store.block_ranges.items.len);
        assert(b.open_block_depth == 0);
        assert(b.open_leaf == null);
        const range = &b.store.block_ranges.items[note];
        const block_count: u32 = @intCast(b.store.blocks.len);
        assert(block_count >= range.startRaw());
        range.len = block_count - range.startRaw();
    }

    // ---------------------------------------------------------- metadata

    /// Adds a string entry to the document's root metadata map.
    pub fn metaString(b: *Builder, key: []const u8, value: []const u8) Error!void {
        const key_range = try b.appendText(key);
        const value_range = try b.appendText(value);
        const span_index: u32 = @intCast(b.store.spans.items.len);
        try b.store.spans.append(b.gpa, value_range);
        const value_index: u32 = @intCast(b.store.meta_values.items.len);
        try b.store.meta_values.append(b.gpa, .{ .tag = .string, .payload = span_index });
        try b.pending_meta.append(b.gpa, .{
            .key = key_range,
            .value = @enumFromInt(value_index),
        });
    }

    // ------------------------------------------------------------ finish

    /// Freezes the built forest into a `Document`. Asserts every open stack
    /// is empty: a plugin that returns unbalanced is a bug, not a
    /// recoverable condition.
    pub fn finish(b: *Builder) Error!ast.Document {
        assert(b.open_block_depth == 0);
        assert(b.open_leaf == null);
        assert(b.open_inline_depth == 0);
        assert(b.pending_attrs == .none);

        const entries_start: u32 = @intCast(b.store.meta_entries.items.len);
        // Bytewise key order is the canonical map order.
        std.mem.sort(metadata.MetaEntry, b.pending_meta.items, b.store, metaEntryLessThan);
        try b.store.meta_entries.appendSlice(b.gpa, b.pending_meta.items);
        const map_index: u32 = @intCast(b.store.meta_maps.items.len);
        try b.store.meta_maps.append(b.gpa, .{
            .start = entries_start,
            .len = @intCast(b.pending_meta.items.len),
        });

        const block_count: u32 = @intCast(b.store.blocks.len);
        const body_end = b.body_end orelse block_count;
        assert(body_end >= b.body_start);
        return .{
            .store = b.store,
            .body = ast.BlockRange.init(b.body_start, body_end - b.body_start),
            .meta = @enumFromInt(map_index),
            .plugin_data = .empty,
        };
    }

    fn metaEntryLessThan(store: *Store, lhs: metadata.MetaEntry, rhs: metadata.MetaEntry) bool {
        return std.mem.order(u8, store.textSlice(lhs.key), store.textSlice(rhs.key)) == .lt;
    }
};

// ------------------------------------------------------------- emitter

/// The plugin-facing construction API. Every method is a checked delegate to
/// the builder; balanced `begin`/`end` with `defer` is the natural style.
pub const Emitter = struct {
    builder: *Builder,

    // Container blocks without payloads.
    pub fn beginBlock(e: Emitter, tag: BlockTag) Error!BlockToken {
        assert(switch (tag) {
            .quote, .container, .figure, .line_block, .definition_list, .list_item, .definition_entry, .definition_body, .caption, .table_head, .table_foot, .table_row => true,
            else => false,
        });
        return e.builder.openBlock(tag, 0);
    }

    pub fn beginList(e: Emitter, props: payload.ListProps) Error!BlockToken {
        const index: u32 = @intCast(e.builder.store.lists.items.len);
        try e.builder.store.lists.append(e.builder.gpa, props);
        return e.builder.openBlock(.list, index);
    }

    pub fn beginTable(e: Emitter, alignments: []const payload.Alignment) Error!BlockToken {
        const store = e.builder.store;
        const columns_start: u32 = @intCast(store.columns.items.len);
        for (alignments) |alignment| {
            try store.columns.append(e.builder.gpa, .{ .alignment = alignment });
        }
        const index: u32 = @intCast(store.tables.items.len);
        try store.tables.append(e.builder.gpa, .{ .columns = .{
            .start = columns_start,
            .len = @intCast(alignments.len),
        } });
        return e.builder.openBlock(.table, index);
    }

    pub fn beginTableBody(e: Emitter, props: payload.TableBodyProps) Error!BlockToken {
        const index: u32 = @intCast(e.builder.store.table_bodies.items.len);
        try e.builder.store.table_bodies.append(e.builder.gpa, props);
        return e.builder.openBlock(.table_body, index);
    }

    pub fn beginTableCell(e: Emitter, props: payload.TableCellProps) Error!BlockToken {
        const index: u32 = @intCast(e.builder.store.table_cells.items.len);
        try e.builder.store.table_cells.append(e.builder.gpa, props);
        return e.builder.openBlock(.table_cell, index);
    }

    // Inline-content blocks.
    pub fn beginParagraph(e: Emitter) Error!BlockToken {
        return e.builder.openLeaf(.paragraph, 0);
    }

    pub fn beginPlain(e: Emitter) Error!BlockToken {
        return e.builder.openLeaf(.plain, 0);
    }

    pub fn beginLine(e: Emitter) Error!BlockToken {
        return e.builder.openLeaf(.line, 0);
    }

    pub fn beginDefinitionTerm(e: Emitter) Error!BlockToken {
        return e.builder.openLeaf(.definition_term, 0);
    }

    pub fn beginHeading(e: Emitter, level: u8) Error!BlockToken {
        assert(level >= 1 and level <= 6);
        const index: u32 = @intCast(e.builder.store.headings.items.len);
        try e.builder.store.headings.append(e.builder.gpa, .{ .level = level });
        return e.builder.openLeaf(.heading, index);
    }

    /// Closes any begun block: container or inline-content.
    pub fn endBlock(e: Emitter, token: BlockToken) void {
        if (e.builder.open_leaf) |leaf| {
            if (leaf.block == token.index) {
                e.builder.closeLeaf(token);
                return;
            }
        }
        e.builder.closeBlock(token);
    }

    // Childless blocks.
    pub fn thematicBreak(e: Emitter) Error!void {
        _ = try e.builder.leafBlock(.thematic_break, 0);
    }

    pub fn codeBlock(e: Emitter, language: []const u8, bytes: []const u8) Error!void {
        if (language.len > 0) {
            try e.builder.stageAttrs(.{ .classes = &.{language} });
        }
        const range = try e.builder.appendText(bytes);
        const index: u32 = @intCast(e.builder.store.literals.items.len);
        try e.builder.store.literals.append(e.builder.gpa, range);
        _ = try e.builder.leafBlock(.code_block, index);
    }

    pub fn rawBlock(e: Emitter, format: []const u8, bytes: []const u8) Error!void {
        const index = try e.appendRaw(format, bytes);
        _ = try e.builder.leafBlock(.raw_block, index);
    }

    // Inline containers.
    pub fn beginInline(e: Emitter, tag: InlineTag) Error!InlineToken {
        assert(switch (tag) {
            .emphasis, .underline, .strong, .strikethrough, .superscript, .subscript, .small_caps, .span => true,
            else => false,
        });
        return e.builder.openInline(tag, 0);
    }

    pub fn beginQuoted(e: Emitter, kind: payload.QuoteKind) Error!InlineToken {
        return e.builder.openInline(.quote, @intFromEnum(kind));
    }

    pub fn beginLink(e: Emitter, url: []const u8, title: []const u8) Error!InlineToken {
        return e.builder.openInline(.link, try e.appendTarget(url, title));
    }

    pub fn beginImage(e: Emitter, url: []const u8, title: []const u8) Error!InlineToken {
        return e.builder.openInline(.image, try e.appendTarget(url, title));
    }

    pub fn endInline(e: Emitter, token: InlineToken) void {
        e.builder.closeInline(token);
    }

    pub const MediaError = Error || error{LimitExceeded};

    /// Registers extracted bytes for a media source named in `beginImage`.
    /// On path output the engine writes the bytes into a `<stem>_media`
    /// directory beside the artifact and rewrites every image whose URL
    /// equals `source` to the written file; stream output leaves sources
    /// untouched. A duplicate source keeps its first registration.
    pub fn media(
        e: Emitter,
        source: []const u8,
        bytes: []const u8,
        mime: []const u8,
    ) MediaError!void {
        assert(source.len > 0);
        assert(bytes.len > 0);
        const b = e.builder;
        for (b.store.media.items) |existing| {
            if (std.mem.eql(u8, b.store.textSlice(existing.source), source)) return;
        }
        if (b.store.media.items.len >= b.limits.max_media_files) return error.LimitExceeded;
        if (b.media_bytes_total + bytes.len > b.limits.max_media_bytes) {
            return error.LimitExceeded;
        }
        b.media_bytes_total += bytes.len;
        const source_range = try b.appendText(source);
        const bytes_range: ast.ByteRange = .{
            .start = @intCast(b.store.media_bytes.items.len),
            .len = @intCast(bytes.len),
        };
        try b.store.media_bytes.appendSlice(b.gpa, bytes);
        const mime_range = try b.appendText(mime);
        try b.store.media.append(b.gpa, .{
            .source = source_range,
            .bytes = bytes_range,
            .mime = mime_range,
        });
    }

    // Inline leaves.
    pub fn text(e: Emitter, bytes: []const u8) Error!void {
        return e.builder.text(bytes);
    }

    pub fn softBreak(e: Emitter) Error!void {
        return e.builder.softBreak();
    }

    pub fn hardBreak(e: Emitter) Error!void {
        return e.builder.hardBreak();
    }

    pub fn code(e: Emitter, bytes: []const u8) Error!void {
        const range = try e.builder.appendText(bytes);
        const index: u32 = @intCast(e.builder.store.literals.items.len);
        try e.builder.store.literals.append(e.builder.gpa, range);
        _ = try e.builder.leafInline(.code, index);
    }

    pub fn math(e: Emitter, kind: payload.MathKind, bytes: []const u8) Error!void {
        const range = try e.builder.appendText(bytes);
        const index: u32 = @intCast(e.builder.store.maths.items.len);
        try e.builder.store.maths.append(e.builder.gpa, .{ .kind = kind, .text = range });
        _ = try e.builder.leafInline(.math, index);
    }

    pub fn rawInline(e: Emitter, format: []const u8, bytes: []const u8) Error!void {
        const index = try e.appendRaw(format, bytes);
        _ = try e.builder.leafInline(.raw, index);
    }

    /// Stages attributes applied to the next begun or emitted node.
    pub fn attrs(e: Emitter, options: AttrOptions) Error!void {
        return e.builder.stageAttrs(options);
    }

    /// Reserves a note the body of which is emitted after the document
    /// body, between `beginNoteBody` and `endNoteBody`.
    pub fn declareNote(e: Emitter) Error!u32 {
        return e.builder.declareNote();
    }

    pub fn noteReference(e: Emitter, note: u32) Error!void {
        assert(note < e.builder.store.block_ranges.items.len);
        _ = try e.builder.leafInline(.note, note);
    }

    pub fn beginNoteBody(e: Emitter, note: u32) void {
        e.builder.beginNoteBody(note);
    }

    pub fn endNoteBody(e: Emitter, note: u32) void {
        e.builder.endNoteBody(note);
    }

    /// Adds a string entry to the document's root metadata map.
    pub fn metaString(e: Emitter, key: []const u8, value: []const u8) Error!void {
        return e.builder.metaString(key, value);
    }

    fn appendTarget(e: Emitter, url: []const u8, title: []const u8) Error!u32 {
        const store = e.builder.store;
        const url_range = try e.builder.appendText(url);
        const title_range = if (title.len == 0) ByteRange.empty else try e.builder.appendText(title);
        const index: u32 = @intCast(store.targets.items.len);
        try store.targets.append(e.builder.gpa, .{ .url = url_range, .title = title_range });
        return index;
    }

    fn appendRaw(e: Emitter, format: []const u8, bytes: []const u8) Error!u32 {
        const store = e.builder.store;
        const format_range = try e.builder.intern(format);
        const text_range = try e.builder.appendText(bytes);
        const index: u32 = @intCast(store.raws.items.len);
        try store.raws.append(e.builder.gpa, .{ .format = format_range, .text = text_range });
        return index;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testDocument(store: *Store, build_fn: fn (Emitter) Error!void) !ast.Document {
    var b = Builder.init(testing.allocator, store, .{});
    defer b.deinit();
    try build_fn(.{ .builder = &b });
    return b.finish();
}

test "a paragraph splits and coalesces text" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const doc = try testDocument(&store, struct {
        fn build(e: Emitter) Error!void {
            const p = try e.beginParagraph();
            defer e.endBlock(p);
            try e.text("The quick ");
            try e.text("bro");
            try e.text("wn fox");
        }
    }.build);
    try ast.validate(&doc, .{});

    // text("The") space text("quick") space text("brown") space text("fox"):
    // the chunk boundary inside "brown" coalesces, the spaces split.
    try testing.expectEqual(@as(usize, 7), store.inlines.len);
    const view = doc.block(@enumFromInt(0));
    try testing.expectEqual(ast.BlockTag.paragraph, @as(ast.BlockTag, view.content));
    const brown = doc.text(store.spans.items[store.inlines.items(.payload)[4]]);
    try testing.expectEqualStrings("brown", brown);
    const fox = doc.text(store.spans.items[store.inlines.items(.payload)[6]]);
    try testing.expectEqualStrings("fox", fox);
}

test "nested inline containers patch subtree lengths" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const doc = try testDocument(&store, struct {
        fn build(e: Emitter) Error!void {
            const h = try e.beginHeading(2);
            defer e.endBlock(h);
            try e.text("The ");
            const em = try e.beginInline(.emphasis);
            try e.text("quick");
            e.endInline(em);
            try e.text(" ");
            const link = try e.beginLink("http://x", "");
            try e.text("brown");
            e.endInline(link);
            try e.text(" fox");
        }
    }.build);
    try ast.validate(&doc, .{});

    const heading = doc.blockAs(@enumFromInt(0), .heading).?;
    try testing.expectEqual(@as(u8, 2), heading.level);
    try testing.expectEqual(@as(u32, 9), heading.inlines.len);

    // Hopping the heading's inlines yields seven top-level children.
    var count: u32 = 0;
    var it = doc.inlineRoots(heading.inlines);
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(u32, 7), count);
}

test "quote nests blocks and lists hold items" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const doc = try testDocument(&store, struct {
        fn build(e: Emitter) Error!void {
            const q = try e.beginBlock(.quote);
            defer e.endBlock(q);
            const list = try e.beginList(.unordered);
            defer e.endBlock(list);
            {
                const item = try e.beginBlock(.list_item);
                defer e.endBlock(item);
                const p = try e.beginPlain();
                defer e.endBlock(p);
                try e.text("one");
            }
            {
                const item = try e.beginBlock(.list_item);
                defer e.endBlock(item);
                const p = try e.beginParagraph();
                defer e.endBlock(p);
                try e.text("two");
            }
        }
    }.build);
    try ast.validate(&doc, .{});

    const lengths = store.blocks.items(.subtree_len);
    try testing.expectEqual(@as(u32, 6), lengths[0]);
    try testing.expectEqual(@as(u32, 5), lengths[1]);
    try testing.expectEqual(@as(u32, 2), lengths[2]);
}

test "attrs staging applies to the next node only" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const doc = try testDocument(&store, struct {
        fn build(e: Emitter) Error!void {
            try e.attrs(.{ .id = "intro", .classes = &.{"lead"} });
            const p = try e.beginParagraph();
            defer e.endBlock(p);
            try e.text("hi");
        }
    }.build);
    try ast.validate(&doc, .{});

    const view = doc.block(@enumFromInt(0));
    const attrs = doc.attrsOf(view.attrs);
    try testing.expectEqualStrings("intro", doc.text(attrs.id));
    try testing.expectEqual(@as(u32, 1), attrs.classes.len);
}

test "metadata entries sort by key bytes" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const doc = try testDocument(&store, struct {
        fn build(e: Emitter) Error!void {
            try e.metaString("title", "A Report");
            try e.metaString("author", "Zen");
        }
    }.build);
    try ast.validate(&doc, .{});

    const entries = doc.metaEntries(doc.meta);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("author", doc.text(entries[0].key));
    try testing.expectEqualStrings("title", doc.text(entries[1].key));
}
