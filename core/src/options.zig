//! Public conversion inputs, outputs, limits, and pipeline options.

const std = @import("std");
const limits = @import("limits.zig");
const lowering = @import("lowering.zig");
const pipeline = @import("pipeline.zig");

pub const InputSpec = union(enum) {
    path: []const u8,
    bytes: Bytes,

    pub const Bytes = struct {
        /// Display name for reports and the manifest.
        name: []const u8,
        data: []const u8,
    };
};

pub const OutputSpec = union(enum) {
    /// Written atomically, with `<path>.zenfmt.json` beside it.
    path: []const u8,
    /// Streamed; the manifest is only returned in `Conversion`. Embedded
    /// resources are not projected in this mode.
    writer: *std.Io.Writer,
    /// Staged in conversion-owned memory with the same resource naming,
    /// target rewriting, digests, and manifest as path publication; the
    /// result carries the complete ensemble (ZDS 0014).
    memory: Memory,

    pub const Memory = struct {
        /// Artifact basename used in the manifest and for deterministic
        /// `<stem>_media/` resource naming. Must not contain a directory
        /// separator.
        artifact_name: []const u8,
    };
};

pub const ConvertOptions = struct {
    input: InputSpec,
    output: OutputSpec,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    limits: limits.Limits = .{},
    /// Replace existing artifact and manifest paths.
    overwrite: bool = false,
    /// Refuse before output when the selected loss crosses this grade.
    strict: lowering.Strictness = .off,
    /// Include full facet rows instead of digest-and-count summaries.
    preserve_facets: bool = false,
    /// Filter stages run in declaration order and revalidate after each.
    pipeline: ?*const pipeline.Pipeline = null,
};

pub const Status = enum(u8) { success, failed };
