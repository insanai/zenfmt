//! The filter pipeline (ZDS 0002, Filters; Traversal and Rewriting).
//!
//! Filters do not mutate. A stage reads one `Document` and appends a
//! replacement snapshot to the same store only when it finds an edit: a
//! discovery pass records edits in source order, and if the edit list is
//! empty the stage returns the input unchanged, allocating no AST storage.
//! A rebuild pass then copies only the changed spines — unchanged sibling
//! subtrees are copied a column at a time, and referenced inline ranges and
//! side-table rows are shared outright because their append-only indices
//! stay stable. On error, every store array is truncated back to the
//! stage's start: rollback is free.
//!
//! A `Pipeline` is declared in the manner of `build.zig`: a user writes
//! `pub fn filters(p: *zenfmt.Pipeline) void` in their own project and
//! compiles it against the zenfmt module. The pipeline is fixed-capacity
//! and allocation-free, so declaration cannot fail.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const payload = @import("payload.zig");
const builder_mod = @import("builder.zig");
const metadata = @import("metadata.zig");
const report_mod = @import("report.zig");
const limits_mod = @import("limits.zig");

pub const FilterOrder = enum { bottom_up, top_down };

pub const FilterAction = enum {
    /// Nothing changes; the subtree is shared or bulk-copied.
    keep,
    /// The node and its whole subtree disappear.
    drop,
    /// The node disappears; its children take its place.
    unwrap,
    /// A replacement recorded through a context helper takes its place.
    replace,
};

pub const FilterError = error{ OutOfMemory, DepthLimitExceeded, LimitExceeded };

pub const FilterDescriptor = struct {
    id: []const u8,
    description: []const u8,
    order: FilterOrder,
    /// Candidate tags; empty means every node of that kind is visited.
    /// Declared tags get the vectorized tag-scan fast path.
    block_tags: []const ast.BlockTag,
    inline_tags: []const ast.InlineTag,
    visit_block: ?*const fn (
        options: *const anyopaque,
        ctx: *FilterContext,
        node: ast.BlockIndex,
    ) FilterError!FilterAction,
    visit_inline: ?*const fn (
        options: *const anyopaque,
        ctx: *FilterContext,
        node: ast.InlineIndex,
    ) FilterError!FilterAction,
    /// Declares that running the filter twice equals running it once; the
    /// property tests hold declared filters to it.
    idempotent: bool,
};

pub fn FilterOptionsType(comptime Options: type) void {
    comptime {
        if (@sizeOf(Options) > Pipeline.max_options_bytes) {
            @compileError("filter options of type " ++ @typeName(Options) ++
                " exceed the pipeline's inline storage. Options are plain " ++
                "data up to 256 bytes; larger state belongs behind a " ++
                "pointer with a lifetime the caller guarantees.");
        }
    }
}

/// The comptime filter constructor: validates the declaration where the
/// filter is defined, generates the type-erased trampolines, and returns a
/// type so `Pipeline.add` can coerce anonymous option literals safely:
/// `p.add(zenfmt.filters.shift_headings, .{ .by = 1 })`.
pub fn Filter(comptime spec: anytype) type {
    const OptionsType = spec.options;
    comptime FilterOptionsType(OptionsType);
    comptime {
        if (!@hasField(@TypeOf(spec), "visit_block") and !@hasField(@TypeOf(spec), "visit_inline")) {
            @compileError("filter `" ++ spec.id ++ "` declares no visit " ++
                "callback. Provide `.visit_block`, `.visit_inline`, or " ++
                "both; a filter that visits nothing does nothing.");
        }
    }

    return struct {
        pub const Options = OptionsType;

        pub const descriptor: FilterDescriptor = .{
            .id = spec.id,
            .description = spec.description,
            .order = if (@hasField(@TypeOf(spec), "order")) spec.order else .top_down,
            .block_tags = if (@hasField(@TypeOf(spec), "block_tags")) spec.block_tags else &.{},
            .inline_tags = if (@hasField(@TypeOf(spec), "inline_tags")) spec.inline_tags else &.{},
            .visit_block = if (@hasField(@TypeOf(spec), "visit_block")) visitBlockErased else null,
            .visit_inline = if (@hasField(@TypeOf(spec), "visit_inline")) visitInlineErased else null,
            .idempotent = if (@hasField(@TypeOf(spec), "idempotent")) spec.idempotent else false,
        };

        fn visitBlockErased(
            options: *const anyopaque,
            ctx: *FilterContext,
            node: ast.BlockIndex,
        ) FilterError!FilterAction {
            const typed: *const Options = @ptrCast(@alignCast(options));
            return spec.visit_block(typed, ctx, node);
        }

        fn visitInlineErased(
            options: *const anyopaque,
            ctx: *FilterContext,
            node: ast.InlineIndex,
        ) FilterError!FilterAction {
            const typed: *const Options = @ptrCast(@alignCast(options));
            return spec.visit_inline(typed, ctx, node);
        }
    };
}

