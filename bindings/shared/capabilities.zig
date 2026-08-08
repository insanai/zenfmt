//! Comptime capability generators shared by every binding (ZDS 0014,
//! ZDS 0015).
//!
//! Each binding publishes its own capability document with its own schema and
//! version, because a browser module has a target, an ABI version, and a
//! limit profile that mean nothing to an in-process native bridge. What they
//! must not have is their own idea of which formats exist. So the *generators*
//! live here and read the compiled bundle's descriptor tables and the
//! engine's limit fields directly: adding a format to the default bundle
//! changes every binding's capability document at compile time, and no
//! binding can be edited into disagreeing with the engine it ships with.
//!
//! Everything here runs at comptime and returns string literals. Names come
//! from validated descriptor tables (lowercase ASCII), so no JSON escaping is
//! required.

const std = @import("std");
const core = @import("zenfmt_core");

pub fn extensionsJson(comptime extensions: []const []const u8) []const u8 {
    var out: []const u8 = "[";
    for (extensions, 0..) |extension, i| {
        out = out ++ (if (i == 0) "" else ",") ++ "\"" ++ extension ++ "\"";
    }
    return out ++ "]";
}

fn writerFor(
    comptime writers: []const core.plugin.WriterDescriptor,
    comptime format: []const u8,
) ?core.plugin.WriterDescriptor {
    for (writers) |writer| {
        if (std.mem.eql(u8, writer.format, format)) return writer;
    }
    return null;
}

fn readerFor(
    comptime readers: []const core.plugin.ReaderDescriptor,
    comptime format: []const u8,
) ?core.plugin.ReaderDescriptor {
    for (readers) |reader| {
        if (std.mem.eql(u8, reader.format, format)) return reader;
    }
    return null;
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

/// The `formats` array: reader registry order first, with a readable and
/// writable format merged into one entry, then any writer-only formats.
pub fn formatsJson(
    comptime readers: []const core.plugin.ReaderDescriptor,
    comptime writers: []const core.plugin.WriterDescriptor,
) []const u8 {
    var out: []const u8 = "[";
    for (readers, 0..) |reader, i| {
        out = out ++ (if (i == 0) "" else ",") ++ formatEntry(
            reader.format,
            reader.id,
            reader.extensions,
            reader,
            writerFor(writers, reader.format),
        );
    }
    for (writers) |writer| {
        if (readerFor(readers, writer.format) == null) {
            out = out ++ "," ++ formatEntry(
                writer.format,
                writer.id,
                writer.extensions,
                null,
                writer,
            );
        }
    }
    return out ++ "]";
}

/// Every limit field and its value, in declaration order.
pub fn limitsJson(comptime values: core.Limits) []const u8 {
    var out: []const u8 = "{";
    for (@typeInfo(core.Limits).@"struct".fields, 0..) |field, i| {
        out = out ++ (if (i == 0) "" else ",") ++ "\"" ++ field.name ++
            "\":" ++ std.fmt.comptimePrint(
            "{d}",
            .{@field(values, field.name)},
        );
    }
    return out ++ "}";
}

/// The compile-time safety caps, for the fields that have one.
pub fn hardCapsJson() []const u8 {
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

/// A JSON string array from a comptime list of literals.
pub fn stringsJson(comptime values: []const []const u8) []const u8 {
    return extensionsJson(values);
}
