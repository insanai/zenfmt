//! Document metadata (ZDS 0002, The text pool and side tables).
//!
//! Metadata is a zenfmt tagged value model: JSON's scalar vocabulary plus
//! rich inline and block values. Values live in the conversion's append-only
//! store; a `MetaValueIndex` is stable for the life of the conversion. Maps
//! serialize with keys in bytewise UTF-8 order for deterministic output;
//! their semantic order is insignificant.

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const json = @import("json.zig");
const payload = @import("payload.zig");

pub const MetaValueTag = enum(u8) {
    null,
    boolean,
    integer,
    float,
    string,
    inlines,
    blocks,
    map,
    list,
};

pub const MetaValueIndex = enum(u32) { _ };
pub const MetaMapIndex = enum(u32) { _ };

pub const MetaValue = struct {
    tag: MetaValueTag,
    /// Index into the table selected by `tag`: map entries, value indices,
    /// bools, strings, inline ranges, or block ranges. Reached only through
    /// `ast.Document.metaValue`.
    payload: u32,
};

pub const MetaEntry = struct {
    key: ast.ByteRange,
    value: MetaValueIndex,
};

/// A contiguous run of `MetaEntry` rows: one map.
pub const MetaEntryRange = struct {
    start: u32,
    len: u32,
};

/// A contiguous run of `MetaValueIndex` rows: one list.
pub const MetaItemRange = struct {
    start: u32,
    len: u32,
};

/// The typed public view of one metadata value.
pub const MetaView = union(MetaValueTag) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: ast.ByteRange,
    inlines: ast.InlineRange,
    blocks: ast.BlockRange,
    map: MetaMapIndex,
    list: MetaItemRange,
};

// ------------------------------------------------------- JSON encoding
//
// The portable form of `Document.meta` for the artifact manifest. JSON
// scalars, lists, and maps use their natural representation; rich inline and
// block values use a zenfmt-owned tagged object:
// `{"$type":"inlines","value":[{"text":"Report","type":"text"}]}`.
// Emission is non-recursive: one explicit task stack, and every object's
// keys are emitted in bytewise order because the canonical stream demands
// it.

const Forest = struct {
    cursor: u32,
    end: u32,
};

const FieldArray = struct {
    name: []const u8,
    forest: Forest,
    kind: enum { inline_forest, block_forest },
};

const Task = union(enum) {
    value: MetaValueIndex,
    entry: MetaEntry,
    inline_node: u32,
    block_node: u32,
    inline_forest: Forest,
    block_forest: Forest,
    finish_inline: u32,
    finish_block: u32,
    citation: u32,
    /// Closes the citations array and opens the content array.
    citation_content_bridge,
    /// Closes a prefix array and opens the suffix array within one row.
    citation_suffix_bridge,
    end_array,
    end_object,
};

/// Writes one metadata map — usually `Document.meta` — as a canonical JSON
/// object.
pub fn writeMetaMap(
    gpa: std.mem.Allocator,
    doc: *const ast.Document,
    map: MetaMapIndex,
    w: *json.WriteStream,
) error{OutOfMemory}!void {
    var tasks: std.ArrayList(Task) = .empty;
    defer tasks.deinit(gpa);

    try w.beginObject();
    try tasks.append(gpa, .end_object);
    try pushEntries(gpa, doc, &tasks, map);

    while (tasks.pop()) |task| {
        switch (task) {
            .end_array => try w.endArray(),
            .end_object => try w.endObject(),
            .entry => |entry| {
                try w.field(doc.text(entry.key));
                try tasks.append(gpa, .{ .value = entry.value });
            },
            .value => |index| try writeValueTask(gpa, doc, &tasks, w, index),
            .inline_forest => |forest| {
                if (forest.cursor == forest.end) continue;
                const lengths = doc.store.inlines.items(.subtree_len);
                const len = lengths[forest.cursor];
                try tasks.append(gpa, .{ .inline_forest = .{
                    .cursor = forest.cursor + len,
                    .end = forest.end,
                } });
                try tasks.append(gpa, .{ .inline_node = forest.cursor });
            },
            .block_forest => |forest| {
                if (forest.cursor == forest.end) continue;
                const lengths = doc.store.blocks.items(.subtree_len);
                const len = lengths[forest.cursor];
                try tasks.append(gpa, .{ .block_forest = .{
                    .cursor = forest.cursor + len,
                    .end = forest.end,
                } });
                try tasks.append(gpa, .{ .block_node = forest.cursor });
            },
            .inline_node => |index| try writeInlineNode(gpa, doc, &tasks, w, index),
            .block_node => |index| try writeBlockNode(gpa, doc, &tasks, w, index),
            .finish_inline => |index| try finishInline(doc, w, index),
            .finish_block => |index| try finishBlock(doc, w, index),
            .citation => |index| try writeCitation(gpa, doc, &tasks, w, index),
            .citation_content_bridge => {
                try w.endArray();
                try w.field("content");
                try w.beginArray();
            },
            .citation_suffix_bridge => {
                try w.endArray();
                try w.field("suffix");
                try w.beginArray();
            },
        }
    }
}