pub const Pipeline = struct {
    pub const max_stages = 32;
    pub const max_options_bytes = 256;

    stages: [max_stages]Stage = undefined,
    stage_count: u32 = 0,

    pub const Stage = struct {
        descriptor: FilterDescriptor,
        options: [max_options_bytes]u8 align(16),
    };

    pub const empty: Pipeline = .{};

    /// Registers a stage. Order matters, and is exactly the order written.
    pub fn add(p: *Pipeline, comptime F: type, options: F.Options) void {
        assert(p.stage_count < max_stages);
        var stage: Stage = .{ .descriptor = F.descriptor, .options = undefined };
        const bytes = std.mem.asBytes(&options);
        @memcpy(stage.options[0..bytes.len], bytes);
        p.stages[p.stage_count] = stage;
        p.stage_count += 1;
    }

    pub fn stageDescriptors(p: *const Pipeline) []const Stage {
        return p.stages[0..p.stage_count];
    }

    /// Runs every stage in declaration order, validating after each. The
    /// input document remains valid; each stage's output becomes the next
    /// stage's input.
    pub fn run(
        p: *const Pipeline,
        gpa: std.mem.Allocator,
        doc: ast.Document,
        reports: *report_mod.Reports,
        limits: limits_mod.Limits,
    ) (FilterError || error{InvalidDocument})!ast.Document {
        var current = doc;
        for (p.stages[0..p.stage_count]) |*stage| {
            current = try runStage(stage, gpa, current, reports, limits);
            try ast.validate(&current, limits);
        }
        return current;
    }
};

// --------------------------------------------------------------- edits

pub const BlockAction = union(enum) {
    drop,
    unwrap,
    replace_payload: u32,
    replace_attrs: ast.OptionalAttrsIndex,
    replace_subtree: ast.BlockRange,
};

pub const BlockEdit = struct {
    node: u32,
    action: BlockAction,
};

pub const InlineAction = union(enum) {
    drop,
    unwrap,
    replace_payload: u32,
    replace_attrs: ast.OptionalAttrsIndex,
};

pub const InlineEdit = struct {
    node: u32,
    action: InlineAction,
};

pub const MetaEdit = struct {
    /// Key bytes in the text pool.
    key: ast.ByteRange,
    value: metadata.MetaValue,
};

