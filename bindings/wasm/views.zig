//! Resolving a view request into a slice of a live result (ZDS 0015).
//!
//! Views are borrowed: the bytes belong to the result until it is freed, and
//! the module never copies them for the sake of the boundary. A host reads
//! them out of linear memory and takes its own copy if it wants one.
//!
//! Nothing here can fail in a way a caller must handle. An absent view, an
//! out-of-range resource index, and an index given for a view that has none
//! all resolve to "no slice", which the ABI reports as offset zero — the same
//! answer a caller already has to handle for a result that has no manifest.

const std = @import("std");
const exports = @import("exports.zig");
const Result = @import("result.zig").Result;

const View = exports.View;

/// The bytes a view names, or null when the result does not have that view.
pub fn resolve(result: *const Result, view: View, index: u32) ?[]const u8 {
    if (index != 0 and !view.indexed()) return null;

    return switch (view) {
        .reports_json => result.reports_json,
        .manifest_json => manifestJson(result),
        .source_format => formatId(result, .source),
        .output_format => formatId(result, .output),
        .artifact => if (result.ensemble()) |value| value.artifact else null,
        .artifact_name => if (result.ensemble()) |value| value.artifact_name else null,
        .resource_rel_path,
        .resource_bytes,
        .resource_digest_hex,
        => resource(result, view, index),
    };
}

fn manifestJson(result: *const Result) ?[]const u8 {
    const conversion = result.conversion orelse return null;
    return conversion.manifest_json;
}

const FormatRole = enum { source, output };

fn formatId(result: *const Result, role: FormatRole) ?[]const u8 {
    const conversion = result.conversion orelse return null;
    return switch (role) {
        .source => conversion.source_format,
        .output => conversion.output_format,
    };
}

fn resource(result: *const Result, view: View, index: u32) ?[]const u8 {
    const ensemble = result.ensemble() orelse return null;
    if (index >= ensemble.resources.len) return null;
    const entry = &ensemble.resources[index];
    return switch (view) {
        .resource_rel_path => entry.rel_path,
        .resource_bytes => entry.bytes,
        .resource_digest_hex => &entry.digest_hex,
        else => unreachable,
    };
}

pub fn resourceCount(result: *const Result) u32 {
    const ensemble = result.ensemble() orelse return 0;
    return @intCast(ensemble.resources.len);
}

const testing = std.testing;
const result_mod = @import("result.zig");

test "a successful conversion exposes artifact, formats, and reports" {
    defer result_mod.freeAll();
    const handle = result_mod.convert(
        \\{"schema":1,"name":"note.md"}
    , "# Title\n\nBody.\n");
    const result = result_mod.lookup(handle).?;
    defer _ = result_mod.free(handle);

    try testing.expect(resolve(result, .artifact, 0) != null);
    try testing.expectEqualStrings("note.md", resolve(result, .artifact_name, 0).?);
    try testing.expectEqualStrings("markdown", resolve(result, .source_format, 0).?);
    try testing.expectEqualStrings("markdown", resolve(result, .output_format, 0).?);
    try testing.expect(resolve(result, .reports_json, 0) != null);
    try testing.expect(resolve(result, .manifest_json, 0) != null);
}

test "a refused request has reports but no artifact" {
    defer result_mod.freeAll();
    const handle = result_mod.convert(
        \\{"schema":1,"name":"bad/name.md"}
    , "");
    const result = result_mod.lookup(handle).?;
    defer _ = result_mod.free(handle);

    try testing.expect(resolve(result, .artifact, 0) == null);
    try testing.expect(resolve(result, .manifest_json, 0) == null);
    // The explanation is always present, which is the point of the contract.
    try testing.expect(resolve(result, .reports_json, 0).?.len > 2);
}

test "an out-of-range or misapplied index resolves to nothing" {
    defer result_mod.freeAll();
    const handle = result_mod.convert(
        \\{"schema":1,"name":"note.md"}
    , "# Title\n");
    const result = result_mod.lookup(handle).?;
    defer _ = result_mod.free(handle);

    try testing.expectEqual(@as(u32, 0), resourceCount(result));
    try testing.expect(resolve(result, .resource_bytes, 0) == null);
    try testing.expect(resolve(result, .resource_bytes, 99) == null);
    // An index is meaningless for a non-resource view, and saying so beats
    // quietly ignoring it.
    try testing.expect(resolve(result, .artifact, 1) == null);
}