fn pushEntries(
    gpa: std.mem.Allocator,
    doc: *const ast.Document,
    tasks: *std.ArrayList(Task),
    map: MetaMapIndex,
) error{OutOfMemory}!void {
    const entries = doc.metaEntries(map);
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        try tasks.append(gpa, .{ .entry = entries[i] });
    }
}

fn writeValueTask(
    gpa: std.mem.Allocator,
    doc: *const ast.Document,
    tasks: *std.ArrayList(Task),
    w: *json.WriteStream,
    index: MetaValueIndex,
) error{OutOfMemory}!void {
    switch (doc.metaValue(index)) {
        .null => try w.nullValue(),
        .boolean => |value| try w.boolean(value),
        .integer => |value| try w.integer(value),
        .float => |value| try w.float(value),
        .string => |range| try w.string(doc.text(range)),
        .map => |nested| {
            try w.beginObject();
            try tasks.append(gpa, .end_object);
            try pushEntries(gpa, doc, tasks, nested);
        },
        .list => |range| {
            try w.beginArray();
            try tasks.append(gpa, .end_array);
            const items = doc.store.meta_items.items[range.start .. range.start + range.len];
            var i = items.len;
            while (i > 0) {
                i -= 1;
                try tasks.append(gpa, .{ .value = items[i] });
            }
        },
        .inlines => |range| {
            try w.beginObject();
            try w.field("$type");
            try w.string("inlines");
            try w.field("value");
            try w.beginArray();
            try tasks.append(gpa, .end_object);
            try tasks.append(gpa, .end_array);
            try tasks.append(gpa, .{ .inline_forest = .{
                .cursor = range.startRaw(),
                .end = range.endRaw(),
            } });
        },
        .blocks => |range| {
            try w.beginObject();
            try w.field("$type");
            try w.string("blocks");
            try w.field("value");
            try w.beginArray();
            try tasks.append(gpa, .end_object);
            try tasks.append(gpa, .end_array);
            try tasks.append(gpa, .{ .block_forest = .{
                .cursor = range.startRaw(),
                .end = range.endRaw(),
            } });
        },
    }
}

fn writeAttrsField(
    doc: *const ast.Document,
    w: *json.WriteStream,
    index: ast.OptionalAttrsIndex,
) error{OutOfMemory}!void {
    const attrs = doc.attrsOf(index);
    if (index == .none) return;
    try w.field("attrs");
    try w.beginObject();
    try w.field("classes");
    try w.beginArray();
    const classes = doc.store.strings.items[attrs.classes.start .. attrs.classes.start + attrs.classes.len];
    for (classes) |class| try w.string(doc.text(class));
    try w.endArray();
    try w.field("id");
    try w.string(doc.text(attrs.id));
    try w.field("pairs");
    try w.beginArray();
    const pairs = doc.store.pairs.items[attrs.pairs.start .. attrs.pairs.start + attrs.pairs.len];
    for (pairs) |pair| {
        try w.beginArray();
        try w.string(doc.text(pair.key));
        try w.string(doc.text(pair.value));
        try w.endArray();
    }
    try w.endArray();
    try w.endObject();
}