/// What a filter sees and edits through. Everything a filter does is a
/// typed call here; it never touches raw arrays.
pub const FilterContext = struct {
    gpa: std.mem.Allocator,
    document: *const ast.Document,
    reports: *report_mod.Reports,
    limits: limits_mod.Limits,

    /// The ancestor tags of the node being visited, outermost first.
    parents: []const ast.BlockTag = &.{},

    store: *ast.Store,
    block_edits: std.ArrayList(BlockEdit) = .empty,
    inline_edits: std.ArrayList(InlineEdit) = .empty,
    meta_edits: std.ArrayList(MetaEdit) = .empty,
    /// The node a helper most recently recorded a replacement for; the
    /// engine asserts `.replace` is only returned after a helper call.
    pending_replace: ?u32 = null,
    replacement_builder: ?builder_mod.Builder = null,
    replacement_node: u32 = 0,
    replacement_start: u32 = 0,

    fn deinit(ctx: *FilterContext) void {
        ctx.block_edits.deinit(ctx.gpa);
        ctx.inline_edits.deinit(ctx.gpa);
        ctx.meta_edits.deinit(ctx.gpa);
    }

    // ------------------------------------------------------- inspection

    pub fn block(ctx: *const FilterContext, node: ast.BlockIndex) payload.BlockView {
        return ctx.document.block(node);
    }

    pub fn inlineView(ctx: *const FilterContext, node: ast.InlineIndex) payload.InlineView {
        return ctx.document.inlineView(node);
    }

    pub fn text(ctx: *const FilterContext, range: ast.ByteRange) []const u8 {
        return ctx.document.text(range);
    }

    pub fn hasClass(ctx: *const FilterContext, attrs: ast.OptionalAttrsIndex, class: []const u8) bool {
        const value = ctx.document.attrsOf(attrs);
        const classes = ctx.store.strings.items[value.classes.start .. value.classes.start + value.classes.len];
        for (classes) |range| {
            if (std.mem.eql(u8, ctx.document.text(range), class)) return true;
        }
        return false;
    }

    pub fn attribute(
        ctx: *const FilterContext,
        attrs: ast.OptionalAttrsIndex,
        key: []const u8,
    ) ?[]const u8 {
        const value = ctx.document.attrsOf(attrs);
        const pairs = ctx.store.pairs.items[value.pairs.start .. value.pairs.start + value.pairs.len];
        for (pairs) |pair| {
            if (std.mem.eql(u8, ctx.document.text(pair.key), key)) {
                return ctx.document.text(pair.value);
            }
        }
        return null;
    }

    /// Formats into the conversion arena; the result outlives the stage.
    pub fn fmt(
        ctx: *FilterContext,
        comptime format: []const u8,
        args: anytype,
    ) error{OutOfMemory}![]const u8 {
        return std.fmt.allocPrint(ctx.gpa, format, args);
    }

    pub fn report(ctx: *FilterContext, value: report_mod.Report) error{OutOfMemory}!void {
        try ctx.reports.add(value);
    }

    // -------------------------------------------------------- rewriting

    /// Points a `link` or `image` at a new target, keeping its children.
    pub fn replaceLinkTarget(
        ctx: *FilterContext,
        node: ast.InlineIndex,
        target: []const u8,
    ) FilterError!void {
        const tag = ctx.document.inlineTag(node);
        assert(tag == .link or tag == .image);
        const old = ctx.store.targets.items[ctx.store.inlines.items(.payload)[node.raw()]];
        const url_start: u32 = @intCast(ctx.store.text.items.len);
        try ctx.store.text.appendSlice(ctx.gpa, target);
        const index: u32 = @intCast(ctx.store.targets.items.len);
        try ctx.store.targets.append(ctx.gpa, .{
            .url = .{ .start = url_start, .len = @intCast(target.len) },
            .title = old.title,
        });
        try ctx.inline_edits.append(ctx.gpa, .{
            .node = node.raw(),
            .action = .{ .replace_payload = index },
        });
        ctx.pending_replace = node.raw();
    }

    /// Renumbers a heading, clamped to 1 through 6 by the caller.
    pub fn replaceHeadingLevel(
        ctx: *FilterContext,
        node: ast.BlockIndex,
        level: u8,
    ) FilterError!void {
        assert(level >= 1 and level <= 6);
        assert(ctx.document.blockTag(node) == .heading);
        const index: u32 = @intCast(ctx.store.headings.items.len);
        try ctx.store.headings.append(ctx.gpa, .{ .level = level });
        try ctx.block_edits.append(ctx.gpa, .{
            .node = node.raw(),
            .action = .{ .replace_payload = index },
        });
        ctx.pending_replace = node.raw();
    }

    /// Replaces a block node's attributes wholesale.
    pub fn replaceBlockAttrs(
        ctx: *FilterContext,
        node: ast.BlockIndex,
        attrs: ast.OptionalAttrsIndex,
    ) FilterError!void {
        try ctx.block_edits.append(ctx.gpa, .{
            .node = node.raw(),
            .action = .{ .replace_attrs = attrs },
        });
        ctx.pending_replace = node.raw();
    }

    pub fn replaceInlineAttrs(
        ctx: *FilterContext,
        node: ast.InlineIndex,
        attrs: ast.OptionalAttrsIndex,
    ) FilterError!void {
        try ctx.inline_edits.append(ctx.gpa, .{
            .node = node.raw(),
            .action = .{ .replace_attrs = attrs },
        });
        ctx.pending_replace = node.raw();
    }

    /// Builds a new attrs row from plugin-facing strings.
    pub fn makeAttrs(ctx: *FilterContext, options: builder_mod.AttrOptions) FilterError!ast.OptionalAttrsIndex {
        var scratch = builder_mod.Builder.init(ctx.gpa, ctx.store, ctx.limits);
        defer scratch.deinit();
        try scratch.stageAttrs(options);
        const staged = scratch.pending_attrs;
        scratch.pending_attrs = .none;
        return staged;
    }

    /// Opens an emitter whose output replaces `node`'s whole subtree. The
    /// replacement must be balanced and committed before returning.
    pub fn beginReplaceBlock(ctx: *FilterContext, node: ast.BlockIndex) FilterError!builder_mod.Emitter {
        assert(ctx.replacement_builder == null);
        ctx.replacement_builder = builder_mod.Builder.init(ctx.gpa, ctx.store, ctx.limits);
        ctx.replacement_node = node.raw();
        ctx.replacement_start = @intCast(ctx.store.blocks.len);
        return .{ .builder = &ctx.replacement_builder.? };
    }

    pub fn commitReplaceBlock(ctx: *FilterContext) FilterError!void {
        var replacement = ctx.replacement_builder.?;
        assert(replacement.open_block_depth == 0);
        assert(replacement.open_leaf == null);
        replacement.deinit();
        ctx.replacement_builder = null;

        const end: u32 = @intCast(ctx.store.blocks.len);
        try ctx.block_edits.append(ctx.gpa, .{
            .node = ctx.replacement_node,
            .action = .{ .replace_subtree = ast.BlockRange.init(
                ctx.replacement_start,
                end - ctx.replacement_start,
            ) },
        });
        ctx.pending_replace = ctx.replacement_node;
    }

    /// Sets a root metadata entry to rich inline content that already
    /// exists in the store — a promoted heading's inlines, for example.
    pub fn setMetaInlines(
        ctx: *FilterContext,
        key: []const u8,
        range: ast.InlineRange,
    ) FilterError!void {
        const key_start: u32 = @intCast(ctx.store.text.items.len);
        try ctx.store.text.appendSlice(ctx.gpa, key);
        const range_index: u32 = @intCast(ctx.store.inline_ranges.items.len);
        try ctx.store.inline_ranges.append(ctx.gpa, range);
        try ctx.meta_edits.append(ctx.gpa, .{
            .key = .{ .start = key_start, .len = @intCast(key.len) },
            .value = .{ .tag = .inlines, .payload = range_index },
        });
    }
};

