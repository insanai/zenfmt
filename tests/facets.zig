//! End-to-end coverage for the IR v2 kernel additions (ZDS 0013): lazy
//! entities, sparse facet tables, extension nodes, and entity rebasing
//! through the rebuild transform.

const std = @import("std");
const testing = std.testing;
const core = @import("zenfmt_core");
const markdown = @import("zenfmt_markdown");

const ast = core.ast;
const facets = core.facets;

fn buildFacetedDocument(store: *ast.Store, gpa: std.mem.Allocator) !ast.Document {
    var tree = core.builder.Builder.init(gpa, store, .{});
    defer tree.deinit();
    const out: core.Emitter = .{ .builder = &tree };

    // Paragraph 0: styled and revised. Paragraph 1: bare, zero cost.
    const first = try out.beginParagraph();
    try out.text("styled");
    try out.attachStyle(first, .{ .name = "Heading 2", .language = "de" });
    try out.attachRevision(first, .{ .kind = .insertion, .author = "ada" });
    try out.attachRevision(first, .{ .kind = .comment, .note = "check this" });
    out.endBlock(first);

    const second = try out.beginParagraph();
    try out.text("bare");
    out.endBlock(second);

    return tree.finish();
}

test "facets bind through lazy entities and survive validation" {
    const gpa = testing.allocator;
    var store: ast.Store = .{};
    defer store.deinit(gpa);

    const doc = try buildFacetedDocument(&store, gpa);
    try ast.validate(&doc, .{});

    // Only the faceted node has an entity; the bare one cost nothing.
    try testing.expectEqual(@as(u32, 1), doc.block_entities.len);
    const entity = doc.blockEntity(@enumFromInt(0)).?;
    try testing.expectEqual(@as(?ast.EntityId, null), doc.blockEntity(@enumFromInt(1)));

    const style = doc.styleOf(entity).?;
    try testing.expectEqualStrings("Heading 2", store.textSlice(style.name));
    try testing.expectEqualStrings("de", store.textSlice(style.language));

    const revisions = doc.revisionsOf(entity);
    try testing.expectEqual(@as(usize, 2), revisions.len);
    try testing.expectEqual(facets.RevisionKind.insertion, revisions[0].kind);
    try testing.expectEqual(facets.RevisionKind.comment, revisions[1].kind);

    try testing.expectEqual(@as(?facets.Grid, null), doc.gridOf(entity));
}

test "entity bindings follow nodes through a rebuild and die with them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var store: ast.Store = .{};
    defer store.deinit(gpa);

    var tree = core.builder.Builder.init(gpa, &store, .{});
    defer tree.deinit();
    const out: core.Emitter = .{ .builder = &tree };

    // heading (styled), then an empty container (to be dropped), then a
    // paragraph (revised): the drop shifts the paragraph's node index.
    const heading = try out.beginHeading(2);
    try out.text("title");
    try out.attachStyle(heading, .{ .name = "Title" });
    out.endBlock(heading);

    const container = try out.beginBlock(.container);
    try out.attachStyle(container, .{ .name = "Doomed" });
    out.endBlock(container);

    const paragraph = try out.beginParagraph();
    try out.text("body");
    try out.attachRevision(paragraph, .{ .kind = .insertion, .author = "ada" });
    out.endBlock(paragraph);

    const doc = try tree.finish();
    try ast.validate(&doc, .{});
    try testing.expectEqual(@as(u32, 3), doc.block_entities.len);

    var pipeline: core.Pipeline = .empty;
    pipeline.add(core.filters.drop_empty_containers, .{});
    var reports = core.Reports.init(gpa, .{});
    const rebuilt = try pipeline.run(gpa, doc, &reports, .{});
    try ast.validate(&rebuilt, .{});

    // Two survivors, rebased to the new indices: heading 0, paragraph 1.
    try testing.expectEqual(@as(u32, 2), rebuilt.block_entities.len);
    const heading_entity = rebuilt.blockEntity(@enumFromInt(rebuilt.body.startRaw())).?;
    try testing.expectEqualStrings("Title", store.textSlice(rebuilt.styleOf(heading_entity).?.name));
    const paragraph_entity = rebuilt.blockEntity(@enumFromInt(rebuilt.body.startRaw() + 1)).?;
    try testing.expectEqual(
        facets.RevisionKind.insertion,
        rebuilt.revisionsOf(paragraph_entity)[0].kind,
    );

    // The dropped container's entity is bound to no node in the new
    // snapshot: its facet became unreachable, exactly per Lemma 2.
    var index = rebuilt.body.startRaw();
    while (index < rebuilt.body.endRaw()) : (index += 1) {
        if (rebuilt.blockEntity(@enumFromInt(index))) |entity| {
            const style = rebuilt.styleOf(entity);
            if (style) |row| {
                try testing.expect(!std.mem.eql(u8, store.textSlice(row.name), "Doomed"));
            }
        }
    }
}

