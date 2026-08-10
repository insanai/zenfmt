//! The JSON result envelope (ZDS 0016, The conversion request).
//!
//! Field names and semantics deliberately mirror the Python `Conversion`
//! model of ZDS 0014: status, artifact, artifact_name, resources, manifest,
//! reports, exit_class, source_format, output_format. Reports serialize
//! through the engine's own writer, and the canonical manifest embeds
//! verbatim, so the server never rewrites either.

const std = @import("std");
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");

const reports_mod = @import("reports.zig");

/// The emission class of the selected writer, deciding whether the artifact
/// travels as a UTF-8 string or base64.
fn writerEmission(format: []const u8) core.plugin.Emission {
    inline for (zenfmt.Default.writers) |descriptor| {
        if (std.mem.eql(u8, descriptor.format, format)) return descriptor.emits;
    }
    return .utf8_text;
}

/// Serializes the success envelope for a memory-output conversion.
pub fn writeSuccess(
    arena: std.mem.Allocator,
    conversion: *const zenfmt.Conversion,
) ![]u8 {
    std.debug.assert(conversion.status == .success);
    const ensemble = conversion.ensemble.?;
    // The core write stream enforces canonical (sorted) member order, so
    // the fields appear alphabetically; consumers address them by name.
    var stream = zenfmt.json.WriteStream.init(arena);
    defer stream.deinit();
    try stream.beginObject();

    const output_format = conversion.output_format orelse "markdown";
    const binary = writerEmission(output_format) == .binary;
    try stream.field("artifact");
    if (binary) {
        try stream.string(try base64Alloc(arena, ensemble.artifact));
    } else {
        try stream.string(ensemble.artifact);
    }
    try stream.field("artifact_name");
    try stream.string(ensemble.artifact_name);
    if (binary) {
        try stream.field("encoding");
        try stream.string("base64");
    }
    try stream.field("exit_class");
    try stream.string(@tagName(conversion.exit_class));

    try stream.field("manifest");
    if (conversion.manifest_json) |manifest| {
        try stream.raw(manifest);
    } else {
        try stream.nullValue();
    }

    try stream.field("output_format");
    try stream.string(output_format);

    try stream.field("reports");
    try stream.beginArray();
    for (conversion.reports) |item| try zenfmt.report.writeJson(item, &stream);
    try stream.endArray();

    try stream.field("resources");
    try stream.beginArray();
    for (ensemble.resources) |resource| {
        try stream.beginObject();
        try stream.field("bytes");
        try stream.string(try base64Alloc(arena, resource.bytes));
        try stream.field("digest");
        try stream.string(&resource.digest_hex);
        try stream.field("name");
        try stream.string(resource.rel_path);
        try stream.endObject();
    }
    try stream.endArray();

    try stream.field("source_format");
    if (conversion.source_format) |format| try stream.string(format) else try stream.nullValue();
    try stream.field("status");
    try stream.string("success");
    try stream.endObject();
    return stream.toOwnedSlice();
}

/// Serializes the failure envelope for engine or server reports.
pub fn writeFailure(
    arena: std.mem.Allocator,
    reports: []const zenfmt.Report,
    exit_class: zenfmt.report.ExitClass,
) ![]u8 {
    var stream = zenfmt.json.WriteStream.init(arena);
    defer stream.deinit();
    try stream.beginObject();
    try stream.field("exit_class");
    try stream.string(@tagName(exit_class));
    try stream.field("reports");
    try stream.beginArray();
    for (reports) |item| try zenfmt.report.writeJson(item, &stream);
    try stream.endArray();
    try stream.field("status");
    try stream.string("failed");
    try stream.endObject();
    return stream.toOwnedSlice();
}

fn base64Alloc(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}

/// The HTTP status for a failed engine conversion (ZDS 0016): usage 400,
/// limit 413, conversion 422.
pub fn statusForExitClass(exit_class: zenfmt.report.ExitClass) u16 {
    return switch (exit_class) {
        .usage => 400,
        .limit => 413,
        .conversion => 422,
    };
}

/// The one-report failure envelope for a server-origin entry.
pub fn writeServerFailure(
    arena: std.mem.Allocator,
    entry: reports_mod.Entry,
) ![]u8 {
    return writeFailure(arena, &.{entry.report}, entry.report.exit_class);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the failure envelope parses and mirrors the Python model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try writeServerFailure(arena, reports_mod.busy);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    const object = parsed.value.object;
    try testing.expectEqualStrings("failed", object.get("status").?.string);
    try testing.expectEqualStrings("conversion", object.get("exit_class").?.string);
    const first = object.get("reports").?.array.items[0].object;
    try testing.expectEqualStrings("server.busy", first.get("code").?.string);
}

test "exit classes map to the record's statuses" {
    try testing.expectEqual(@as(u16, 400), statusForExitClass(.usage));
    try testing.expectEqual(@as(u16, 413), statusForExitClass(.limit));
    try testing.expectEqual(@as(u16, 422), statusForExitClass(.conversion));
}
