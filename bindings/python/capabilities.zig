//! Comptime capability metadata for the Python bridge (ZDS 0014).
//!
//! One canonical JSON document generated from the default bundle's
//! descriptor tables and the engine's limit defaults. There is no runtime
//! registry and no hand-maintained Python format table: adding a format to
//! the default Zig bundle changes this string at compile time.

const std = @import("std");
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");
const build_info = @import("zenfmt_build");

pub const schema_version = 1;

/// The complete capability JSON, embedded in the shared library's constant
/// data. Names come from validated descriptor tables (lowercase ASCII), so
/// no JSON escaping is required.
pub const json: []const u8 = buildJson();

fn writerFor(comptime format: []const u8) ?core.plugin.WriterDescriptor {
    for (zenfmt.Default.writers) |writer| {
        if (std.mem.eql(u8, writer.format, format)) return writer;
    }
    return null;
}

fn readerFor(comptime format: []const u8) ?core.plugin.ReaderDescriptor {
    for (zenfmt.Default.readers) |reader| {
        if (std.mem.eql(u8, reader.format, format)) return reader;
    }
    return null;
}

fn extensionsJson(comptime extensions: []const []const u8) []const u8 {
    var out: []const u8 = "[";
    for (extensions, 0..) |extension, i| {
        out = out ++ (if (i == 0) "" else ",") ++ "\"" ++ extension ++ "\"";
    }
    return out ++ "]";
}

fn formatEntry(
    comptime format: []const u8,
    comptime plugin_id: []const u8,
    comptime extensions: []const []const u8,
    comptime reader: ?core.plugin.ReaderDescriptor,
    comptime writer: ?core.plugin.WriterDescriptor,
) []const u8 {
    return "{" ++
        "\"extensions\":" ++ extensionsJson(extensions) ++
        ",\"format\":\"" ++ format ++ "\"" ++
        ",\"plugin_id\":\"" ++ plugin_id ++ "\"" ++
        ",\"primary_extension\":" ++ (if (writer) |value|
        "\"" ++ value.extensions[0] ++ "\""
    else
        "null") ++
        ",\"read\":" ++ (if (reader != null) "true" else "false") ++
        ",\"seekable_input\":" ++ (if (reader) |value|
        (if (value.input == .seekable) "true" else "false")
    else
        "false") ++
        ",\"text_writer\":" ++ (if (writer) |value|
        (if (value.emits == .utf8_text) "true" else "false")
    else
        "null") ++
        ",\"write\":" ++ (if (writer != null) "true" else "false") ++
        "}";
}

fn limitsJson() []const u8 {
    const defaults: core.Limits = .{};
    var out: []const u8 = "{";
    for (@typeInfo(core.Limits).@"struct".fields, 0..) |field, i| {
        out = out ++ (if (i == 0) "" else ",") ++ "\"" ++ field.name ++
            "\":" ++ std.fmt.comptimePrint(
            "{d}",
            .{@field(defaults, field.name)},
        );
    }
    return out ++ "}";
}

fn hardCapsJson() []const u8 {
    var out: []const u8 = "{";
    var first = true;
    for (@typeInfo(core.Limits).@"struct".fields) |field| {
        const cap = core.Limits.hardCap(@field(core.Limits.Field, field.name));
        if (cap) |value| {
            out = out ++ (if (first) "" else ",") ++ "\"" ++ field.name ++
                "\":" ++ std.fmt.comptimePrint("{d}", .{value});
            first = false;
        }
    }
    return out ++ "}";
}

fn buildJson() []const u8 {
    @setEvalBranchQuota(200_000);
    var formats: []const u8 = "[";
    // Reader registry order first; a format readable and writable becomes
    // one merged entry.
    for (zenfmt.Default.readers, 0..) |reader, i| {
        formats = formats ++ (if (i == 0) "" else ",") ++ formatEntry(
            reader.format,
            reader.id,
            reader.extensions,
            reader,
            writerFor(reader.format),
        );
    }
    // Writer-only formats append after the readers.
    for (zenfmt.Default.writers) |writer| {
        if (readerFor(writer.format) == null) {
            formats = formats ++ "," ++ formatEntry(
                writer.format,
                writer.id,
                writer.extensions,
                null,
                writer,
            );
        }
    }
    formats = formats ++ "]";
    return "{" ++
        "\"default_output_format\":\"" ++ zenfmt.default_output_format ++ "\"" ++
        ",\"formats\":" ++ formats ++
        ",\"hard_caps\":" ++ hardCapsJson() ++
        ",\"limits\":" ++ limitsJson() ++
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