// ----------------------------------------------------------- one stage

fn runStage(
    stage: *const Pipeline.Stage,
    gpa: std.mem.Allocator,
    doc: ast.Document,
    reports: *report_mod.Reports,
    limits: limits_mod.Limits,
) FilterError!ast.Document {
    const store: *ast.Store = @constCast(doc.store);
    const mark = storeMark(store);

    var ctx: FilterContext = .{
        .gpa = gpa,
        .document = &doc,
        .reports = reports,
        .limits = limits,
        .store = store,
    };
    defer ctx.deinit();

    discover(stage, &ctx, doc) catch |err| {
        truncateStore(store, mark);
        return err;
    };

    if (ctx.block_edits.items.len == 0 and
        ctx.inline_edits.items.len == 0 and
        ctx.meta_edits.items.len == 0)
    {
        // The identity case: nothing was appended, nothing is copied.
        assert(std.meta.eql(storeMark(store), mark));
        return doc;
    }

    return rebuild(&ctx, doc) catch |err| {
        truncateStore(store, mark);
        return err;
    };
}

const StoreMark = struct {
    lengths: [store_field_count]usize,
};

const store_field_count = @typeInfo(ast.Store).@"struct".fields.len;

fn storeMark(store: *const ast.Store) StoreMark {
    var mark: StoreMark = undefined;
    inline for (@typeInfo(ast.Store).@"struct".fields, 0..) |field, i| {
        mark.lengths[i] = lengthOf(@field(store, field.name));
    }
    return mark;
}

