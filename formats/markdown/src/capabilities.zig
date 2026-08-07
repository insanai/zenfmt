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
};

pub const capabilities: lowering.Capabilities = .{
    .exact_blocks = &.{
        .plain,     .paragraph, .line_block,     .heading,    .code_block,
        .quote,     .list,      .thematic_break, .figure,     .line,
        .list_item, .caption,   .table_head,     .table_foot, .table_row,
    },
    // Lowered blocks: the emission sites hit the rules above under the
    // conditions the renderer already decides (nested tables, flattened
    // cells, non-decimal numbering, attributed containers, raw formats
    // Markdown cannot carry, extension fallbacks).
    .lowered_blocks = &.{
        .raw_block,       .definition_list, .definition_entry, .definition_term,
        .definition_body, .table,           .table_body,       .table_cell,
        .container,       .extension,
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
};

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
