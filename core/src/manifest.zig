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
const facets_mod = @import("facets.zig");
const lowering = @import("lowering.zig");
const limits_mod = @import("limits.zig");

pub const schema_name = "ai.insan.zenfmt.artifact-manifest";
/// Version 2 (ZDS 0013): adds the `facets` object carrying, per facet
/// kind, a digest-and-count summary of carried-but-unused facet tables,
/// with full rows under `--preserve-facets`.
pub const schema_version: i64 = 2;
pub const ast_schema_name = "ai.insan.zenfmt.ast";
/// Version 2 (ZDS 0013): extension nodes, entities, facets, resources.
pub const ast_version: i64 = 2;
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

/// One extracted media file committed beside the artifact.
pub const MediaFile = struct {
    /// Path relative to the artifact's directory, as written into the
    /// artifact's image URLs.
    path: []const u8,
    digest_hex: DigestHex,
};

/// One facet kind's manifest entry (ZDS 0013, manifest schema v2). The
/// default tier is the digest-and-count summary; `rows_json` carries the
/// full canonical rows only under `--preserve-facets`.
pub const FacetEntry = struct {
    kind: []const u8,
    digest_hex: DigestHex,
    count: u64,
    /// True when the selected writer declared no use for this facet kind:
    /// carried but unused, not lost.
    unused: bool,
    rows_json: ?[]const u8 = null,
};

pub const ArtifactManifest = struct {
    source: ArtifactRef,
    artifact: ArtifactRef,
    /// Canonical JSON object: the portable form of `Document.meta`.
    document_metadata: []const u8,
    reports: []const report.Report,
    plugins: []const PluginEntry,
    /// Extracted media files; empty when nothing was extracted, and the
    /// `media` key is then omitted so earlier manifests stay byte-stable.
    media: []const MediaFile = &.{},
    /// Per-kind facet summaries; the `facets` key is omitted when the
    /// document carries none.
    facets: []const FacetEntry = &.{},
};

// ------------------------------------------------------------- encoding

/// The version 2 envelope, as canonical JSON bytes. Deterministic: no
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
    if (m.facets.len > 0) {
        try w.field("facets");
        try w.beginObject();
        // `facetEntries` produces the entries in bytewise kind order; the
        // canonical writer asserts it.
        for (m.facets) |entry| {
            try w.field(entry.kind);
            try w.beginObject();
            try w.field("count");
            try w.integer(@intCast(entry.count));
            try w.field("digest");
            try w.beginObject();
            try w.field("algorithm");
            try w.string(digest_algorithm);
            try w.field("value");
            try w.string(&entry.digest_hex);
            try w.endObject();
            if (entry.rows_json) |rows| {
                try w.field("rows");
                try w.raw(rows);
            }
            try w.field("unused");
            try w.boolean(entry.unused);
            try w.endObject();
        }
        try w.endObject();
    }
    if (m.media.len > 0) {
        try w.field("media");
        try w.beginArray();
        for (m.media) |entry| {
            try w.beginObject();
            try w.field("digest");
            try w.beginObject();
            try w.field("algorithm");
            try w.string(digest_algorithm);
            try w.field("value");
            try w.string(&entry.digest_hex);
            try w.endObject();
            try w.field("path");
            try w.string(entry.path);
            try w.endObject();
        }
        try w.endArray();
    }
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

// --------------------------------------------------------------- facets

/// Builds the manifest's facet entries for one snapshot (ZDS 0013): for
/// each facet kind with rows reachable from the snapshot's entities, the
/// canonical row serialization is produced once, digested, counted, and
/// kept in full only when `preserve` is set. `consumed` is the selected
/// writer's declared facet list; everything else is carried but unused.
/// Entries come out in bytewise kind order, ready for the encoder.
pub fn facetEntries(
    arena: std.mem.Allocator,
    doc: *const ast.Document,
    consumed: []const lowering.FacetKind,
    preserve: bool,
) error{OutOfMemory}![]const FacetEntry {
    const reachable = try reachableEntities(arena, doc);
    if (reachable.len == 0) return &.{};

    var entries: std.ArrayList(FacetEntry) = .empty;
    // Bytewise order of the kind names: grid, layout, provenance,
    // revision, style.
    try appendFacetEntry(&entries, arena, doc, .grid, reachable, consumed, preserve);
    try appendFacetEntry(&entries, arena, doc, .layout, reachable, consumed, preserve);
    try appendFacetEntry(&entries, arena, doc, .provenance, reachable, consumed, preserve);
    try appendFacetEntry(&entries, arena, doc, .revision, reachable, consumed, preserve);
    try appendFacetEntry(&entries, arena, doc, .style, reachable, consumed, preserve);
    return entries.items;
}

