//! The rebuild transform (ZDS 0002, Traversal and Rewriting): discovery
//! recorded the edits; this pass copies only the changed spines, one
//! column memcpy per unchanged sibling subtree, sharing every append-only
//! side-table index.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const payload = @import("payload.zig");
const metadata = @import("metadata.zig");
const pipeline = @import("pipeline.zig");

const FilterContext = pipeline.FilterContext;
const FilterError = pipeline.FilterError;
const BlockAction = pipeline.BlockAction;
const BlockEdit = pipeline.BlockEdit;
const InlineAction = pipeline.InlineAction;
const InlineEdit = pipeline.InlineEdit;

const Rebuild = struct {
    ctx: *FilterContext,
    store: *ast.Store,
    gpa: std.mem.Allocator,
    doc: *const ast.Document,

    fn hasBlockEditsIn(r: *const Rebuild, start: u32, end: u32) bool {
        return firstEditAtOrAfter(BlockEdit, r.ctx.block_edits.items, start, end);
    }

    fn hasInlineEditsIn(r: *const Rebuild, start: u32, end: u32) bool {
        return firstEditAtOrAfter(InlineEdit, r.ctx.inline_edits.items, start, end);
    }

    fn blockEditFor(r: *const Rebuild, node: u32) ?BlockAction {
        for (r.ctx.block_edits.items) |edit| {
            if (edit.node == node) return edit.action;
            if (edit.node > node) return null;
        }
        return null;
    }

    fn inlineEditFor(r: *const Rebuild, node: u32) ?InlineAction {
        for (r.ctx.inline_edits.items) |edit| {
            if (edit.node == node) return edit.action;
            if (edit.node > node) return null;
        }
        return null;
    }

    /// Bulk-copies a block range: one memcpy per touched column. Relative
    /// `subtree_len` values and append-only side-table indices need no
    /// fix-up.
    fn bulkCopyBlocks(r: *Rebuild, start: u32, len: u32) FilterError!void {
        if (len == 0) return;
        const old_len = r.store.blocks.len;
        try r.store.blocks.resize(r.gpa, old_len + len);
        const slice = r.store.blocks.slice();
        inline for (@typeInfo(ast.Block).@"struct".fields) |field| {
            const column = slice.items(@field(std.meta.FieldEnum(ast.Block), field.name));
            @memcpy(column[old_len..], column[start .. start + len]);
        }
    }

    fn bulkCopyInlines(r: *Rebuild, start: u32, len: u32) FilterError!void {
        if (len == 0) return;
        const old_len = r.store.inlines.len;
        try r.store.inlines.resize(r.gpa, old_len + len);
        const slice = r.store.inlines.slice();
        inline for (@typeInfo(ast.Inline).@"struct".fields) |field| {
            const column = slice.items(@field(std.meta.FieldEnum(ast.Inline), field.name));
            @memcpy(column[old_len..], column[start .. start + len]);
        }
    }

    const Work = union(enum) {
        /// Emit the roots of this old-range in order.
        forest: struct { cursor: u32, end: u32 },
        /// Patch the subtree length of an already-appended node.
        patch: u32,
    };

    /// Rebuilds one block forest into fresh preorder at the end of the
    /// array. Only spines above edits are rewritten node by node.
    fn rebuildBlockForest(r: *Rebuild, range: ast.BlockRange) FilterError!ast.BlockRange {
        const out_start: u32 = @intCast(r.store.blocks.len);
        var work: std.ArrayList(Work) = .empty;
        defer work.deinit(r.gpa);
        try work.append(r.gpa, .{ .forest = .{
            .cursor = range.startRaw(),
            .end = range.endRaw(),
        } });

        while (work.items.len > 0) {
            const top = &work.items[work.items.len - 1];
            switch (top.*) {
                .patch => |out_index| {
                    _ = work.pop();
                    const lengths = r.store.blocks.items(.subtree_len);
                    const count: u32 = @intCast(r.store.blocks.len);
                    assert(lengths[out_index] == 0);
                    lengths[out_index] = count - out_index;
                },
                .forest => |*forest| {
                    if (forest.cursor == forest.end) {
                        _ = work.pop();
                        continue;
                    }
                    const node = forest.cursor;
                    const subtree_len = r.store.blocks.items(.subtree_len)[node];
                    forest.cursor += subtree_len;
                    try r.rebuildBlockNode(&work, node, subtree_len);
                },
            }
        }
        const out_end: u32 = @intCast(r.store.blocks.len);
        return ast.BlockRange.init(out_start, out_end - out_start);
    }

    fn rebuildBlockNode(
        r: *Rebuild,
        work: *std.ArrayList(Work),
        node: u32,
        subtree_len: u32,
    ) FilterError!void {
        const node_end = node + subtree_len;
        const edit = r.blockEditFor(node);

        if (edit) |action| switch (action) {
            .drop => return,
            .replace_subtree => |replacement| {
                try r.bulkCopyBlocks(replacement.startRaw(), replacement.len);
                return;
            },
            .unwrap => {
                assert(payload.blockContent(r.store.blocks.items(.tag)[node]) == .blocks);
                try work.append(r.gpa, .{ .forest = .{ .cursor = node + 1, .end = node_end } });
                return;
            },
            .replace_payload, .replace_attrs => {
                try r.appendEditedBlock(work, node, node_end, action);
                return;
            },
        };

        // No edit on the node itself; are there edits below or inside?
        const inline_range = r.store.blocks.items(.inlines)[node];
        const inlines_edited = !inline_range.isEmpty() and
            r.hasInlineEditsIn(inline_range.startRaw(), inline_range.endRaw());
        const blocks_edited = subtree_len > 1 and r.hasBlockEditsIn(node + 1, node_end);
        const descendants_inline_edited = subtree_len > 1 and
            r.blockSubtreeHasInlineEdits(node, node_end);

        if (!inlines_edited and !blocks_edited and !descendants_inline_edited) {
            try r.bulkCopyBlocks(node, subtree_len);
            return;
        }
        try r.appendEditedBlock(work, node, node_end, null);
    }

    fn blockSubtreeHasInlineEdits(r: *Rebuild, node: u32, node_end: u32) bool {
        if (r.ctx.inline_edits.items.len == 0) return false;
        const ranges = r.store.blocks.items(.inlines);
        var i = node + 1;
        while (i < node_end) : (i += 1) {
            const range = ranges[i];
            if (!range.isEmpty() and r.hasInlineEditsIn(range.startRaw(), range.endRaw())) {
                return true;
            }
        }
        return false;
    }

    /// Appends a copy of one node, rebuilding its inline range when edited
    /// and queueing its block children for rebuild.
    fn appendEditedBlock(
        r: *Rebuild,
        work: *std.ArrayList(Work),
        node: u32,
        node_end: u32,
        action: ?BlockAction,
    ) FilterError!void {
        var copy: ast.Block = .{
            .tag = r.store.blocks.items(.tag)[node],
            .payload = r.store.blocks.items(.payload)[node],
            .attrs = r.store.blocks.items(.attrs)[node],
            .inlines = r.store.blocks.items(.inlines)[node],
            .subtree_len = r.store.blocks.items(.subtree_len)[node],
        };
        if (action) |value| switch (value) {
            .replace_payload => |index| copy.payload = index,
            .replace_attrs => |attrs| copy.attrs = attrs,
            else => unreachable,
        };
        if (!copy.inlines.isEmpty() and
            r.hasInlineEditsIn(copy.inlines.startRaw(), copy.inlines.endRaw()))
        {
            copy.inlines = try r.rebuildInlineForest(copy.inlines);
        }

        const out_index: u32 = @intCast(r.store.blocks.len);
        if (copy.subtree_len > 1) {
            copy.subtree_len = 0;
            try r.store.blocks.append(r.gpa, copy);
            try work.append(r.gpa, .{ .patch = out_index });
            try work.append(r.gpa, .{ .forest = .{ .cursor = node + 1, .end = node_end } });
        } else {
            try r.store.blocks.append(r.gpa, copy);
        }
    }

    fn rebuildInlineForest(r: *Rebuild, range: ast.InlineRange) FilterError!ast.InlineRange {
        const out_start: u32 = @intCast(r.store.inlines.len);
        var work: std.ArrayList(Work) = .empty;
        defer work.deinit(r.gpa);
        try work.append(r.gpa, .{ .forest = .{
            .cursor = range.startRaw(),
            .end = range.endRaw(),
        } });

        while (work.items.len > 0) {
            const top = &work.items[work.items.len - 1];
            switch (top.*) {
                .patch => |out_index| {
                    _ = work.pop();
                    const lengths = r.store.inlines.items(.subtree_len);
                    const count: u32 = @intCast(r.store.inlines.len);
                    assert(lengths[out_index] == 0);
                    lengths[out_index] = count - out_index;
                },
                .forest => |*forest| {
                    if (forest.cursor == forest.end) {
                        _ = work.pop();
                        continue;
                    }
                    const node = forest.cursor;
                    const subtree_len = r.store.inlines.items(.subtree_len)[node];
                    forest.cursor += subtree_len;
                    try r.rebuildInlineNode(&work, node, subtree_len);
                },
            }
        }
        const out_end: u32 = @intCast(r.store.inlines.len);
        return ast.InlineRange.init(out_start, out_end - out_start);
    }

    fn rebuildInlineNode(
        r: *Rebuild,
        work: *std.ArrayList(Work),
        node: u32,
        subtree_len: u32,
    ) FilterError!void {
        const node_end = node + subtree_len;
        const edit = r.inlineEditFor(node);

        if (edit) |action| switch (action) {
            .drop => return,
            .unwrap => {
                assert(payload.inlineHasChildren(r.store.inlines.items(.tag)[node]));
                try work.append(r.gpa, .{ .forest = .{ .cursor = node + 1, .end = node_end } });
                return;
            },
            .replace_payload, .replace_attrs => {
                try r.appendEditedInline(work, node, node_end, action);
                return;
            },
        };

        if (subtree_len == 1 or !r.hasInlineEditsIn(node + 1, node_end)) {
            try r.bulkCopyInlines(node, subtree_len);
            return;
        }
        try r.appendEditedInline(work, node, node_end, null);
    }

    fn appendEditedInline(
        r: *Rebuild,
        work: *std.ArrayList(Work),
        node: u32,
        node_end: u32,
        action: ?InlineAction,
    ) FilterError!void {
        var copy: ast.Inline = .{
            .tag = r.store.inlines.items(.tag)[node],
            .payload = r.store.inlines.items(.payload)[node],
            .attrs = r.store.inlines.items(.attrs)[node],
            .subtree_len = r.store.inlines.items(.subtree_len)[node],
        };
        if (action) |value| switch (value) {
            .replace_payload => |index| copy.payload = index,
            .replace_attrs => |attrs| copy.attrs = attrs,
            else => unreachable,
        };

        const out_index: u32 = @intCast(r.store.inlines.len);
        if (copy.subtree_len > 1) {
            copy.subtree_len = 0;
            try r.store.inlines.append(r.gpa, copy);
            try work.append(r.gpa, .{ .patch = out_index });
            try work.append(r.gpa, .{ .forest = .{ .cursor = node + 1, .end = node_end } });
        } else {
            try r.store.inlines.append(r.gpa, copy);
        }
    }
};

