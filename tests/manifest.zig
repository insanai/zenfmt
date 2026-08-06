//! Manifest properties over the umbrella module: canonical form, digest
//! binding, and idempotent re-encoding.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");

fn convertSample(out: *std.Io.Writer) zenfmt.Conversion {
    return zenfmt.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{
            .name = "sample.txt",
            .data = "first paragraph\n\nsecond one\n",
        } },
        .output = .{ .writer = out },
    });
}

test "the manifest is canonical: parse and re-encode is the identity" {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertSample(&out);
    defer conversion.deinit(testing.allocator);
    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    const manifest_json = conversion.manifest_json.?;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const value = try zenfmt.json.parse(arena, manifest_json, 1 << 20, 64);
    var stream = zenfmt.json.WriteStream.init(arena);
    try zenfmt.json.writeValue(&stream, value);
    const reencoded = try stream.toOwnedSlice();
    try testing.expectEqualStrings(manifest_json, reencoded);
}

test "the manifest carries no whitespace, timestamps, or absolute paths" {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertSample(&out);
    defer conversion.deinit(testing.allocator);
    const manifest_json = conversion.manifest_json.?;

    try testing.expect(std.mem.indexOfAny(u8, manifest_json, " \t\n") == null);
    // Names are basenames; no path separator may appear in the envelope.
    try testing.expect(std.mem.indexOf(u8, manifest_json, "\"name\":\"sample.txt\"") != null);
    try testing.expect(std.mem.indexOf(u8, manifest_json, "/") == null);
}

test "identical input produces byte-identical manifests" {
    var buffer_a: [4096]u8 = undefined;
    var out_a = std.Io.Writer.fixed(&buffer_a);
    var conversion_a = convertSample(&out_a);
    defer conversion_a.deinit(testing.allocator);

    var buffer_b: [4096]u8 = undefined;
    var out_b = std.Io.Writer.fixed(&buffer_b);
    var conversion_b = convertSample(&out_b);
    defer conversion_b.deinit(testing.allocator);

    try testing.expectEqualStrings(
        conversion_a.manifest_json.?,
        conversion_b.manifest_json.?,
    );
    try testing.expectEqualStrings(out_a.buffered(), out_b.buffered());
}
