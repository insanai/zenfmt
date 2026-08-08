const std = @import("std");
const ast = @import("ast.zig");
const builder = @import("builder.zig");

const testing = std.testing;
const Builder = builder.Builder;
const Emitter = builder.Emitter;
const Error = builder.Error;
const Store = ast.Store;

fn testDocument(
    store: *Store,
    build_fn: fn (Emitter) Error!void,
) !ast.Document {
    var tree_builder = Builder.init(testing.allocator, store, .{});
    defer tree_builder.deinit();
    try build_fn(.{ .builder = &tree_builder });
    return tree_builder.finish();
}

test "a paragraph splits and coalesces text" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const doc = try testDocument(&store, struct {
        fn build(emitter: Emitter) Error!void {
            const paragraph = try emitter.beginParagraph();
            defer emitter.endBlock(paragraph);
            try emitter.text("The quick ");
            try emitter.text("bro");
            try emitter.text("wn fox");
        }
    }.build);
    try ast.validate(&doc, .{});

    try testing.expectEqual(@as(usize, 7), store.inlines.len);
    const view = doc.block(@enumFromInt(0));
    try testing.expectEqual(
        ast.BlockTag.paragraph,
        @as(ast.BlockTag, view.content),
    );
    const payloads = store.inlines.items(.payload);
    const brown = doc.text(store.spans.items[payloads[4]]);
    try testing.expectEqualStrings("brown", brown);
    const fox = doc.text(store.spans.items[payloads[6]]);
    try testing.expectEqualStrings("fox", fox);
}

test "nested inline containers patch subtree lengths" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const doc = try testDocument(&store, struct {
        fn build(emitter: Emitter) Error!void {
            const heading = try emitter.beginHeading(2);
            defer emitter.endBlock(heading);
            try emitter.text("The ");
            const emphasis = try emitter.beginInline(.emphasis);
            try emitter.text("quick");
            emitter.endInline(emphasis);
            try emitter.text(" ");
            const link = try emitter.beginLink("http://x", "");
            try emitter.text("brown");
            emitter.endInline(link);
            try emitter.text(" fox");
        }
    }.build);
    try ast.validate(&doc, .{});

    const heading = doc.blockAs(@enumFromInt(0), .heading).?;
    try testing.expectEqual(@as(u8, 2), heading.level);
    try testing.expectEqual(@as(u32, 9), heading.inlines.len);
    var count: u32 = 0;
    var iterator = doc.inlineRoots(heading.inlines);
    while (iterator.next()) |_| count += 1;
    try testing.expectEqual(@as(u32, 7), count);
}

test "quote nests blocks and lists hold items" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const doc = try testDocument(&store, struct {
        fn build(emitter: Emitter) Error!void {
            const quote = try emitter.beginBlock(.quote);
            defer emitter.endBlock(quote);
            const list = try emitter.beginList(.unordered);
            defer emitter.endBlock(list);
            {
                const item = try emitter.beginBlock(.list_item);
                defer emitter.endBlock(item);
                const plain = try emitter.beginPlain();
                defer emitter.endBlock(plain);
                try emitter.text("one");
            }
            {
                const item = try emitter.beginBlock(.list_item);
                defer emitter.endBlock(item);
                const paragraph = try emitter.beginParagraph();
                defer emitter.endBlock(paragraph);
                try emitter.text("two");
            }
        }
    }.build);
    try ast.validate(&doc, .{});

    const lengths = store.blocks.items(.subtree_len);
    try testing.expectEqual(@as(u32, 6), lengths[0]);
    try testing.expectEqual(@as(u32, 5), lengths[1]);
    try testing.expectEqual(@as(u32, 2), lengths[2]);
}

test "attrs staging applies to the next node only" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const doc = try testDocument(&store, struct {
        fn build(emitter: Emitter) Error!void {
            try emitter.attrs(.{ .id = "intro", .classes = &.{"lead"} });
            const paragraph = try emitter.beginParagraph();
            defer emitter.endBlock(paragraph);
            try emitter.text("hi");
        }
    }.build);
    try ast.validate(&doc, .{});

    const view = doc.block(@enumFromInt(0));
    const attrs = doc.attrsOf(view.attrs);
    try testing.expectEqualStrings("intro", doc.text(attrs.id));
    try testing.expectEqual(@as(u32, 1), attrs.classes.len);
}

test "metadata entries sort by key bytes" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);

    const doc = try testDocument(&store, struct {
        fn build(emitter: Emitter) Error!void {
            try emitter.metaString("title", "A Report");
            try emitter.metaString("author", "Zen");
        }
    }.build);
    try ast.validate(&doc, .{});

    const entries = doc.metaEntries(doc.meta);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("author", doc.text(entries[0].key));
    try testing.expectEqualStrings("title", doc.text(entries[1].key));
}