fn contentForest(
    gpa: std.mem.Allocator,
    tasks: *std.ArrayList(Task),
    w: *json.WriteStream,
    finish: Task,
    forest: Task,
) error{OutOfMemory}!void {
    try w.field("content");
    try w.beginArray();
    try tasks.append(gpa, finish);
    try tasks.append(gpa, .end_array);
    try tasks.append(gpa, forest);
}

fn writeInlineNode(
    gpa: std.mem.Allocator,
    doc: *const ast.Document,
    tasks: *std.ArrayList(Task),
    w: *json.WriteStream,
    index: u32,
) error{OutOfMemory}!void {
    const view = doc.inlineView(@enumFromInt(index));
    try w.beginObject();
    switch (view.content) {
        .text => |range| {
            try writeAttrsField(doc, w, view.attrs);
            try w.field("text");
            try w.string(doc.text(range));
            try typeField(w, @tagName(view.content));
            try w.endObject();
        },
        .space, .soft_break, .hard_break => {
            try writeAttrsField(doc, w, view.attrs);
            try typeField(w, @tagName(view.content));
            try w.endObject();
        },
        .code => |range| {
            try writeAttrsField(doc, w, view.attrs);
            try w.field("text");
            try w.string(doc.text(range));
            try typeField(w, "code");
            try w.endObject();
        },
        .math => |math| {
            try writeAttrsField(doc, w, view.attrs);
            try w.field("kind");
            try w.string(@tagName(math.kind));
            try w.field("text");
            try w.string(doc.text(math.text));
            try typeField(w, "math");
            try w.endObject();
        },
        .raw => |raw| {
            try writeAttrsField(doc, w, view.attrs);
            try w.field("format");
            try w.string(doc.text(raw.format));
            try w.field("text");
            try w.string(doc.text(raw.text));
            try typeField(w, "raw");
            try w.endObject();
        },
        .note => |blocks| {
            try writeAttrsField(doc, w, view.attrs);
            try w.field("blocks");
            try w.beginArray();
            try tasks.append(gpa, .{ .finish_inline = index });
            try tasks.append(gpa, .end_array);
            try tasks.append(gpa, .{ .block_forest = .{
                .cursor = blocks.startRaw(),
                .end = blocks.endRaw(),
            } });
        },
        .emphasis,
        .underline,
        .strong,
        .strikethrough,
        .superscript,
        .subscript,
        .small_caps,
        .span,
        => |children| {
            try writeAttrsField(doc, w, view.attrs);
            try contentForest(gpa, tasks, w, .{ .finish_inline = index }, .{
                .inline_forest = .{ .cursor = children.startRaw(), .end = children.endRaw() },
            });
        },
        .quote => |quote| {
            try writeAttrsField(doc, w, view.attrs);
            try contentForest(gpa, tasks, w, .{ .finish_inline = index }, .{
                .inline_forest = .{
                    .cursor = quote.children.startRaw(),
                    .end = quote.children.endRaw(),
                },
            });
        },
        .link, .image => |target| {
            try writeAttrsField(doc, w, view.attrs);
            try contentForest(gpa, tasks, w, .{ .finish_inline = index }, .{
                .inline_forest = .{
                    .cursor = target.children.startRaw(),
                    .end = target.children.endRaw(),
                },
            });
        },
        .citation => |citation| {
            try writeAttrsField(doc, w, view.attrs);
            try w.field("citations");
            try w.beginArray();
            // After the rows: close the array, then the content forest, then
            // the trailing fields. Pushed in reverse.
            try tasks.append(gpa, .{ .finish_inline = index });
            try tasks.append(gpa, .end_array);
            try tasks.append(gpa, .{ .inline_forest = .{
                .cursor = citation.children.startRaw(),
                .end = citation.children.endRaw(),
            } });
            try tasks.append(gpa, .citation_content_bridge);
            var i = citation.citations.start + citation.citations.len;
            while (i > citation.citations.start) {
                i -= 1;
                try tasks.append(gpa, .{ .citation = i });
            }
        },
    }
}

