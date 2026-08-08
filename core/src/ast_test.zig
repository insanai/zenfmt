const std = @import("std");
const ast = @import("ast.zig");

test "storage columns match the budget in the record" {
    var block_bytes: usize = 0;
    inline for (@typeInfo(ast.Block).@"struct".fields) |field| {
        block_bytes += @sizeOf(field.type);
    }
    try std.testing.expectEqual(@as(usize, 21), block_bytes);

    var inline_bytes: usize = 0;
    inline for (@typeInfo(ast.Inline).@"struct".fields) |field| {
        inline_bytes += @sizeOf(field.type);
    }
    try std.testing.expectEqual(@as(usize, 13), inline_bytes);
}

test "child iterator hops over grandchildren" {
    const gpa = std.testing.allocator;
    var store: ast.Store = .{};
    defer store.deinit(gpa);

    try appendBlock(&store, gpa, .quote, 4);
    try appendBlock(&store, gpa, .paragraph, 1);
    try appendBlock(&store, gpa, .quote, 2);
    try appendBlock(&store, gpa, .paragraph, 1);

    const doc: ast.Document = .{
        .store = &store,
        .body = ast.BlockRange.init(0, 4),
        .meta = @enumFromInt(0),
        .plugin_data = .empty,
    };
    var children = doc.blockChildren(@enumFromInt(0));
    try std.testing.expectEqual(@as(u32, 1), children.next().?.raw());
    try std.testing.expectEqual(@as(u32, 2), children.next().?.raw());
    try std.testing.expectEqual(@as(?ast.BlockIndex, null), children.next());
}

test "validate rejects a subtree escaping its parent" {
    const gpa = std.testing.allocator;
    var store: ast.Store = .{};
    defer store.deinit(gpa);
    try store.meta_maps.append(gpa, .{ .start = 0, .len = 0 });

    try appendBlock(&store, gpa, .quote, 2);
    try appendBlock(&store, gpa, .paragraph, 2);
    const doc = document(&store, ast.BlockRange.init(0, 2));
    try std.testing.expectError(error.InvalidDocument, ast.validate(&doc, .{}));
}

test "validate rejects a structural tag at the root" {
    const gpa = std.testing.allocator;
    var store: ast.Store = .{};
    defer store.deinit(gpa);
    try store.meta_maps.append(gpa, .{ .start = 0, .len = 0 });

    try appendBlock(&store, gpa, .list_item, 1);
    const doc = document(&store, ast.BlockRange.init(0, 1));
    try std.testing.expectError(error.InvalidDocument, ast.validate(&doc, .{}));
}

test "validate accepts an empty document" {
    const gpa = std.testing.allocator;
    var store: ast.Store = .{};
    defer store.deinit(gpa);
    try store.meta_maps.append(gpa, .{ .start = 0, .len = 0 });

    const doc = document(&store, ast.BlockRange.empty);
    try ast.validate(&doc, .{});
}

fn appendBlock(
    store: *ast.Store,
    gpa: std.mem.Allocator,
    tag: ast.BlockTag,
    subtree_len: u32,
) !void {
    try store.blocks.append(gpa, .{
        .tag = tag,
        .payload = 0,
        .attrs = .none,
        .inlines = .empty,
        .subtree_len = subtree_len,
    });
}

fn document(store: *ast.Store, body: ast.BlockRange) ast.Document {
    return .{
        .store = store,
        .body = body,
        .meta = @enumFromInt(0),
        .plugin_data = .empty,
    };
}
