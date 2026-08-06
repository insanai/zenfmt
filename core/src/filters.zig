//! The built-in filters (ZDS 0002, Filters that ship).
//!
//! A small set, chosen because they are the transforms people actually
//! reach for and because each exercises a different part of the contract.
//! They double as the worked examples and as the tests for the filter
//! machinery: if a transform cannot be written cleanly here, the node set
//! is wrong, and this is where we find out.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const pipeline = @import("pipeline.zig");

const FilterContext = pipeline.FilterContext;
const FilterAction = pipeline.FilterAction;
const FilterError = pipeline.FilterError;

/// Adds a constant to every heading level, clamping at 1 and 6. The
/// simplest possible stage: one tag, a typed payload edit, `.replace`.
pub const shift_headings = pipeline.Filter(.{
    .id = "core.shift-headings",
    .description = "Shift every heading level by a constant",
    .options = ShiftHeadingsOptions,
    .block_tags = &.{.heading},
    .idempotent = false,
    .visit_block = shiftHeadingsVisit,
});

pub const ShiftHeadingsOptions = struct {
    by: i8,
};

fn shiftHeadingsVisit(
    options: *const ShiftHeadingsOptions,
    ctx: *FilterContext,
    node: ast.BlockIndex,
) FilterError!FilterAction {
    const heading = switch (ctx.block(node).content) {
        .heading => |value| value,
        else => unreachable,
    };
    const shifted = @as(i16, heading.level) + options.by;
    const clamped: u8 = @intCast(std.math.clamp(shifted, 1, 6));
    if (clamped == heading.level) return .keep;
    try ctx.replaceHeadingLevel(node, clamped);
    return .replace;
}

/// Moves a leading level-1 heading into document metadata as the title.
/// Shows a filter that edits the document as a whole rather than node by
/// node: one drop, one metadata entry sharing the heading's inline range.
pub const promote_first_heading = pipeline.Filter(.{
    .id = "core.promote-first-heading",
    .description = "Promote a leading level-1 heading to the title",
    .options = PromoteFirstHeadingOptions,
    .block_tags = &.{.heading},
    .idempotent = true,
    .visit_block = promoteFirstHeadingVisit,
});

pub const PromoteFirstHeadingOptions = struct {};

fn promoteFirstHeadingVisit(
    options: *const PromoteFirstHeadingOptions,
    ctx: *FilterContext,
    node: ast.BlockIndex,
) FilterError!FilterAction {
    _ = options;
    // Only the document's first block qualifies, and only at level 1.
    if (node.raw() != ctx.document.body.startRaw()) return .keep;
    if (ctx.parents.len != 0) return .keep;
    const heading = switch (ctx.block(node).content) {
        .heading => |value| value,
        else => unreachable,
    };
    if (heading.level != 1) return .keep;
    try ctx.setMetaInlines("title", heading.inlines);
    return .drop;
}

/// Unwraps `container` and `span` nodes carrying no attributes.
/// Demonstrates `.unwrap`, and is genuinely useful after HTML and DOCX
/// ingestion.
pub const drop_empty_containers = pipeline.Filter(.{
    .id = "core.drop-empty-containers",
    .description = "Unwrap containers and spans with no attributes",
    .options = DropEmptyContainersOptions,
    .block_tags = &.{.container},
    .inline_tags = &.{.span},
    .idempotent = true,
    .visit_block = dropEmptyContainersBlock,
    .visit_inline = dropEmptyContainersInline,
});

pub const DropEmptyContainersOptions = struct {};

fn dropEmptyContainersBlock(
    options: *const DropEmptyContainersOptions,
    ctx: *FilterContext,
    node: ast.BlockIndex,
) FilterError!FilterAction {
    _ = options;
    const view = ctx.block(node);
    return if (view.attrs == .none) .unwrap else .keep;
}

fn dropEmptyContainersInline(
    options: *const DropEmptyContainersOptions,
    ctx: *FilterContext,
    node: ast.InlineIndex,
) FilterError!FilterAction {
    _ = options;
    const view = ctx.inlineView(node);
    return if (view.attrs == .none) .unwrap else .keep;
}

