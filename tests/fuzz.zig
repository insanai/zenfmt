//! Reader fuzz targets (ZDS 0002, Testing Strategy): arbitrary bytes into
//! each reader, with `ast.validate` as the oracle via the engine. The
//! properties: never crash, never exceed the limits, always leave the
//! builder balanced, and never commit output on failure. Run continuously
//! with `zig build test --fuzz`; each ordinary test run exercises the seed
//! corpus.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");

fn convertFuzzInput(format: []const u8, bytes: []const u8) !void {
    var sink_buffer: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&sink_buffer);

    var conversion = zenfmt.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "fuzz-input", .data = bytes } },
        .output = .{ .writer = &discarding.writer },
        .from = format,
        // Small limits keep pathological nesting fast while still
        // exercising the refusal paths.
        .limits = .{ .max_depth = 64, .max_input_bytes = 1 << 20 },
    });
    defer conversion.deinit(testing.allocator);

    // Success must produce a manifest; failure must explain itself. The
    // engine validates the tree in both cases before writing anything.
    switch (conversion.status) {
        .success => try testing.expect(conversion.manifest_json != null),
        .failed => try testing.expect(conversion.reports.len > 0),
    }
}

const markdown_corpus: []const []const u8 = &.{
    "# Title\n\nThe *quick* [fox](http://x) jumps.\n",
    "- one\n- two\n  1. three\n\n> quote\n\n```zig\ncode\n```\n",
    "| a | b |\n| - | - |\n| 1 | 2 |\n\nnote[^n]\n\n[^n]: body\n",
    "**bold _mixed_ emphasis** with `code` and ~~strike~~\n",
    "[ref][r]\n\n[r]: http://example.com \"t\"\n",
    "***\n\nSetext\n======\n\n    indented code\n",
};

fn fuzzMarkdown(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [2048]u8 = undefined;
    const len = smith.slice(&buffer);
    try convertFuzzInput("markdown", buffer[0..len]);
}

test "fuzz the markdown reader" {
    try std.testing.fuzz({}, fuzzMarkdown, .{ .corpus = markdown_corpus });
}

fn fuzzText(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [2048]u8 = undefined;
    const len = smith.slice(&buffer);
    try convertFuzzInput("text", buffer[0..len]);
}

test "fuzz the text reader" {
    try std.testing.fuzz({}, fuzzText, .{ .corpus = &.{
        "plain paragraph\n\nsecond one\n",
        "\xff\xfe invalid utf8",
    } });
}

fn fuzzCsv(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [2048]u8 = undefined;
    const len = smith.slice(&buffer);
    try convertFuzzInput("csv", buffer[0..len]);
}

test "fuzz the csv reader" {
    try std.testing.fuzz({}, fuzzCsv, .{ .corpus = &.{
        "a,b\n1,\"two, quoted\"\n",
        "a,\"unterminated\n",
        "x\ty\n1\t2\n",
    } });
}
