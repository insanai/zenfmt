//! Resource limits (ZDS 0002, Security Considerations).
//!
//! Every limit has a name, a default, a CLI override (`--limit NAME=VALUE`),
//! and a reason recorded in the architecture record. Limits bound what a
//! hostile input can cost; they are a design surface, not tuning knobs, and a
//! change to a default belongs in a ZDS amendment.

const std = @import("std");
const assert = std.debug.assert;

/// Fixed upper bound on any depth limit override. Walker stacks are sized to
/// this at compile time, so raising `max_depth` past it is refused rather
/// than silently unsafe.
pub const max_depth_hard_cap: u32 = 4096;

pub const Limits = struct {
    /// Maximum bytes read from any single input document.
    max_input_bytes: u64 = 512 * 1024 * 1024,
    /// Maximum nesting depth of either node tree; bounds every explicit
    /// walker stack, so a deeply nested input is a report, not a crash.
    max_depth: u32 = 256,
    /// Maximum entries admitted from one archive central directory.
    max_archive_entries: u32 = 4096,
    /// Maximum expanded size of one archive entry.
    max_entry_uncompressed: u64 = 256 * 1024 * 1024,
    /// Maximum total expanded size across all read entries.
    max_total_uncompressed: u64 = 1024 * 1024 * 1024,
    /// Maximum expansion ratio, checked during streaming decompression.
    max_compression_ratio: u32 = 200,
    /// Maximum archive entry name length in bytes.
    max_entry_name_bytes: u32 = 1024,
    /// Maximum XML element nesting depth.
    max_xml_depth: u32 = 256,
    /// Scanner scratch cap: structural offsets are drained per chunk of at
    /// most this many bytes rather than retained for the whole input.
    max_scan_chunk_bytes: u32 = 1024 * 1024,
    /// Maximum size of an adjacent artifact manifest accepted on input.
    max_manifest_bytes: u32 = 16 * 1024 * 1024,
    /// Maximum size of one plugin-data namespace value.
    max_plugin_data_bytes: u32 = 4 * 1024 * 1024,
    /// Maximum JSON nesting depth in an accepted manifest.
    max_manifest_depth: u32 = 64,
    /// Distinct locations an aggregated report retains before it counts the
    /// remainder instead of listing it.
    max_report_samples: u32 = 4,

    /// One row of the `--limit` table: the field name is the public name.
    pub const Field = std.meta.FieldEnum(Limits);

    /// Applies `NAME=VALUE`. Returns the offending part on failure so the
    /// caller can build a report that shows exactly what to change.
    pub fn override(limits: *Limits, text: []const u8) OverrideError!void {
        const equals = std.mem.indexOfScalar(u8, text, '=') orelse
            return error.MissingValue;
        const name = text[0..equals];
        const value_text = text[equals + 1 ..];
        assert(name.len + 1 + value_text.len == text.len);
        if (value_text.len == 0) return error.MissingValue;

        inline for (@typeInfo(Limits).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                const value = std.fmt.parseInt(field.type, value_text, 10) catch
                    return error.InvalidValue;
                if (value == 0) return error.InvalidValue;
                const is_depth = comptime std.mem.eql(u8, field.name, "max_depth") or
                    std.mem.eql(u8, field.name, "max_xml_depth");
                if (is_depth and value > max_depth_hard_cap) return error.InvalidValue;
                @field(limits, field.name) = value;
                return;
            }
        }
        return error.UnknownLimit;
    }

    pub const OverrideError = error{ UnknownLimit, MissingValue, InvalidValue };

    /// The limit names, for suggestion lists in reports.
    pub const names: []const []const u8 = blk: {
        const fields = @typeInfo(Limits).@"struct".fields;
        var list: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| list[i] = field.name;
        const copy = list;
        break :blk &copy;
    };
};

test "override accepts a known limit" {
    var limits: Limits = .{};
    try limits.override("max_compression_ratio=600");
    try std.testing.expectEqual(@as(u32, 600), limits.max_compression_ratio);
}

test "override rejects unknown names and malformed values" {
    var limits: Limits = .{};
    try std.testing.expectError(error.UnknownLimit, limits.override("max_zip=1"));
    try std.testing.expectError(error.MissingValue, limits.override("max_depth"));
    try std.testing.expectError(error.MissingValue, limits.override("max_depth="));
    try std.testing.expectError(error.InvalidValue, limits.override("max_depth=abc"));
    try std.testing.expectError(error.InvalidValue, limits.override("max_depth=0"));
    try std.testing.expectError(error.InvalidValue, limits.override("max_depth=1000000"));
}

test "names lists every field" {
    try std.testing.expectEqual(
        @typeInfo(Limits).@"struct".fields.len,
        Limits.names.len,
    );
}