test "the facet row budget refuses a facet bomb" {
    const gpa = testing.allocator;
    var store: ast.Store = .{};
    defer store.deinit(gpa);

    var tree = core.builder.Builder.init(gpa, &store, .{ .max_facet_rows = 2 });
    defer tree.deinit();
    const out: core.Emitter = .{ .builder = &tree };

    const paragraph = try out.beginParagraph();
    try out.text("x");
    try out.attachRevision(paragraph, .{ .kind = .comment, .note = "one" });
    try out.attachRevision(paragraph, .{ .kind = .comment, .note = "two" });
    try testing.expectError(
        error.LimitExceeded,
        out.attachRevision(paragraph, .{ .kind = .comment, .note = "three" }),
    );
}

test "the node budget refuses unbounded growth" {
    const gpa = testing.allocator;
    var store: ast.Store = .{};
    defer store.deinit(gpa);

    var tree = core.builder.Builder.init(gpa, &store, .{ .max_nodes = 3 });
    defer tree.deinit();
    const out: core.Emitter = .{ .builder = &tree };

    const paragraph = try out.beginParagraph();
    try out.text("ab");
    try testing.expectError(error.LimitExceeded, out.text("cd extra words"));
    _ = paragraph;
}

// ------------------------------------------------------------ extensions

fn readExtensionFixture(ctx: *core.ReadContext) core.ReadError!void {
    const details = try ctx.out.beginExtension("ai.insan.zenfmt.test", "details", 1);
    const summary = try ctx.out.beginParagraph();
    try ctx.out.text("Summary line");
    ctx.out.endBlock(summary);
    ctx.out.endBlock(details);
}

const extension_reader = core.Reader(.{
    .id = "ai.insan.zenfmt.test-extension",
    .format = "extfix",
    .extensions = &.{"extfix"},
    .read = readExtensionFixture,
});

const ExtensionBundle = core.Bundle(.{
    .readers = .{extension_reader},
    .writers = .{markdown.writer},
});

test "markdown lowers an unknown extension to its fallback with a note" {
    const gpa = testing.allocator;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = ExtensionBundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "widget.extfix", .data = "irrelevant" } },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.success, conversion.status);
    try testing.expectEqualStrings("Summary line\n", out.buffered());

    var found = false;
    for (conversion.reports) |report| {
        if (std.mem.eql(u8, report.code, "markdown.extension-fallback")) found = true;
    }
    try testing.expect(found);
}