/// Replaces a table inside a table cell with a placeholder and a report.
/// The canonical lossy transform, and the one that shows how a filter
/// cooperates with the diagnostics contract.
pub const flatten_nested_tables = pipeline.Filter(.{
    .id = "core.flatten-nested-tables",
    .description = "Replace tables nested in cells with a placeholder",
    .options = FlattenNestedTablesOptions,
    .block_tags = &.{.table},
    .idempotent = true,
    .visit_block = flattenNestedTablesVisit,
});

pub const FlattenNestedTablesOptions = struct {
    placeholder: []const u8 = "(nested table omitted)",
};

fn flattenNestedTablesVisit(
    options: *const FlattenNestedTablesOptions,
    ctx: *FilterContext,
    node: ast.BlockIndex,
) FilterError!FilterAction {
    var nested = false;
    for (ctx.parents) |parent| {
        if (parent == .table_cell) nested = true;
    }
    if (!nested) return .keep;

    const out = try ctx.beginReplaceBlock(node);
    const paragraph = try out.beginParagraph();
    try out.text(options.placeholder);
    out.endBlock(paragraph);
    try ctx.commitReplaceBlock();

    try ctx.report(.{
        .severity = .warning,
        .code = "core.nested-table-flattened",
        .title = "NESTED TABLE FLATTENED",
        .problem = "A table sits inside another table's cell, and the " ++
            "flatten-nested-tables filter is active.",
        .consequence = "The inner table was replaced with a placeholder " ++
            "paragraph; its content is not in the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source or restructure",
            .explanation = "Keep the source document, or restructure it " ++
                "so tables do not nest, if the inner table's content " ++
                "matters.",
        }},
    });
    return .replace;
}

/// Removes classes matching a pattern — an exact name, or a `prefix*`
/// wildcard. Shows attribute editing and the tag-scan fast path.
pub const strip_classes = pipeline.Filter(.{
    .id = "core.strip-classes",
    .description = "Remove classes matching a pattern",
    .options = StripClassesOptions,
    .idempotent = true,
    .visit_block = stripClassesBlock,
    .visit_inline = stripClassesInline,
});

pub const StripClassesOptions = struct {
    pattern: []const u8,
};

fn classMatches(pattern: []const u8, class: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "*")) {
        return std.mem.startsWith(u8, class, pattern[0 .. pattern.len - 1]);
    }
    return std.mem.eql(u8, class, pattern);
}

fn strippedAttrs(
    ctx: *FilterContext,
    attrs_index: ast.OptionalAttrsIndex,
    pattern: []const u8,
) FilterError!?ast.OptionalAttrsIndex {
    if (attrs_index == .none) return null;
    const attrs = ctx.document.attrsOf(attrs_index);
    const store = ctx.store;
    const classes = store.strings.items[attrs.classes.start .. attrs.classes.start + attrs.classes.len];

    var kept: u32 = 0;
    for (classes) |class| {
        if (!classMatches(pattern, ctx.text(class))) kept += 1;
    }
    if (kept == classes.len) return null;

    if (kept == 0 and attrs.id.len == 0 and attrs.pairs.len == 0) {
        return .none;
    }
    const classes_start: u32 = @intCast(store.strings.items.len);
    for (classes) |class| {
        if (!classMatches(pattern, ctx.text(class))) {
            try store.strings.append(ctx.gpa, class);
        }
    }
    const index: u32 = @intCast(store.attrs.items.len);
    try store.attrs.append(ctx.gpa, .{
        .id = attrs.id,
        .classes = .{ .start = classes_start, .len = kept },
        .pairs = attrs.pairs,
    });
    return ast.OptionalAttrsIndex.from(@enumFromInt(index));
}

fn stripClassesBlock(
    options: *const StripClassesOptions,
    ctx: *FilterContext,
    node: ast.BlockIndex,
) FilterError!FilterAction {
    const view = ctx.block(node);
    const replacement = try strippedAttrs(ctx, view.attrs, options.pattern) orelse return .keep;
    try ctx.replaceBlockAttrs(node, replacement);
    return .replace;
}

fn stripClassesInline(
    options: *const StripClassesOptions,
    ctx: *FilterContext,
    node: ast.InlineIndex,
) FilterError!FilterAction {
    const view = ctx.inlineView(node);
    const replacement = try strippedAttrs(ctx, view.attrs, options.pattern) orelse return .keep;
    try ctx.replaceInlineAttrs(node, replacement);
    return .replace;
}
