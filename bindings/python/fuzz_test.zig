//! Bridge boundary fuzzing (ZDS 0014): arbitrary bytes as the options
//! JSON and as the input document, independently of Python. Properties:
//! never crash, status stays in the ABI's fixed set, reports JSON always
//! parses, success implies a manifest, and every handle is released
//! without leaking (the test allocator checks on exit).

const std = @import("std");
const testing = std.testing;
const abi = @import("abi.zig");
const result_mod = @import("result.zig");

fn byteSlice(bytes: []const u8) abi.Slice {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

fn exerciseRequest(options_json: []const u8, input: []const u8) !void {
    const request: abi.Request = .{
        .options_json = byteSlice(options_json),
        .input_bytes = byteSlice(input),
        .input_path = .{ .ptr = null, .len = 0 },
        .output_path = .{ .ptr = null, .len = 0 },
    };
    const result = result_mod.convert(testing.allocator, &request) orelse
        return;
    defer result.destroy();

    try testing.expect(result.status <= result_mod.status_invalid_request);
    try testing.expect(result.exit_class <= 2);

    // Reports JSON must always parse, whatever the request contained.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        result.reports_json,
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);

    if (result.status == result_mod.status_success) {
        const conversion = &result.conversion.?;
        try testing.expect(conversion.manifest_json != null);
    }
    if (result.status == result_mod.status_failed) {
        try testing.expect(parsed.value.array.items.len > 0);
    }
}

fn fuzzOptions(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [1024]u8 = undefined;
    const len = smith.slice(&buffer);
    try exerciseRequest(buffer[0..len], "# Title\n\nbody\n");
}

test "fuzz the options JSON boundary" {
    try std.testing.fuzz({}, fuzzOptions, .{ .corpus = &.{
        "{\"schema\":1,\"input\":{\"kind\":\"bytes\",\"name\":\"a.md\"}," ++
            "\"output\":{\"kind\":\"memory\",\"artifact_name\":\"a.md\"}}",
        "{\"schema\":1,\"input\":{\"kind\":\"bytes\",\"name\":\"a.md\"}," ++
            "\"output\":{\"kind\":\"memory\",\"artifact_name\":\"a.md\"}," ++
            "\"strict\":\"content\",\"limits\":{\"max_depth\":32}}",
        "{\"schema\":1}",
        "{]",
        "",
    } });
}

fn fuzzInputBytes(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [2048]u8 = undefined;
    const len = smith.slice(&buffer);
    try exerciseRequest(
        "{\"schema\":1,\"input\":{\"kind\":\"bytes\",\"name\":\"fuzz.md\"}," ++
            "\"output\":{\"kind\":\"memory\",\"artifact_name\":\"fuzz.md\"}," ++
            "\"limits\":{\"max_depth\":64,\"max_input_bytes\":1048576}}",
        buffer[0..len],
    );
}

test "fuzz the input byte boundary through the bridge" {
    try std.testing.fuzz({}, fuzzInputBytes, .{ .corpus = &.{
        "# Title\n\nThe *quick* [fox](http://x) jumps.\n",
        "PK\x03\x04truncated",
        "\xff\xfe invalid utf8",
        "",
    } });
}
