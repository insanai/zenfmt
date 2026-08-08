//! The Markdown writer's capability declaration (ZDS 0013, Writer
//! Lowering): which kernel tags it emits exactly, which it lowers, and
//! the priced degradation rules its emission sites hit. The declaration is
//! validated for totality at compile time, so a new kernel tag will not
//! build until this writer decides its disposition.
//!
//! Rule order here defines `RuleId`; a comptime check keeps the two in
//! lockstep. Costs follow ZDS 0013 Definition 7: component one is dropped
//! content, component two structural degradation, component three style
//! and metadata loss.

const core = @import("zenfmt_core");
const writer_reports = @import("writer_reports.zig");

const lowering = core.lowering;

/// Emission-site handles for the rules below, in the same order.
pub const RuleId = enum(u16) {
    style_dropped,
    extension_fallback,
    citation_dropped,
    raw_dropped,
    nested_table,
    cell_flattened,
    cell_span,
    number_style,
    definition_list,
    container_attrs,
    table_caption,
};

pub const rules = [_]lowering.Rule{
    .{
        .name = "style-dropped",
        .cost = .{ 0, 0, 1, 0, 0, 0 },
        .note = writer_reports.styleDroppedRuleNote,
    },
    .{
        .name = "extension-fallback",
        .cost = .{ 0, 0, 1, 0, 0, 0 },
        .note = writer_reports.extensionFallbackNote,
    },
    .{
        .name = "citation-dropped",
        .cost = .{ 0, 0, 1, 0, 0, 0 },
        .note = writer_reports.citationDroppedNote,
    },
    .{
        .name = "raw-dropped",
        .cost = .{ 1, 0, 0, 0, 0, 0 },
        .note = writer_reports.rawDroppedNote,
    },
    .{
        .name = "nested-table",
        .cost = .{ 1, 0, 0, 0, 0, 0 },
        .note = writer_reports.nestedTableWarning,
    },
    .{
        .name = "cell-flattened",
        .cost = .{ 0, 1, 0, 0, 0, 0 },
        .note = writer_reports.cellFlattenedNote,
    },
    .{
        .name = "cell-span",
        .cost = .{ 0, 1, 0, 0, 0, 0 },
        .note = writer_reports.spanNote,
    },
    .{
        .name = "number-style",
        .cost = .{ 0, 0, 1, 0, 0, 0 },
        .note = writer_reports.numberStyleNote,
    },
    .{
        .name = "definition-list",
        .cost = .{ 0, 1, 0, 0, 0, 0 },
        .note = writer_reports.definitionListNote,
    },
    .{
        .name = "container-attrs",
        .cost = .{ 0, 0, 1, 0, 0, 0 },
        .note = writer_reports.containerAttrsNote,
    },
    .{
        .name = "table-caption",
        .cost = .{ 0, 1, 0, 0, 0, 0 },
        .note = writer_reports.tableCaptionNote,
    },
};

pub const capabilities: lowering.Capabilities = .{
    .exact_blocks = &.{
        .plain,   .paragraph,      .line_block, .heading,   .code_block,
        .quote,   .thematic_break, .figure,     .line,      .list_item,
        .caption, .table_head,     .table_foot, .table_row,
    },
    // Lowered blocks: the emission sites hit the rules above under the
    // conditions the renderer already decides (nested tables, flattened
    // cells, non-decimal numbering, attributed containers, raw formats
    // Markdown cannot carry, extension fallbacks).
    .lowered_blocks = &.{
        .raw_block,       .list,  .definition_list, .definition_entry, .definition_term,
        .definition_body, .table, .table_body,      .table_cell,       .container,
        .extension,
    },
    .exact_inlines = &.{
        .text,          .space, .soft_break, .hard_break, .emphasis, .strong,
        .strikethrough, .quote, .code,       .math,       .link,     .image,
        .note,          .span,
    },
    .lowered_inlines = &.{
        .underline, .small_caps, .superscript, .subscript, .raw, .citation,
        .extension,
    },
    .rules = &rules,
    .facets = &.{},
    .extensions = &.{},
    .propose = propose,
};

fn propose(
    context: *const lowering.ProposalContext,
    node: lowering.Node,
    alternatives: *lowering.Alternatives,
) lowering.PlanError!void {
    switch (node) {
        .block => |index| try proposeBlock(context, index, alternatives),
        .@"inline" => |index| try proposeInline(context, index, alternatives),
    }
}