fn truncateStore(store: *ast.Store, mark: StoreMark) void {
    inline for (@typeInfo(ast.Store).@"struct".fields, 0..) |field, i| {
        @field(store, field.name).shrinkRetainingCapacity(mark.lengths[i]);
    }
}

fn lengthOf(list: anytype) usize {
    return if (@hasField(@TypeOf(list), "items")) list.items.len else list.len;
}

// ------------------------------------------------------------ discovery

/// Walks the body in preorder with one explicit stack, visiting candidate
/// nodes. Top-down filters see a node before its descendants; bottom-up
/// filters see it after. Edits are recorded by node index and sorted
/// afterwards, so both orders feed the same rebuild.
fn discover(
    stage: *const Pipeline.Stage,
    ctx: *FilterContext,
    doc: ast.Document,
) FilterError!void {
    const descriptor = &stage.descriptor;
    const options: *const anyopaque = &stage.options;

    const slice = doc.store.blocks.slice();
    const tags = slice.items(.tag);
    const lengths = slice.items(.subtree_len);
    const inline_ranges = slice.items(.inlines);

    // The fast path: no block callback and a declared inline tag set means
    // whole block subtrees without candidates are skipped by tag scan.
    var parent_tags: [limits_mod.max_depth_hard_cap]ast.BlockTag = undefined;
    var ends: [limits_mod.max_depth_hard_cap]u32 = undefined;
    var depth: u32 = 0;

    var cursor = doc.body.startRaw();
    const end = doc.body.endRaw();
    while (cursor < end) {
        while (depth > 0 and ends[depth - 1] == cursor) depth -= 1;
        const tag = tags[cursor];
        const subtree_len = lengths[cursor];

        if (descriptor.visit_block) |visit| {
            if (tagMatches(ast.BlockTag, descriptor.block_tags, tag)) {
                ctx.parents = parent_tags[0..depth];
                ctx.pending_replace = null;
                const action = try visit(options, ctx, @enumFromInt(cursor));
                switch (action) {
                    .keep => {},
                    .drop => {
                        try ctx.block_edits.append(ctx.gpa, .{ .node = cursor, .action = .drop });
                        cursor += subtree_len;
                        continue;
                    },
                    .unwrap => {
                        assert(payload.blockContent(tag) == .blocks);
                        try ctx.block_edits.append(ctx.gpa, .{ .node = cursor, .action = .unwrap });
                    },
                    .replace => {
                        // `.replace` is only meaningful after a helper
                        // recorded what replaces the node.
                        assert(ctx.pending_replace == cursor);
                        cursor += subtree_len;
                        continue;
                    },
                }
            }
        }

        if (descriptor.visit_inline != null and payload.blockContent(tag) == .inlines) {
            try discoverInlines(stage, ctx, doc, inline_ranges[cursor]);
        }

        if (payload.blockContent(tag) == .blocks and subtree_len > 1) {
            assert(depth < ctx.limits.max_depth);
            parent_tags[depth] = tag;
            ends[depth] = cursor + subtree_len;
            depth += 1;
            cursor += 1;
        } else {
            cursor += subtree_len;
        }
    }

    std.mem.sort(BlockEdit, ctx.block_edits.items, {}, blockEditLessThan);
    std.mem.sort(InlineEdit, ctx.inline_edits.items, {}, inlineEditLessThan);
}

