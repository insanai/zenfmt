//! Conversion tests for the HTML reader's IR v2 additions (ZDS 0013):
//! the `<details>` extension node with its mandatory fallback, and
//! colspan/rowspan carried into table-cell properties. Split out of
//! `reader.zig` under the file-size rule.

const std = @import("std");
const core = @import("zenfmt_core");
const read = @import("reader.zig").read;

const testing = std.testing;

const Converted = struct {
    doc: core.ast.Document,
    reports: []const core.Report,
};

fn convertHtml(arena: std.mem.Allocator, bytes: []const u8) !Converted {
    const store = try arena.create(core.ast.Store);
    store.* = .{};
    var b = core.builder.Builder.init(arena, store, .{});
    const reports = try arena.create(core.Reports);
    reports.* = core.Reports.init(arena, .{});
    var ctx: core.ReadContext = .{
        .gpa = arena,
        .out = .{ .builder = &b },
        .input = .{ .bytes = bytes },
        .input_name = "test.html",
        .reports = reports,
        .manifest_in = null,
        .limits = .{},
    };
    try read(&ctx);
    const doc = try b.finish();
    try core.ast.validate(&doc, .{});
    return .{ .doc = doc, .reports = try reports.finalize() };
}

test "details becomes an extension node with the summary as fallback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertHtml(arena,
        \\<details><summary>Click me</summary><p>Hidden body.</p></details>
    );
    const store = converted.doc.store;

    try testing.expectEqual(@as(usize, 1), store.extensions.items.len);
    const extension = store.extensions.items[0];
    try testing.expectEqualStrings("ai.insan.zenfmt.html", store.textSlice(extension.owner));
    try testing.expectEqualStrings("details", store.textSlice(extension.name));
    try testing.expectEqual(@as(u32, 1), extension.version);

    // The extension root carries the fallback: summary paragraph plus body.
    const tags = store.blocks.items(.tag);
    try testing.expectEqual(core.BlockTag.extension, tags[0]);
    try testing.expectEqual(core.BlockTag.paragraph, tags[1]);
    try testing.expectEqual(core.BlockTag.paragraph, tags[2]);
    try testing.expectEqual(@as(u32, 3), store.blocks.items(.subtree_len)[0]);
}

test "a nested details degrades to a container instead of same-owner nesting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertHtml(arena,
        \\<details><summary>Outer</summary>
        \\<details><summary>Inner</summary><p>Deep.</p></details>
        \\</details>
    );
    const store = converted.doc.store;

    // One extension only; the inner one is an ordinary container, so the
    // validator's same-owner rule holds by construction.
    try testing.expectEqual(@as(usize, 1), store.extensions.items.len);
    var containers: u32 = 0;
    for (store.blocks.items(.tag)) |tag| {
        if (tag == .container) containers += 1;
    }
    try testing.expectEqual(@as(u32, 1), containers);
}

test "an empty details still carries a fallback the validator accepts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertHtml(arena, "<details></details>");
    const store = converted.doc.store;
    try testing.expectEqual(core.BlockTag.extension, store.blocks.items(.tag)[0]);
    // validate() ran inside convertHtml: subtree_len >= 2 held.
    try testing.expect(store.blocks.items(.subtree_len)[0] >= 2);
}

test "colspan and rowspan land in the cell properties" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertHtml(arena,
        \\<table><tbody>
        \\<tr><td>a</td><td>b</td></tr>
        \\<tr><td colspan="2" rowspan="3">wide</td></tr>
        \\</tbody></table>
    );
    const store = converted.doc.store;

    var spanned: ?core.payload.TableCellProps = null;
    for (store.blocks.items(.tag), store.blocks.items(.payload)) |tag, payload_index| {
        if (tag != .table_cell) continue;
        const props = store.table_cells.items[payload_index];
        if (props.col_span > 1) spanned = props;
    }
    try testing.expectEqual(@as(u32, 2), spanned.?.col_span);
    try testing.expectEqual(@as(u32, 3), spanned.?.row_span);
}

test "a malformed span attribute degrades to one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const converted = try convertHtml(arena,
        \\<table><tbody><tr><td colspan="banana">x</td></tr></tbody></table>
    );
    const store = converted.doc.store;
    for (store.blocks.items(.tag), store.blocks.items(.payload)) |tag, payload_index| {
        if (tag != .table_cell) continue;
        const props = store.table_cells.items[payload_index];
        try testing.expectEqual(@as(u32, 1), props.col_span);
        try testing.expectEqual(@as(u32, 1), props.row_span);
    }
}
