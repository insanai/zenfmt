//! The adjacent artifact manifest (ZDS 0002, Adjacent Artifact Manifest).
//!
//! Every path output gets `<output>.zenfmt.json` beside it: provenance,
//! semantic document metadata, the canonical report stream, and versioned
//! plugin-owned preservation data. The digest binds plugin data to the exact
//! artifact bytes: data is never applied to different bytes merely because
//! filenames match. A missing manifest is normal input; a malformed or
//! stale one is ignored with a warning, never trusted.

const std = @import("std");
const assert = std.debug.assert;
const json = @import("json.zig");
const report = @import("report.zig");
const metadata = @import("metadata.zig");
const ast = @import("ast.zig");
const limits_mod = @import("limits.zig");

pub const schema_name = "ai.insan.zenfmt.artifact-manifest";
pub const schema_version: i64 = 1;
pub const ast_schema_name = "ai.insan.zenfmt.ast";
pub const ast_version: i64 = 1;
pub const digest_algorithm = "blake3-256";

pub const digest_length = 32;
pub const DigestHex = [digest_length * 2]u8;

pub fn digestHex(bytes: []const u8) DigestHex {
    var digest: [digest_length]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn digestHexFromHasher(hasher: *std.crypto.hash.Blake3) DigestHex {
    var digest: [digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub const ArtifactRef = struct {
    /// Display name: the file's basename, never an absolute path.
    name: []const u8,
    format: []const u8,
    digest_hex: DigestHex,
    plugin_id: []const u8,
};

/// One namespaced plugin-data value, canonically encoded.
pub const PluginEntry = struct {
    /// Reverse-DNS plugin id: the namespace key.
    id: []const u8,
    version: i64,
    /// The namespace's `data` value as canonical JSON bytes.
    data: []const u8,
};

pub const ArtifactManifest = struct {
    source: ArtifactRef,
    artifact: ArtifactRef,
    /// Canonical JSON object: the portable form of `Document.meta`.
    document_metadata: []const u8,
    reports: []const report.Report,
    plugins: []const PluginEntry,
};

// ------------------------------------------------------------- encoding

/// The version 1 envelope, as canonical JSON bytes. Deterministic: no
/// timestamps, hostnames, or absolute paths.
pub fn encode(gpa: std.mem.Allocator, m: ArtifactManifest) error{OutOfMemory}![]u8 {
    assert(m.document_metadata.len > 0);
    var w = json.WriteStream.init(gpa);
    defer w.deinit();

    try w.beginObject();
    try w.field("artifact");
    try encodeRef(&w, m.artifact);
    try w.field("ast");
    try w.beginObject();
    try w.field("schema");
    try w.string(ast_schema_name);
    try w.field("version");
    try w.integer(ast_version);
    try w.endObject();
    try w.field("document_metadata");
    try w.raw(m.document_metadata);
    try w.field("plugins");
    try w.beginObject();
    // Namespace keys must arrive sorted; the engine sorts entries by id.
    for (m.plugins) |entry| {
        try w.field(entry.id);
        try w.beginObject();
        try w.field("data");
        try w.raw(entry.data);
        try w.field("version");
        try w.integer(entry.version);
        try w.endObject();
    }
    try w.endObject();
    try w.field("reports");
    try w.beginArray();
    for (m.reports) |item| try report.writeJson(item, &w);
    try w.endArray();
    try w.field("schema");
    try w.string(schema_name);
    try w.field("schema_version");
    try w.integer(schema_version);
    try w.field("source");
    try encodeRef(&w, m.source);
    try w.endObject();

    return w.toOwnedSlice();
}

fn encodeRef(w: *json.WriteStream, ref: ArtifactRef) error{OutOfMemory}!void {
    try w.beginObject();
    try w.field("digest");
    try w.beginObject();
    try w.field("algorithm");
    try w.string(digest_algorithm);
    try w.field("value");
    try w.string(&ref.digest_hex);
    try w.endObject();
    try w.field("format");
    try w.string(ref.format);
    try w.field("name");
    try w.string(ref.name);
    try w.field("plugin");
    try w.beginObject();
    try w.field("id");
    try w.string(ref.plugin_id);
    try w.endObject();
    try w.endObject();
}

// -------------------------------------------------------------- loading

/// What an input-side manifest contributes to a conversion.
pub const Loaded = struct {
    artifact_format: []const u8,
    artifact_digest_hex: DigestHex,
    plugins: []const PluginEntry,
};

pub const LoadError = error{ OutOfMemory, Invalid };

/// Parses and structurally verifies an adjacent manifest under explicit
/// limits. The caller still must verify `artifact_digest_hex` against the
/// actual input bytes before trusting any plugin namespace.
pub fn load(
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: limits_mod.Limits,
) LoadError!Loaded {
    const root = json.parse(
        arena,
        bytes,
        limits.max_manifest_bytes,
        limits.max_manifest_depth,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed, error.TooDeep, error.TooLarge => return error.Invalid,
    };
    const top = objectMembers(root) orelse return error.Invalid;

    const schema = stringField(top, "schema") orelse return error.Invalid;
    if (!std.mem.eql(u8, schema, schema_name)) return error.Invalid;
    const version = integerField(top, "schema_version") orelse return error.Invalid;
    // A newer schema is not understood; the caller reports staleness.
    if (version != schema_version) return error.Invalid;

    const artifact = objectMembers(field(top, "artifact") orelse return error.Invalid) orelse
        return error.Invalid;
    const format = stringField(artifact, "format") orelse return error.Invalid;
    const digest = objectMembers(field(artifact, "digest") orelse return error.Invalid) orelse
        return error.Invalid;
    const algorithm = stringField(digest, "algorithm") orelse return error.Invalid;
    if (!std.mem.eql(u8, algorithm, digest_algorithm)) return error.Invalid;
    const value = stringField(digest, "value") orelse return error.Invalid;
    if (value.len != digest_length * 2) return error.Invalid;
    var digest_hex: DigestHex = undefined;
    for (value, 0..) |byte, i| {
        switch (byte) {
            '0'...'9', 'a'...'f' => digest_hex[i] = byte,
            else => return error.Invalid,
        }
    }

    var plugins: std.ArrayList(PluginEntry) = .empty;
    if (field(top, "plugins")) |plugins_value| {
        const members = objectMembers(plugins_value) orelse return error.Invalid;
        for (members) |member| {
            const entry = objectMembers(member.value) orelse return error.Invalid;
            const entry_version = integerField(entry, "version") orelse return error.Invalid;
            const data = field(entry, "data") orelse return error.Invalid;
            var w = json.WriteStream.init(arena);
            try json.writeValue(&w, data);
            const canonical = try w.toOwnedSlice();
            if (canonical.len > limits.max_plugin_data_bytes) return error.Invalid;
            try plugins.append(arena, .{
                .id = member.key,
                .version = entry_version,
                .data = canonical,
            });
        }
    }

    return .{
        .artifact_format = format,
        .artifact_digest_hex = digest_hex,
        .plugins = plugins.items,
    };
}

fn objectMembers(value: json.Value) ?[]json.Member {
    return switch (value) {
        .object => |members| members,
        else => null,
    };
}

fn field(members: []json.Member, key: []const u8) ?json.Value {
    for (members) |member| {
        if (std.mem.eql(u8, member.key, key)) return member.value;
    }
    return null;
}

fn stringField(members: []json.Member, key: []const u8) ?[]const u8 {
    return switch (field(members, key) orelse return null) {
        .string => |slice| slice,
        else => null,
    };
}

fn integerField(members: []json.Member, key: []const u8) ?i64 {
    return switch (field(members, key) orelse return null) {
        .integer => |int| int,
        else => null,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "encode emits the version 1 envelope canonically" {
    const manifest: ArtifactManifest = .{
        .source = .{
            .name = "report.docx",
            .format = "docx",
            .digest_hex = digestHex("source-bytes"),
            .plugin_id = "ai.insan.zenfmt.docx",
        },
        .artifact = .{
            .name = "report.md",
            .format = "markdown",
            .digest_hex = digestHex("artifact-bytes"),
            .plugin_id = "ai.insan.zenfmt.markdown",
        },
        .document_metadata = "{}",
        .reports = &.{},
        .plugins = &.{.{
            .id = "ai.insan.zenfmt.docx",
            .version = 1,
            .data = "{\"paragraph_styles\":{\"intro\":\"BodyText\"}}",
        }},
    };

    const bytes = try encode(testing.allocator, manifest);
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.startsWith(u8, bytes, "{\"artifact\":{\"digest\":"));
    try testing.expect(std.mem.indexOf(u8, bytes, "\"schema\":\"ai.insan.zenfmt.artifact-manifest\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"paragraph_styles\"") != null);
    // No whitespace anywhere: canonical form.
    try testing.expect(std.mem.indexOfAny(u8, bytes, " \n\t") == null);
}

test "a round trip through encode and load preserves plugin data" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest: ArtifactManifest = .{
        .source = .{
            .name = "a.docx",
            .format = "docx",
            .digest_hex = digestHex("in"),
            .plugin_id = "ai.insan.zenfmt.docx",
        },
        .artifact = .{
            .name = "a.md",
            .format = "markdown",
            .digest_hex = digestHex("out"),
            .plugin_id = "ai.insan.zenfmt.markdown",
        },
        .document_metadata = "{\"title\":\"A\"}",
        .reports = &.{},
        .plugins = &.{.{
            .id = "ai.insan.zenfmt.docx",
            .version = 3,
            .data = "{\"a\":[1,2],\"z\":true}",
        }},
    };
    const bytes = try encode(arena, manifest);

    const loaded = try load(arena, bytes, .{});
    try testing.expectEqualStrings("markdown", loaded.artifact_format);
    try testing.expectEqualStrings(&digestHex("out"), &loaded.artifact_digest_hex);
    try testing.expectEqual(@as(usize, 1), loaded.plugins.len);
    try testing.expectEqual(@as(i64, 3), loaded.plugins[0].version);
    try testing.expectEqualStrings("{\"a\":[1,2],\"z\":true}", loaded.plugins[0].data);
}

test "load refuses a wrong schema or digest algorithm" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.Invalid, load(arena, "{}", .{}));
    try testing.expectError(error.Invalid, load(arena, "[1,2]", .{}));
    try testing.expectError(error.Invalid, load(arena, "not json", .{}));
}
