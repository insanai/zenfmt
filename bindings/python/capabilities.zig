//! Capability metadata for the Python bridge (ZDS 0014).
//!
//! One canonical JSON document generated from the default bundle's descriptor
//! tables and the engine's limit defaults, using the generators shared with
//! every other binding. There is no runtime registry and no hand-maintained
//! Python format table: adding a format to the default Zig bundle changes
//! this string at compile time.

const std = @import("std");
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");
const build_info = @import("zenfmt_build");
const shared = @import("zenfmt_capabilities");

pub const schema_version = 1;

/// The complete capability JSON, embedded in the shared library's constant
/// data.
pub const json: []const u8 = buildJson();

fn buildJson() []const u8 {
    @setEvalBranchQuota(200_000);
    return "{" ++
        "\"default_output_format\":\"" ++ zenfmt.default_output_format ++ "\"" ++
        ",\"formats\":" ++ shared.formatsJson(
        zenfmt.Default.readers,
        zenfmt.Default.writers,
    ) ++
        ",\"hard_caps\":" ++ shared.hardCapsJson() ++
        ",\"limits\":" ++ shared.limitsJson(.{}) ++
        ",\"schema\":" ++ std.fmt.comptimePrint("{d}", .{schema_version}) ++
        ",\"version\":\"" ++ build_info.version ++ "\"" ++
        "}";
}

test "capability JSON parses and describes the default bundle" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(
        @as(i64, schema_version),
        root.get("schema").?.integer,
    );
    try std.testing.expectEqualStrings(
        build_info.version,
        root.get("version").?.string,
    );
    try std.testing.expectEqualStrings(
        "markdown",
        root.get("default_output_format").?.string,
    );
    const formats = root.get("formats").?.array;
    try std.testing.expectEqual(zenfmt.Default.readers.len, formats.items.len);
    var writable: usize = 0;
    for (formats.items) |entry| {
        if (entry.object.get("write").?.bool) writable += 1;
    }
    try std.testing.expectEqual(zenfmt.Default.writers.len, writable);
    const limit_values = root.get("limits").?.object;
    try std.testing.expectEqual(
        @typeInfo(core.Limits).@"struct".fields.len,
        limit_values.count(),
    );
}