fn firstEditAtOrAfter(comptime Edit: type, edits: []const Edit, start: u32, end: u32) bool {
    // Edits are sorted by node; binary search for the range.
    var low: usize = 0;
    var high: usize = edits.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (edits[mid].node < start) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low < edits.len and edits[low].node < end;
}

pub fn rebuild(ctx: *FilterContext, doc: ast.Document) FilterError!ast.Document {
    const store: *ast.Store = @constCast(doc.store);
    var r: Rebuild = .{
        .ctx = ctx,
        .store = store,
        .gpa = ctx.gpa,
        .doc = &doc,
    };

    const new_body = if (ctx.block_edits.items.len > 0 or ctx.inline_edits.items.len > 0)
        try r.rebuildBlockForest(doc.body)
    else
        doc.body;

    var new_meta = doc.meta;
    if (ctx.meta_edits.items.len > 0) {
        new_meta = try rebuildMeta(ctx, doc);
    }

    return .{
        .store = doc.store,
        .body = new_body,
        .meta = new_meta,
        .plugin_data = doc.plugin_data,
    };
}

/// A new root map: the old entries with the edits merged in, re-sorted.
fn rebuildMeta(ctx: *FilterContext, doc: ast.Document) FilterError!metadata.MetaMapIndex {
    const store = ctx.store;
    const old_entries = doc.metaEntries(doc.meta);

    var merged: std.ArrayList(metadata.MetaEntry) = .empty;
    defer merged.deinit(ctx.gpa);
    for (old_entries) |entry| {
        var replaced = false;
        for (ctx.meta_edits.items) |edit| {
            if (std.mem.eql(u8, store.textSlice(entry.key), store.textSlice(edit.key))) {
                replaced = true;
            }
        }
        if (!replaced) try merged.append(ctx.gpa, entry);
    }
    for (ctx.meta_edits.items) |edit| {
        const value_index: u32 = @intCast(store.meta_values.items.len);
        try store.meta_values.append(ctx.gpa, edit.value);
        try merged.append(ctx.gpa, .{ .key = edit.key, .value = @enumFromInt(value_index) });
    }
    std.mem.sort(metadata.MetaEntry, merged.items, store, metaKeyLessThan);

    const entries_start: u32 = @intCast(store.meta_entries.items.len);
    try store.meta_entries.appendSlice(ctx.gpa, merged.items);
    const map_index: u32 = @intCast(store.meta_maps.items.len);
    try store.meta_maps.append(ctx.gpa, .{
        .start = entries_start,
        .len = @intCast(merged.items.len),
    });
    return @enumFromInt(map_index);
}

fn metaKeyLessThan(store: *ast.Store, lhs: metadata.MetaEntry, rhs: metadata.MetaEntry) bool {
    return std.mem.order(u8, store.textSlice(lhs.key), store.textSlice(rhs.key)) == .lt;
}