fn writeCitation(
    gpa: std.mem.Allocator,
    doc: *const ast.Document,
    tasks: *std.ArrayList(Task),
    w: *json.WriteStream,
    index: u32,
) error{OutOfMemory}!void {
    const citation = doc.store.citations.items[index];
    try w.beginObject();
    try w.field("id");
    try w.string(doc.text(citation.id));
    try w.field("mode");
    try w.string(@tagName(citation.mode));
    try w.field("prefix");
    try w.beginArray();
    // prefix forest, close, suffix field, suffix forest, close, close row.
    try tasks.append(gpa, .end_object);
    try tasks.append(gpa, .end_array);
    try tasks.append(gpa, .{ .inline_forest = .{
        .cursor = citation.suffix.startRaw(),
        .end = citation.suffix.endRaw(),
    } });
    try tasks.append(gpa, .citation_suffix_bridge);
    try tasks.append(gpa, .{ .inline_forest = .{
        .cursor = citation.prefix.startRaw(),
        .end = citation.prefix.endRaw(),
    } });
}

fn finishInline(
    doc: *const ast.Document,
    w: *json.WriteStream,
    index: u32,
) error{OutOfMemory}!void {
    const view = doc.inlineView(@enumFromInt(index));
    switch (view.content) {
        .note => try typeField(w, "note"),
        .emphasis,
        .underline,
        .strong,
        .strikethrough,
        .superscript,
        .subscript,
        .small_caps,
        .span,
        .citation,
        => try typeField(w, @tagName(view.content)),
        .quote => |quote| {
            try w.field("kind");
            try w.string(@tagName(quote.kind));
            try typeField(w, "quote");
        },
        .link, .image => |target| {
            try w.field("title");
            try w.string(doc.text(target.title));
            try typeField(w, @tagName(view.content));
            try w.field("url");
            try w.string(doc.text(target.url));
        },
        else => unreachable,
    }
    try w.endObject();
}

fn writeBlockNode(
    gpa: std.mem.Allocator,
    doc: *const ast.Document,
    tasks: *std.ArrayList(Task),
    w: *json.WriteStream,
    index: u32,
) error{OutOfMemory}!void {
    const view = doc.block(@enumFromInt(index));
    try w.beginObject();
    switch (view.content) {
        .thematic_break => {
            try writeAttrsField(doc, w, view.attrs);
            try typeField(w, "thematic_break");
            try w.endObject();
        },
        .code_block => |range| {
            try writeAttrsField(doc, w, view.attrs);
            try w.field("text");
            try w.string(doc.text(range));
            try typeField(w, "code_block");
            try w.endObject();
        },
        .raw_block => |raw| {
            try writeAttrsField(doc, w, view.attrs);
            try w.field("format");
            try w.string(doc.text(raw.format));
            try w.field("text");
            try w.string(doc.text(raw.text));
            try typeField(w, "raw_block");
            try w.endObject();
        },
        .plain, .paragraph, .line, .definition_term => |inlines| {
            try writeAttrsField(doc, w, view.attrs);
            try contentForest(gpa, tasks, w, .{ .finish_block = index }, .{
                .inline_forest = .{ .cursor = inlines.startRaw(), .end = inlines.endRaw() },
            });
        },
        .heading => |heading| {
            try writeAttrsField(doc, w, view.attrs);
            try contentForest(gpa, tasks, w, .{ .finish_block = index }, .{
                .inline_forest = .{
                    .cursor = heading.inlines.startRaw(),
                    .end = heading.inlines.endRaw(),
                },
            });
        },
        .line_block,
        .quote,
        .definition_list,
        .figure,
        .container,
        .list_item,
        .definition_entry,
        .definition_body,
        .caption,
        .table_head,
        .table_foot,
        .table_row,
        => |blocks| {
            try writeAttrsField(doc, w, view.attrs);
            try contentForest(gpa, tasks, w, .{ .finish_block = index }, .{
                .block_forest = .{ .cursor = blocks.startRaw(), .end = blocks.endRaw() },
            });
        },
        .list => |list| {
            try writeAttrsField(doc, w, view.attrs);
            try contentForest(gpa, tasks, w, .{ .finish_block = index }, .{
                .block_forest = .{ .cursor = list.items.startRaw(), .end = list.items.endRaw() },
            });
        },
        .table => |table| {
            try writeAttrsField(doc, w, view.attrs);
            try w.field("columns");
            try w.beginArray();
            const columns = doc.store.columns.items[table.columns.start .. table.columns.start + table.columns.len];
            for (columns) |column| try w.string(@tagName(column.alignment));
            try w.endArray();
            try contentForest(gpa, tasks, w, .{ .finish_block = index }, .{
                .block_forest = .{
                    .cursor = table.content.startRaw(),
                    .end = table.content.endRaw(),
                },
            });
        },
        .table_body => |body| {
            try writeAttrsField(doc, w, view.attrs);
            try contentForest(gpa, tasks, w, .{ .finish_block = index }, .{
                .block_forest = .{ .cursor = body.rows.startRaw(), .end = body.rows.endRaw() },
            });
        },
        .table_cell => |cell| {
            try w.field("alignment");
            try w.string(@tagName(cell.alignment));
            try writeAttrsField(doc, w, view.attrs);
            try w.field("col_span");
            try w.integer(cell.col_span);
            try contentForest(gpa, tasks, w, .{ .finish_block = index }, .{
                .block_forest = .{ .cursor = cell.blocks.startRaw(), .end = cell.blocks.endRaw() },
            });
        },
    }
}