test "the validator rejects an extension without a fallback" {
    const gpa = testing.allocator;
    var store: ast.Store = .{};
    defer store.deinit(gpa);
    try store.meta_maps.append(gpa, .{ .start = 0, .len = 0 });
    try store.text.appendSlice(gpa, "ai.insan.zenfmt.test/details");
    try store.extensions.append(gpa, .{
        .owner = .{ .start = 0, .len = 20 },
        .name = .{ .start = 21, .len = 7 },
        .version = 1,
    });
    try store.blocks.append(gpa, .{
        .tag = .extension,
        .payload = 0,
        .attrs = .none,
        .inlines = .empty,
        .subtree_len = 1,
    });

    const doc: ast.Document = .{
        .store = &store,
        .body = ast.BlockRange.init(0, 1),
        .meta = @enumFromInt(0),
        .plugin_data = .empty,
    };
    try testing.expectError(error.InvalidDocument, ast.validate(&doc, .{}));
}

test "the validator rejects same-owner extension nesting" {
    const gpa = testing.allocator;
    var store: ast.Store = .{};
    defer store.deinit(gpa);

    var tree = core.builder.Builder.init(gpa, &store, .{});
    defer tree.deinit();
    const out: core.Emitter = .{ .builder = &tree };

    const outer = try out.beginExtension("ai.insan.zenfmt.test", "outer", 1);
    const inner = try out.beginExtension("ai.insan.zenfmt.test", "inner", 1);
    const paragraph = try out.beginParagraph();
    try out.text("deep");
    out.endBlock(paragraph);
    out.endBlock(inner);
    out.endBlock(outer);

    const doc = try tree.finish();
    try testing.expectError(error.InvalidDocument, ast.validate(&doc, .{}));
}

// ------------------------------------------------------- manifest facets

fn readGridded(ctx: *core.ReadContext) core.ReadError!void {
    const table = try ctx.out.beginTable(&.{.default});
    const body = try ctx.out.beginTableBody(.{ .row_head_columns = 0, .head_rows = 0 });
    const row = try ctx.out.beginBlock(.table_row);
    const cell = try ctx.out.beginTableCell(.plain);
    try ctx.out.attachGrid(cell, .{
        .sheet = "Sheet1",
        .row = 3,
        .col = 1,
        .value_type = .number,
        .formula = "=SUM(B1:B3)",
        .cached = "6",
    });
    const plain = try ctx.out.beginPlain();
    try ctx.out.text("6");
    ctx.out.endBlock(plain);
    ctx.out.endBlock(cell);
    ctx.out.endBlock(row);
    ctx.out.endBlock(body);
    ctx.out.endBlock(table);
}

const grid_reader = core.Reader(.{
    .id = "ai.insan.zenfmt.test-grid",
    .format = "gridfix",
    .extensions = &.{"gridfix"},
    .read = readGridded,
});

const GridBundle = core.Bundle(.{
    .readers = .{grid_reader},
    .writers = .{markdown.writer},
});

test "the manifest summarizes carried-but-unused facets and preserves on request" {
    const gpa = testing.allocator;

    var summary_buffer: [4096]u8 = undefined;
    var summary_out = std.Io.Writer.fixed(&summary_buffer);
    var summary = GridBundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "cells.gridfix", .data = "x" } },
        .output = .{ .writer = &summary_out },
    });
    defer summary.deinit(gpa);
    try testing.expectEqual(core.Status.success, summary.status);
    const summary_manifest = summary.manifest_json.?;
    try testing.expect(std.mem.indexOf(u8, summary_manifest, "\"facets\":{\"grid\":{\"count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, summary_manifest, "\"unused\":true") != null);
    try testing.expect(std.mem.indexOf(u8, summary_manifest, "\"rows\"") == null);

    var full_buffer: [4096]u8 = undefined;
    var full_out = std.Io.Writer.fixed(&full_buffer);
    var full = GridBundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "cells.gridfix", .data = "x" } },
        .output = .{ .writer = &full_out },
        .preserve_facets = true,
    });
    defer full.deinit(gpa);
    try testing.expectEqual(core.Status.success, full.status);
    const full_manifest = full.manifest_json.?;
    try testing.expect(std.mem.indexOf(u8, full_manifest, "\"rows\":[{\"cached\":\"6\"") != null);
    try testing.expect(std.mem.indexOf(u8, full_manifest, "\"formula\":\"=SUM(B1:B3)\"") != null);
    try testing.expect(std.mem.indexOf(u8, full_manifest, "\"sheet\":\"Sheet1\"") != null);
}