fn proposeBlock(
    context: *const lowering.ProposalContext,
    index: core.BlockIndex,
    alternatives: *lowering.Alternatives,
) lowering.PlanError!void {
    const doc = context.doc;
    switch (doc.blockTag(index)) {
        .raw_block => {
            const raw = doc.blockAs(index, .raw_block).?;
            const format = doc.text(raw.format);
            if (isMarkdownRaw(format)) return alternatives.add(lowering.Alternative.exact(0));
            try addLoss(alternatives, .omit, .raw_dropped);
        },
        .definition_list => try addLoss(alternatives, .emit_degraded, .definition_list),
        .table => {
            if (context.hasBlockAncestor(index, .table)) {
                try addLoss(alternatives, .emit_text, .nested_table);
            } else if (tableHasCaption(doc, index)) {
                try addLoss(alternatives, .emit_degraded, .table_caption);
            } else {
                try alternatives.add(lowering.Alternative.exact(0));
            }
        },
        .table_cell => try proposeCell(doc, index, alternatives),
        .container => {
            if (doc.block(index).attrs == .none) {
                try alternatives.add(lowering.Alternative.exact(0));
            } else {
                try addLoss(alternatives, .splice_children, .container_attrs);
            }
        },
        .extension => try addLoss(alternatives, .splice_children, .extension_fallback),
        .list => {
            const list = doc.blockAs(index, .list).?;
            if (list.kind == .ordered and list.style != .decimal) {
                try addLoss(alternatives, .emit_degraded, .number_style);
            } else {
                try alternatives.add(lowering.Alternative.exact(0));
            }
        },
        // Normalized table and definition structure carries no additional
        // loss beyond the public ancestor that introduced it.
        .definition_entry,
        .definition_term,
        .definition_body,
        .table_body,
        => try alternatives.add(lowering.Alternative.exact(0)),
        else => return error.InvalidPlan,
    }
}

fn proposeCell(
    doc: *const core.Document,
    index: core.BlockIndex,
    alternatives: *lowering.Alternatives,
) lowering.PlanError!void {
    const cell = doc.blockAs(index, .table_cell).?;
    var losses: [lowering.max_losses_per_alternative]u16 = undefined;
    var count: u32 = 0;
    if (cell.row_span > 1 or cell.col_span > 1) {
        losses[count] = @intFromEnum(RuleId.cell_span);
        count += 1;
    }
    if (cellNeedsFlattening(doc, cell.blocks)) {
        losses[count] = @intFromEnum(RuleId.cell_flattened);
        count += 1;
    }
    if (count == 0) return alternatives.add(lowering.Alternative.exact(0));
    try alternatives.add(lowering.Alternative.degraded(.emit_degraded, 1, losses[0..count]));
}

pub fn cellNeedsFlattening(doc: *const core.Document, blocks: core.ast.BlockRange) bool {
    var roots = doc.blockRoots(blocks);
    var count: u32 = 0;
    while (roots.next()) |root| {
        count += 1;
        const tag = doc.blockTag(root);
        if (tag != .paragraph and tag != .plain) return true;
    }
    return count > 1;
}

fn tableHasCaption(doc: *const core.Document, index: core.BlockIndex) bool {
    var children = doc.blockChildren(index);
    while (children.next()) |child| {
        if (doc.blockTag(child) == .caption) return true;
    }
    return false;
}

fn proposeInline(
    context: *const lowering.ProposalContext,
    index: core.InlineIndex,
    alternatives: *lowering.Alternatives,
) lowering.PlanError!void {
    const doc = context.doc;
    switch (doc.inlineTag(index)) {
        .underline,
        .small_caps,
        .superscript,
        .subscript,
        => try addLoss(alternatives, .splice_children, .style_dropped),
        .raw => {
            const raw = doc.inlineAs(index, .raw).?;
            if (isMarkdownRaw(doc.text(raw.format))) {
                try alternatives.add(lowering.Alternative.exact(0));
            } else {
                try addLoss(alternatives, .omit, .raw_dropped);
            }
        },
        .citation => try addLoss(alternatives, .splice_children, .citation_dropped),
        .extension => try addLoss(alternatives, .splice_children, .extension_fallback),
        else => return error.InvalidPlan,
    }
}

fn addLoss(
    alternatives: *lowering.Alternatives,
    operation: lowering.Operation,
    rule: RuleId,
) lowering.PlanError!void {
    const id: u16 = @intFromEnum(rule);
    try alternatives.add(lowering.Alternative.degraded(operation, id + 1, &.{id}));
}

fn isMarkdownRaw(format: []const u8) bool {
    const std = @import("std");
    return std.mem.eql(u8, format, "markdown") or std.mem.eql(u8, format, "html");
}

comptime {
    capabilities.validate();
    // RuleId and the rules array are one declaration in two spellings.
    if (@typeInfo(RuleId).@"enum".fields.len != rules.len) {
        @compileError("RuleId and the rules array disagree; add the rule to both.");
    }
    for (@typeInfo(RuleId).@"enum".fields, 0..) |field, index| {
        if (field.value != index) @compileError("RuleId values must be dense and ordered.");
    }
}
