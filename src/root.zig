//! `zenfmt`: the umbrella library.
//!
//! Re-exports the core public API through the default bundle assembled in
//! `default_bundle.zig`. Applications that want a smaller binary import
//! `zenfmt_core` and only the format libraries they need; both paths use
//! the same options, result, and plugin contracts.

const core = @import("zenfmt_core");

pub const Default = @import("default_bundle.zig").Default;
pub const cli = @import("cli.zig");

pub const convert = Default.convert;
pub const default_output_format = Default.default_output_format;

pub const ConvertOptions = core.ConvertOptions;
pub const Conversion = core.Conversion;
pub const InputSpec = core.InputSpec;
pub const OutputSpec = core.OutputSpec;
pub const Status = core.Status;
pub const Limits = core.Limits;
pub const Document = core.Document;
pub const BlockTag = core.BlockTag;
pub const InlineTag = core.InlineTag;
pub const BlockView = core.BlockView;
pub const InlineView = core.InlineView;
pub const Emitter = core.Emitter;
pub const Report = core.Report;
pub const Pipeline = core.Pipeline;
pub const Filter = core.Filter;
pub const FilterContext = core.FilterContext;
pub const FilterAction = core.FilterAction;
pub const FilterError = core.FilterError;
pub const filters = core.filters;
pub const report = core.report;
pub const json = core.json;
pub const limits = core.limits;
pub const ast = core.ast;
pub const manifest = core.manifest;
pub const builder = core.builder;

test {
    _ = @import("default_bundle.zig");
}
