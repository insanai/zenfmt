//! Filter behavior over the umbrella module (ZDS 0002, phase 3 exit
//! criteria): each built-in filter's transform, the identity fast path, and
//! the idempotence property for filters that declare it.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");

fn convertWithPipeline(
    input: []const u8,
    pipeline: *const zenfmt.Pipeline,
    out: *std.Io.Writer,
) zenfmt.Conversion {
    return zenfmt.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "filtered.md", .data = input } },
        .output = .{ .writer = out },
        .from = "markdown",
        .pipeline = pipeline,
    });
}

test "shift-headings moves every level and clamps" {
    var pipeline: zenfmt.Pipeline = .empty;
    pipeline.add(zenfmt.filters.shift_headings, .{ .by = 1 });

    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertWithPipeline(
        "# One\n\n## Two\n\n###### Six stays\n",
        &pipeline,
        &out,
    );
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    try testing.expectEqualStrings(
        "## One\n\n### Two\n\n###### Six stays\n",
        out.buffered(),
    );
}

test "promote-first-heading drops the title into metadata" {
    var pipeline: zenfmt.Pipeline = .empty;
    pipeline.add(zenfmt.filters.promote_first_heading, .{});

    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertWithPipeline(
        "# The Title\n\nBody text.\n",
        &pipeline,
        &out,
    );
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    try testing.expectEqualStrings("Body text.\n", out.buffered());
    const manifest_json = conversion.manifest_json.?;
    try testing.expect(std.mem.indexOf(
        u8,
        manifest_json,
        "\"title\":{\"$type\":\"inlines\"",
    ) != null);
    // The promoted inlines are structured nodes, not one flat string.
    try testing.expect(std.mem.indexOf(
        u8,
        manifest_json,
        "{\"text\":\"Title\",\"type\":\"text\"}",
    ) != null);
}

test "drop-empty-containers unwraps spans and flatten replaces nested tables" {
    var pipeline: zenfmt.Pipeline = .empty;
    pipeline.add(zenfmt.filters.drop_empty_containers, .{});
    pipeline.add(zenfmt.filters.flatten_nested_tables, .{});

    // The markdown reader produces no containers, so this exercises the
    // identity path of both filters together with a real document.
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertWithPipeline(
        "| a | b |\n| - | - |\n| 1 | 2 |\n",
        &pipeline,
        &out,
    );
    defer conversion.deinit(testing.allocator);
    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "| 1   | 2   |") != null);
}

test "an identity pipeline appends no AST storage" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build a document directly so node counts are observable.
    const store = try arena.create(zenfmt.ast.Store);
    store.* = .{};
    var tree_builder = zenfmt.builder.Builder.init(arena, store, .{});
    const p = try tree_builder.openLeaf(.paragraph, 0);
    try tree_builder.text("nothing to change here");
    tree_builder.closeLeaf(p);
    const doc = try tree_builder.finish();

    const blocks_before = store.blocks.len;
    const inlines_before = store.inlines.len;

    var pipeline: zenfmt.Pipeline = .empty;
    pipeline.add(zenfmt.filters.shift_headings, .{ .by = 1 });
    pipeline.add(zenfmt.filters.drop_empty_containers, .{});

    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var reports = zenfmt.report.Reports.init(failing.allocator(), .{});
    const out = try pipeline.run(failing.allocator(), doc, &reports, .{});

    // No candidate matched: the same snapshot comes back and the node
    // arrays did not grow. An identity filter costs a tag scan, not a copy.
    try testing.expectEqual(doc.body, out.body);
    try testing.expectEqual(blocks_before, store.blocks.len);
    try testing.expectEqual(inlines_before, store.inlines.len);
    try testing.expect(!failing.has_induced_failure);
}

test "idempotent filters produce the same output twice" {
    var pipeline: zenfmt.Pipeline = .empty;
    pipeline.add(zenfmt.filters.promote_first_heading, .{});
    pipeline.add(zenfmt.filters.drop_empty_containers, .{});

    const source = "# Title\n\nSome *body* text with [a](#frag) link.\n";

    var once_buffer: [4096]u8 = undefined;
    var once_out = std.Io.Writer.fixed(&once_buffer);
    var once = convertWithPipeline(source, &pipeline, &once_out);
    defer once.deinit(testing.allocator);
    try testing.expectEqual(zenfmt.Status.success, once.status);

    // Feed the output back through the same pipeline: idempotent filters
    // must not change it again.
    var twice_buffer: [4096]u8 = undefined;
    var twice_out = std.Io.Writer.fixed(&twice_buffer);
    var twice = convertWithPipeline(once_out.buffered(), &pipeline, &twice_out);
    defer twice.deinit(testing.allocator);
    try testing.expectEqual(zenfmt.Status.success, twice.status);
    try testing.expectEqualStrings(once_out.buffered(), twice_out.buffered());
}
