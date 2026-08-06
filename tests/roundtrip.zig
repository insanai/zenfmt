//! The round-trip fixed point (ZDS 0002, Testing Strategy): Markdown
//! through the AST and back must be idempotent from the second pass onward.
//! The first pass may normalize; the second must change nothing. A cheap,
//! mechanically checkable property that catches a large class of writer
//! bugs — and reader bugs, since both halves are exercised.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");

fn convertMarkdown(gpa: std.mem.Allocator, input: []const u8, out: *std.Io.Writer) zenfmt.Conversion {
    return zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "roundtrip.md", .data = input } },
        .output = .{ .writer = out },
        .from = "markdown",
    });
}

fn expectFixedPoint(source: []const u8) !void {
    var first_buffer: [16 * 1024]u8 = undefined;
    var first_out = std.Io.Writer.fixed(&first_buffer);
    var first = convertMarkdown(testing.allocator, source, &first_out);
    defer first.deinit(testing.allocator);
    try testing.expectEqual(zenfmt.Status.success, first.status);
    const normalized = first_out.buffered();

    var second_buffer: [16 * 1024]u8 = undefined;
    var second_out = std.Io.Writer.fixed(&second_buffer);
    var second = convertMarkdown(testing.allocator, normalized, &second_out);
    defer second.deinit(testing.allocator);
    try testing.expectEqual(zenfmt.Status.success, second.status);

    try testing.expectEqualStrings(normalized, second_out.buffered());
}

test "prose with emphasis, links, and code reaches a fixed point" {
    try expectFixedPoint(
        \\# A Title
        \\
        \\The *quick* **brown** [fox](http://example.com "jumps") and
        \\`code with backticks` plus ~~gone~~ text.
        \\
        \\Another paragraph with _underscore emphasis_ and an
        \\autolink <https://ziglang.org/>.
        \\
    );
}

test "lists, quotes, and fences reach a fixed point" {
    try expectFixedPoint(
        \\- one
        \\- two
        \\  1. nested three
        \\  2. nested four
        \\
        \\> quoted paragraph
        \\>
        \\> second quoted paragraph
        \\
        \\```zig
        \\const answer = 42;
        \\```
        \\
        \\---
        \\
        \\Loose list:
        \\
        \\- alpha
        \\
        \\- beta
        \\
    );
}

test "tables and reference links reach a fixed point" {
    try expectFixedPoint(
        \\| Name | Count |
        \\| :--- | ----: |
        \\| alpha | 3 |
        \\| beta | 14 |
        \\
        \\See [the docs][ref] for more.
        \\
        \\[ref]: https://example.com/docs "Docs"
        \\
    );
}

test "footnotes reach a fixed point" {
    try expectFixedPoint(
        \\Some text with a note[^a] in it.
        \\
        \\[^a]: The note body.
        \\
    );
}

test "headings normalize and then hold steady" {
    try expectFixedPoint(
        \\Setext Title
        \\============
        \\
        \\Subtitle
        \\--------
        \\
        \\### Deep heading ###
        \\
    );
}

test "escaped punctuation survives the trip" {
    try expectFixedPoint(
        \\Literal \*stars\* and a real *emphasis* pair.
        \\
        \\A number 2 + 2 = 4 and 3 \* 3 = 9.
        \\
    );
}