fn discoverInlines(
    stage: *const Pipeline.Stage,
    ctx: *FilterContext,
    doc: ast.Document,
    range: ast.InlineRange,
) FilterError!void {
    const descriptor = &stage.descriptor;
    const options: *const anyopaque = &stage.options;
    const visit = descriptor.visit_inline.?;

    const slice = doc.store.inlines.slice();
    const tags = slice.items(.tag);
    const lengths = slice.items(.subtree_len);

    // Declared single-tag filters get the vectorized scan: one byte per
    // node, no node loads for the misses.
    if (descriptor.inline_tags.len == 1) {
        const wanted = descriptor.inline_tags[0];
        var from = range.startRaw();
        while (std.mem.indexOfScalarPos(u8, @ptrCast(tags[0..range.endRaw()]), from, @intFromEnum(wanted))) |hit| {
            ctx.pending_replace = null;
            const action = try visit(options, ctx, @enumFromInt(hit));
            try recordInlineAction(ctx, @intCast(hit), action);
            from = @intCast(hit + 1);
        }
        return;
    }

    var cursor = range.startRaw();
    const end = range.endRaw();
    while (cursor < end) {
        const tag = tags[cursor];
        if (tagMatches(ast.InlineTag, descriptor.inline_tags, tag)) {
            ctx.pending_replace = null;
            const action = try visit(options, ctx, @enumFromInt(cursor));
            if (action == .drop) {
                try recordInlineAction(ctx, cursor, action);
                cursor += lengths[cursor];
                continue;
            }
            try recordInlineAction(ctx, cursor, action);
        }
        cursor += 1;
    }
}

fn recordInlineAction(ctx: *FilterContext, node: u32, action: FilterAction) FilterError!void {
    switch (action) {
        .keep => {},
        .drop => try ctx.inline_edits.append(ctx.gpa, .{ .node = node, .action = .drop }),
        .unwrap => try ctx.inline_edits.append(ctx.gpa, .{ .node = node, .action = .unwrap }),
        .replace => assert(ctx.pending_replace == node),
    }
}

fn tagMatches(comptime Tag: type, declared: []const Tag, tag: Tag) bool {
    if (declared.len == 0) return true;
    for (declared) |candidate| {
        if (candidate == tag) return true;
    }
    return false;
}

fn blockEditLessThan(_: void, lhs: BlockEdit, rhs: BlockEdit) bool {
    return lhs.node < rhs.node;
}

fn inlineEditLessThan(_: void, lhs: InlineEdit, rhs: InlineEdit) bool {
    return lhs.node < rhs.node;
}

// The rebuild transform lives in `transform.zig`.
const transform = @import("transform.zig");
const rebuild = transform.rebuild;

test "the empty pipeline is the identity" {
    var store: ast.Store = .{};
    defer store.deinit(std.testing.allocator);
    try store.meta_maps.append(std.testing.allocator, .{ .start = 0, .len = 0 });

    const doc: ast.Document = .{
        .store = &store,
        .body = ast.BlockRange.empty,
        .meta = @enumFromInt(0),
        .plugin_data = .empty,
    };
    var reports = report_mod.Reports.init(std.testing.allocator, .{});
    defer reports.entries.deinit(std.testing.allocator);
    const pipeline: Pipeline = .empty;
    const out = try pipeline.run(std.testing.allocator, doc, &reports, .{});
    try std.testing.expectEqual(doc.body, out.body);
}