/// The snapshot's entity ids, sorted, for reachability filtering.
fn reachableEntities(
    arena: std.mem.Allocator,
    doc: *const ast.Document,
) error{OutOfMemory}![]const u32 {
    const store = doc.store;
    const total = doc.block_entities.len + doc.inline_entities.len;
    if (total == 0) return &.{};
    var ids = try arena.alloc(u32, total);
    var index: usize = 0;
    const block_rows = store.block_entities.items[doc.block_entities.start..doc.block_entities.end()];
    for (block_rows) |row| {
        ids[index] = row.entity.raw();
        index += 1;
    }
    const inline_rows = store.inline_entities.items[doc.inline_entities.start..doc.inline_entities.end()];
    for (inline_rows) |row| {
        ids[index] = row.entity.raw();
        index += 1;
    }
    assert(index == total);
    std.mem.sort(u32, ids, {}, std.sort.asc(u32));
    return ids;
}

fn entityReachable(sorted: []const u32, entity: u32) bool {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] == entity) return true;
        if (sorted[mid] < entity) lo = mid + 1 else hi = mid;
    }
    return false;
}

fn appendFacetEntry(
    entries: *std.ArrayList(FacetEntry),
    arena: std.mem.Allocator,
    doc: *const ast.Document,
    comptime kind: lowering.FacetKind,
    reachable: []const u32,
    consumed: []const lowering.FacetKind,
    preserve: bool,
) error{OutOfMemory}!void {
    const store = doc.store;
    const rows = switch (kind) {
        .provenance => store.provenance_facets.items,
        .style => store.style_facets.items,
        .layout => store.layout_facets.items,
        .grid => store.grid_facets.items,
        .revision => store.revision_facets.items,
    };
    if (rows.len == 0) return;

    var w = json.WriteStream.init(arena);
    defer w.deinit();
    var count: u64 = 0;
    try w.beginArray();
    for (rows) |row| {
        if (!entityReachable(reachable, row.entity.raw())) continue;
        count += 1;
        try writeFacetRow(&w, store, kind, row);
    }
    try w.endArray();
    if (count == 0) return;
    const rows_json = try w.toOwnedSlice();

    var unused = true;
    for (consumed) |declared| {
        if (declared == kind) unused = false;
    }
    try entries.append(arena, .{
        .kind = @tagName(kind),
        .digest_hex = digestHex(rows_json),
        .count = count,
        .unused = unused,
        .rows_json = if (preserve) rows_json else null,
    });
}

fn writeFacetRow(
    w: *json.WriteStream,
    store: *const ast.Store,
    comptime kind: lowering.FacetKind,
    row: anytype,
) error{OutOfMemory}!void {
    try w.beginObject();
    switch (kind) {
        .provenance => {
            try w.field("byte_len");
            try w.integer(@intCast(row.byte_len));
            try w.field("byte_start");
            try w.integer(@intCast(row.byte_start));
            try w.field("confidence");
            try w.string(@tagName(row.confidence));
            try w.field("entity");
            try w.integer(row.entity.raw());
            try w.field("member");
            try w.string(store.textSlice(row.member));
            try w.field("plugin");
            try w.string(store.textSlice(row.plugin));
        },
        .style => {
            try w.field("direction");
            try w.string(@tagName(row.direction));
            try w.field("entity");
            try w.integer(row.entity.raw());
            try w.field("language");
            try w.string(store.textSlice(row.language));
            try w.field("name");
            try w.string(store.textSlice(row.name));
            try w.field("role");
            try w.string(store.textSlice(row.role));
        },
        .layout => {
            try w.field("entity");
            try w.integer(row.entity.raw());
            try w.field("height");
            try w.integer(row.height);
            try w.field("surface");
            try w.string(@tagName(row.surface));
            try w.field("surface_index");
            try w.integer(row.surface_index);
            try w.field("width");
            try w.integer(row.width);
            try w.field("x");
            try w.integer(row.x);
            try w.field("y");
            try w.integer(row.y);
            try w.field("z_order");
            try w.integer(row.z_order);
        },
        .grid => {
            try w.field("cached");
            try w.string(store.textSlice(row.cached));
            try w.field("col");
            try w.integer(row.col);
            try w.field("entity");
            try w.integer(row.entity.raw());
            try w.field("formula");
            try w.string(store.textSlice(row.formula));
            try w.field("merge_cols");
            try w.integer(row.merge_cols);
            try w.field("merge_rows");
            try w.integer(row.merge_rows);
            try w.field("row");
            try w.integer(row.row);
            try w.field("sheet");
            try w.string(store.textSlice(row.sheet));
            try w.field("value_type");
            try w.string(@tagName(row.value_type));
        },
        .revision => {
            try w.field("author");
            try w.string(store.textSlice(row.author));
            try w.field("entity");
            try w.integer(row.entity.raw());
            try w.field("kind");
            try w.string(@tagName(row.kind));
            try w.field("note");
            try w.string(store.textSlice(row.note));
            try w.field("timestamp");
            try w.string(store.textSlice(row.timestamp));
        },
    }
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

test "encode emits the version 2 envelope canonically" {
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
