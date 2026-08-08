//! The browser module's capability document (ZDS 0015).
//!
//! Its own schema with its own version, because a target, an ABI version, and
//! a limit profile mean nothing to the in-process native bridge. What it
//! shares with that bridge is the generators, so neither can advertise a
//! format the compiled bundle does not have.
//!
//! The site renders its format list, its accepted extensions, and its
//! advanced controls from this document. Nothing about formats is written by
//! hand anywhere in the page.

const std = @import("std");
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");
const build_info = @import("zenfmt_build");
const shared = @import("zenfmt_capabilities");
const exports = @import("exports.zig");
const profile = @import("profile.zig");

pub const schema_version = 1;

/// What a browser module cannot do, stated positively so a caller does not
/// have to infer it from the absence of a function.
const unavailable = [_][]const u8{
    "clock",
    "filesystem",
    "network",
    "process",
    "randomness",
    "shared-memory",
    "terminal",
    "threads",
};

/// The pinned WebAssembly feature set. Recorded so a host can tell whether a
/// module predates a feature change rather than discovering it by trapping.
const cpu_features = [_][]const u8{
    "bulk_memory",
    "multivalue",
    "mutable_globals",
    "nontrapping_fptoint",
    "reference_types",
    "sign_ext",
};

pub const json: []const u8 = buildJson();

fn buildJson() []const u8 {
    @setEvalBranchQuota(200_000);
    return "{" ++
        "\"abi_version\":" ++ std.fmt.comptimePrint("{d}", .{exports.version()}) ++
        ",\"browser_profile\":" ++ shared.limitsJson(profile.browser) ++
        ",\"cpu_features\":" ++ shared.stringsJson(&cpu_features) ++
        ",\"default_output_format\":\"" ++ zenfmt.Browser.default_output_format ++ "\"" ++
        ",\"engine_limits\":" ++ shared.limitsJson(.{}) ++
        ",\"formats\":" ++ shared.formatsJson(
        zenfmt.Browser.readers,
        zenfmt.Browser.writers,
    ) ++
        ",\"hard_caps\":" ++ shared.hardCapsJson() ++
        ",\"revision\":\"" ++ build_info.revision ++ "\"" ++
        ",\"schema\":" ++ std.fmt.comptimePrint("{d}", .{schema_version}) ++
        ",\"target\":\"wasm32-freestanding\"" ++
        ",\"unavailable\":" ++ shared.stringsJson(&unavailable) ++
        ",\"version\":\"" ++ build_info.version ++ "\"" ++
        "}";
}

const testing = std.testing;

test "the capability document parses and describes the browser bundle" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;

    try testing.expectEqual(@as(i64, schema_version), root.get("schema").?.integer);
    try testing.expectEqualStrings(
        "wasm32-freestanding",
        root.get("target").?.string,
    );
    try testing.expectEqualStrings(build_info.version, root.get("version").?.string);
    try testing.expectEqual(
        @as(i64, exports.version()),
        root.get("abi_version").?.integer,
    );

    const formats = root.get("formats").?.array;
    try testing.expectEqual(zenfmt.Browser.readers.len, formats.items.len);
}

test "the browser module advertises exactly the formats the CLI ships" {
    try testing.expectEqual(zenfmt.Default.readers.len, zenfmt.Browser.readers.len);
    for (zenfmt.Default.readers, zenfmt.Browser.readers) |native, browser| {
        try testing.expectEqualStrings(native.format, browser.format);
    }
}

test "the published browser profile is the profile conversions run under" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        json,
        .{},
    );
    defer parsed.deinit();
    const published = parsed.value.object.get("browser_profile").?.object;
    inline for (@typeInfo(core.Limits).@"struct".fields) |field| {
        const expected: u64 = @field(profile.browser, field.name);
        const actual = published.get(field.name).?.integer;
        try testing.expectEqual(expected, @as(u64, @intCast(actual)));
    }
}