// -------------------------------------------- writer-side preservation

fn readPreserving(ctx: *core.ReadContext) core.ReadError!void {
    const paragraph = try ctx.out.beginParagraph();
    try ctx.out.text("body");
    ctx.out.endBlock(paragraph);
    ctx.own_plugin_data = .{ .version = 1, .data = "{\"styles\":[\"Body\"]}" };
}

const preserving_reader = core.Reader(.{
    .id = "ai.insan.zenfmt.test-pres",
    .format = "presfix",
    .extensions = &.{"presfix"},
    .data_version = 1,
    .read = readPreserving,
});

fn writeRecovering(ctx: *core.WriteContext) core.WriteError!void {
    if (ctx.preservation("ai.insan.zenfmt.test-pres")) |entry| {
        try ctx.out.writeAll("recovered:");
        try ctx.out.writeAll(entry.data);
    } else {
        try ctx.out.writeAll("missing");
    }
    try ctx.out.writeAll("\n");
}

const recovering_writer = core.Writer(.{
    .id = "ai.insan.zenfmt.test-recover",
    .format = "recover",
    .extensions = &.{"rec"},
    .write = writeRecovering,
});

test "a writer recovers preservation data through the input manifest" {
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const dir = ".zig-cache/tmp/zenfmt-preservation-e2e";
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};

    // First conversion: the reader saves preservation data into the
    // output's adjacent manifest.
    const source_path = dir ++ "/doc.presfix";
    const middle_path = dir ++ "/doc.md";
    try cwd.writeFile(io, .{ .sub_path = source_path, .data = "irrelevant" });
    const FirstBundle = core.Bundle(.{
        .readers = .{preserving_reader},
        .writers = .{markdown.writer},
    });
    var first = FirstBundle.convert(gpa, io, .{
        .input = .{ .path = source_path },
        .output = .{ .path = middle_path },
    });
    defer first.deinit(gpa);
    try testing.expectEqual(core.Status.success, first.status);

    // Second conversion: a writer of the same family recovers the
    // namespace through the verified input manifest.
    const SecondBundle = core.Bundle(.{
        .readers = .{markdown.reader},
        .writers = .{recovering_writer},
    });
    const out_path = dir ++ "/doc.rec";
    var second = SecondBundle.convert(gpa, io, .{
        .input = .{ .path = middle_path },
        .output = .{ .path = out_path },
    });
    defer second.deinit(gpa);
    try testing.expectEqual(core.Status.success, second.status);

    const recovered = try cwd.readFileAlloc(io, out_path, gpa, .limited(4096));
    defer gpa.free(recovered);
    try testing.expectEqualStrings("recovered:{\"styles\":[\"Body\"]}\n", recovered);
}

test "stream state reports a complete stream" {
    const gpa = testing.allocator;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = GridBundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "cells.gridfix", .data = "x" } },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Conversion.StreamState.complete, conversion.stream);
}

test "distinct-owner extension nesting validates" {
    const gpa = testing.allocator;
    var store: ast.Store = .{};
    defer store.deinit(gpa);

    var tree = core.builder.Builder.init(gpa, &store, .{});
    defer tree.deinit();
    const out: core.Emitter = .{ .builder = &tree };

    const outer = try out.beginExtension("ai.insan.zenfmt.alpha", "outer", 1);
    const inner = try out.beginExtension("ai.insan.zenfmt.beta", "inner", 1);
    const paragraph = try out.beginParagraph();
    try out.text("deep");
    out.endBlock(paragraph);
    out.endBlock(inner);
    out.endBlock(outer);

    const doc = try tree.finish();
    try ast.validate(&doc, .{});
}