fn finishBlock(
    doc: *const ast.Document,
    w: *json.WriteStream,
    index: u32,
) error{OutOfMemory}!void {
    const view = doc.block(@enumFromInt(index));
    switch (view.content) {
        .plain,
        .paragraph,
        .line,
        .definition_term,
        .line_block,
        .quote,
        .definition_list,
        .figure,
        .container,
        .list_item,
        .definition_entry,
        .definition_body,
        .caption,
        .table_head,
        .table_foot,
        .table_row,
        .table,
        => try typeField(w, @tagName(view.content)),
        .heading => |heading| {
            try w.field("level");
            try w.integer(heading.level);
            try typeField(w, "heading");
        },
        .list => |list| {
            try w.field("delimiter");
            try w.string(@tagName(list.delimiter));
            try w.field("kind");
            try w.string(@tagName(list.kind));
            try w.field("start");
            try w.integer(list.start);
            try w.field("style");
            try w.string(@tagName(list.style));
            try typeField(w, "list");
        },
        .table_body => |body| {
            try w.field("head_rows");
            try w.integer(body.head_rows);
            try w.field("row_head_columns");
            try w.integer(body.row_head_columns);
            try typeField(w, "table_body");
        },
        .table_cell => |cell| {
            try w.field("row_span");
            try w.integer(cell.row_span);
            try typeField(w, "table_cell");
        },
        else => unreachable,
    }
    try w.endObject();
}

fn typeField(w: *json.WriteStream, name: []const u8) error{OutOfMemory}!void {
    try w.field("type");
    try w.string(name);
}

test "meta value rows stay compact" {
    // The tag byte plus the payload word; the value model must not grow a
    // pointer. Field sizes are what the store pays, padding aside.
    try std.testing.expectEqual(1, @sizeOf(MetaValueTag));
    try std.testing.expectEqual(4, @sizeOf(u32));
    try std.testing.expect(@sizeOf(MetaValue) <= 8);
}

test "string metadata encodes as a canonical JSON object" {
    const testing = std.testing;
    const builder_mod = @import("builder.zig");

    var store: ast.Store = .{};
    defer store.deinit(testing.allocator);
    var b = builder_mod.Builder.init(testing.allocator, &store, .{});
    defer b.deinit();
    try b.metaString("title", "A \"Report\"");
    try b.metaString("author", "Zen");
    const doc = try b.finish();

    var w = json.WriteStream.init(testing.allocator);
    defer w.deinit();
    try writeMetaMap(testing.allocator, &doc, doc.meta, &w);
    const bytes = try w.toOwnedSlice();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(
        "{\"author\":\"Zen\",\"title\":\"A \\\"Report\\\"\"}",
        bytes,
    );
}
