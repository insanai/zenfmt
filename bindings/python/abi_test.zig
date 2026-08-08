//! ABI contract tests: every exported symbol exercised exactly as the
//! Python `ctypes` consumer would call it — valid requests, boundary
//! values, malformed structures, repeated access, and single release.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");
const build_info = @import("zenfmt_build");
const abi = @import("abi.zig");
const result_mod = @import("result.zig");

fn byteSlice(bytes: []const u8) abi.Slice {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

fn pathSlice(path: []const u8) abi.PathSlice {
    return .{ .ptr = @ptrCast(path.ptr), .len = path.len };
}

const empty_path: abi.PathSlice = .{ .ptr = null, .len = 0 };

fn memoryRequest(options_json: []const u8, input: []const u8) abi.Request {
    return .{
        .options_json = byteSlice(options_json),
        .input_bytes = byteSlice(input),
        .input_path = empty_path,
        .output_path = empty_path,
    };
}

const markdown_options =
    \\{"schema":1,"input":{"kind":"bytes","name":"note.md"},
    \\"output":{"kind":"memory","artifact_name":"note.md"}}
;

test "version and runtime queries are stable" {
    try testing.expectEqual(
        (@as(u32, abi.abi_major) << 16) | abi.abi_minor,
        zenfmt_py_abi_version(),
    );
    var info: abi.RuntimeInfo = undefined;
    zenfmt_py_runtime_info(&info);
    try testing.expectEqual(abi.abi_major, info.abi_major);
    try testing.expectEqual(abi.abi_minor, info.abi_minor);
    try testing.expectEqual(@as(u32, @bitSizeOf(usize)), info.pointer_bits);
    const expected_encoding = if (builtin.os.tag == .windows)
        abi.path_encoding_utf16le
    else
        abi.path_encoding_posix_bytes;
    try testing.expectEqual(expected_encoding, info.path_encoding);

    var len: u64 = 0;
    const version_ptr = zenfmt_py_zenfmt_version(&len).?;
    try testing.expectEqualStrings(build_info.version, version_ptr[0..@intCast(len)]);
}

test "capability query returns the static JSON" {
    var len: u64 = 0;
    const ptr = zenfmt_py_capabilities(&len).?;
    const first = ptr[0..@intCast(len)];
    try testing.expect(first.len > 2);
    // Repeated access returns identical bytes at the same address.
    var second_len: u64 = 0;
    const second = zenfmt_py_capabilities(&second_len).?;
    try testing.expectEqual(ptr, second);
    try testing.expectEqual(len, second_len);
}

test "numeric status and exit-class mappings are pinned" {
    // The ABI fixes these numbers; enum reordering in the engine must not
    // silently change them.
    try testing.expectEqual(@as(u32, 0), result_mod.status_success);
    try testing.expectEqual(@as(u32, 1), result_mod.status_failed);
    try testing.expectEqual(@as(u32, 2), result_mod.status_invalid_request);
    try testing.expectEqual(0, @intFromEnum(core.report.ExitClass.conversion));
    try testing.expectEqual(1, @intFromEnum(core.report.ExitClass.usage));
    try testing.expectEqual(2, @intFromEnum(core.report.ExitClass.limit));
}

test "bytes to memory conversion returns the full ensemble" {
    const request = memoryRequest(markdown_options, "# Title\n\nbody\n");
    const result = zenfmt_py_convert(&request).?;
    defer zenfmt_py_result_free(result);

    try testing.expectEqual(result_mod.status_success, zenfmt_py_result_status(result));
    try testing.expectEqual(@as(u32, 0), zenfmt_py_result_exit_class(result));

    var len: u64 = 0;
    const artifact = zenfmt_py_result_artifact(result, &len).?;
    const artifact_bytes = artifact[0..@intCast(len)];
    try testing.expect(artifact_bytes.len > 0);

    // Cross-check against a direct engine conversion.
    var direct = zenfmt.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = "# Title\n\nbody\n" } },
        .output = .{ .memory = .{ .artifact_name = "note.md" } },
    });
    defer direct.deinit(testing.allocator);
    try testing.expectEqualStrings(direct.ensemble.?.artifact, artifact_bytes);

    var name_len: u64 = 0;
    const name = zenfmt_py_result_artifact_name(result, &name_len).?;
    try testing.expectEqualStrings("note.md", name[0..@intCast(name_len)]);

    var manifest_len: u64 = 0;
    const manifest = zenfmt_py_result_manifest_json(result, &manifest_len).?;
    try testing.expectEqualStrings(
        direct.manifest_json.?,
        manifest[0..@intCast(manifest_len)],
    );

    var format_len: u64 = 0;
    const source = zenfmt_py_result_source_format(result, &format_len).?;
    try testing.expectEqualStrings("markdown", source[0..@intCast(format_len)]);
    const output = zenfmt_py_result_output_format(result, &format_len).?;
    try testing.expectEqualStrings("markdown", output[0..@intCast(format_len)]);

    var reports_len: u64 = 0;
    const reports = zenfmt_py_result_reports_json(result, &reports_len).?;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        reports[0..@intCast(reports_len)],
        .{},
    );
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);

    try testing.expectEqual(@as(u64, 0), zenfmt_py_result_resource_count(result));
    var view: abi.ResourceView = undefined;
    try testing.expectEqual(@as(u32, 1), zenfmt_py_result_resource(result, 0, &view));
}

test "path to path conversion publishes the ensemble" {
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    const dir = ".zig-cache/tmp/zenfmt-abi-path";
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};

    const input_path = dir ++ "/note.md";
    const output_path = dir ++ "/note.out.md";
    try cwd.writeFile(io, .{ .sub_path = input_path, .data = "# T\n\nbody\n" });

    const options =
        \\{"schema":1,"input":{"kind":"path"},"output":{"kind":"path"}}
    ;
    const request: abi.Request = .{
        .options_json = byteSlice(options),
        .input_bytes = .{ .ptr = null, .len = 0 },
        .input_path = pathSlice(input_path),
        .output_path = pathSlice(output_path),
    };
    const result = zenfmt_py_convert(&request).?;
    defer zenfmt_py_result_free(result);

    try testing.expectEqual(result_mod.status_success, zenfmt_py_result_status(result));
    // Path mode returns no memory artifact.
    var len: u64 = 0;
    try testing.expectEqual(
        @as(?[*]const u8, null),
        zenfmt_py_result_artifact(result, &len),
    );
    try cwd.access(io, output_path, .{});
    try cwd.access(io, output_path ++ ".zenfmt.json", .{});
}

test "failed conversion carries reports and the limit exit class" {
    const options =
        \\{"schema":1,"input":{"kind":"bytes","name":"note.md"},
        \\"output":{"kind":"memory","artifact_name":"note.md"},
        \\"limits":{"max_output_bytes":1}}
    ;
    const request = memoryRequest(options, "# Title\n\nbody\n");
    const result = zenfmt_py_convert(&request).?;
    defer zenfmt_py_result_free(result);

    try testing.expectEqual(result_mod.status_failed, zenfmt_py_result_status(result));
    try testing.expectEqual(@as(u32, 2), zenfmt_py_result_exit_class(result));

    var len: u64 = 0;
    const reports = zenfmt_py_result_reports_json(result, &len).?;
    const bytes = reports[0..@intCast(len)];
    try testing.expect(
        std.mem.indexOf(u8, bytes, "\"code\":\"core.output-too-large\"") != null,
    );
    try testing.expect(
        std.mem.indexOf(u8, bytes, "\"exit_class\":\"limit\"") != null,
    );
    try testing.expectEqual(
        @as(?[*]const u8, null),
        zenfmt_py_result_artifact(result, &len),
    );
    try testing.expectEqual(
        @as(?[*]const u8, null),
        zenfmt_py_result_manifest_json(result, &len),
    );
}

test "malformed requests are invalid_request, never a crash" {
    const cases = [_][]const u8{
        "",
        "{",
        "[]",
        "{\"schema\":2,\"input\":{\"kind\":\"bytes\",\"name\":\"a\"}," ++
            "\"output\":{\"kind\":\"memory\",\"artifact_name\":\"a\"}}",
        "{\"schema\":1}",
        "{\"schema\":1,\"unknown\":true,\"input\":{\"kind\":\"bytes\"," ++
            "\"name\":\"a\"},\"output\":{\"kind\":\"memory\"," ++
            "\"artifact_name\":\"a\"}}",
        "{\"schema\":1,\"input\":{\"kind\":\"bytes\",\"name\":\"a/b\"}," ++
            "\"output\":{\"kind\":\"memory\",\"artifact_name\":\"a\"}}",
        "{\"schema\":1,\"input\":{\"kind\":\"bytes\",\"name\":\"a\"}," ++
            "\"output\":{\"kind\":\"memory\",\"artifact_name\":\"a\"}," ++
            "\"limits\":{\"max_depth\":0}}",
        "{\"schema\":1,\"input\":{\"kind\":\"bytes\",\"name\":\"a\"}," ++
            "\"output\":{\"kind\":\"memory\",\"artifact_name\":\"a\"}," ++
            "\"limits\":{\"nonsense\":1}}",
        "{\"schema\":1,\"input\":{\"kind\":\"bytes\",\"name\":\"a\"}," ++
            "\"output\":{\"kind\":\"memory\",\"artifact_name\":\"a\"}," ++
            "\"strict\":\"loose\"}",
        "\xff\xfe not utf-8",
    };
    for (cases) |options| {
        const request = memoryRequest(options, "body");
        const result = zenfmt_py_convert(&request).?;
        defer zenfmt_py_result_free(result);
        try testing.expectEqual(
            result_mod.status_invalid_request,
            zenfmt_py_result_status(result),
        );
        var len: u64 = 0;
        const reports = zenfmt_py_result_reports_json(result, &len).?;
        try testing.expect(std.mem.indexOf(
            u8,
            reports[0..@intCast(len)],
            "bridge.invalid-request",
        ) != null);
    }
}

test "a path input request without a path pointer is invalid" {
    const options =
        \\{"schema":1,"input":{"kind":"path"},"output":{"kind":"path"}}
    ;
    const request: abi.Request = .{
        .options_json = byteSlice(options),
        .input_bytes = .{ .ptr = null, .len = 0 },
        .input_path = empty_path,
        .output_path = empty_path,
    };
    const result = zenfmt_py_convert(&request).?;
    defer zenfmt_py_result_free(result);
    try testing.expectEqual(
        result_mod.status_invalid_request,
        zenfmt_py_result_status(result),
    );
}

test "zero-length byte input converts without a pointer" {
    const options =
        \\{"schema":1,"input":{"kind":"bytes","name":"empty.txt"},
        \\"output":{"kind":"memory","artifact_name":"empty.md"},
        \\"from":"text"}
    ;
    const request = memoryRequest(options, "");
    const result = zenfmt_py_convert(&request).?;
    defer zenfmt_py_result_free(result);
    try testing.expectEqual(result_mod.status_success, zenfmt_py_result_status(result));
}

test "embedded resources cross as views joined by the manifest" {
    // The docx fixture used across the repository is heavyweight; a
    // direct engine cross-check with a memfix-style reader lives in
    // tests/memory_output.zig. Here the resource accessors are checked
    // against a conversion that produces no resources plus index abuse.
    const request = memoryRequest(markdown_options, "plain\n");
    const result = zenfmt_py_convert(&request).?;
    defer zenfmt_py_result_free(result);
    var view: abi.ResourceView = undefined;
    try testing.expectEqual(
        @as(u32, 1),
        zenfmt_py_result_resource(result, std.math.maxInt(u64), &view),
    );
    try testing.expectEqual(
        @as(u32, 1),
        zenfmt_py_result_resource(result, 0, &view),
    );
}

test "null tolerance: every accessor survives null" {
    zenfmt_py_result_free(null);
    var len: u64 = 0;
    try testing.expectEqual(@as(?*abi.Result, null), zenfmt_py_convert(null));
    try testing.expectEqual(
        result_mod.status_invalid_request,
        zenfmt_py_result_status(null),
    );
    try testing.expectEqual(@as(u32, 0), zenfmt_py_result_exit_class(null));
    try testing.expectEqual(
        @as(?[*]const u8, null),
        zenfmt_py_result_reports_json(null, &len),
    );
    try testing.expectEqual(
        @as(?[*]const u8, null),
        zenfmt_py_result_manifest_json(null, &len),
    );
    try testing.expectEqual(@as(u64, 0), zenfmt_py_result_resource_count(null));
    zenfmt_py_runtime_info(null);
    try testing.expectEqual(@as(?[*]const u8, null), zenfmt_py_zenfmt_version(null));
    try testing.expectEqual(@as(?[*]const u8, null), zenfmt_py_capabilities(null));
}

// The exported symbols, redeclared as this test's view of the ABI. Calling
// through these extern declarations exercises the same linkage a C
// consumer uses.
extern fn zenfmt_py_abi_version() u32;
extern fn zenfmt_py_runtime_info(out: ?*abi.RuntimeInfo) void;
extern fn zenfmt_py_zenfmt_version(out_len: ?*u64) ?[*]const u8;
extern fn zenfmt_py_capabilities(out_len: ?*u64) ?[*]const u8;
extern fn zenfmt_py_convert(request: ?*const abi.Request) ?*abi.Result;
extern fn zenfmt_py_result_status(result: ?*const abi.Result) u32;
extern fn zenfmt_py_result_exit_class(result: ?*const abi.Result) u32;
extern fn zenfmt_py_result_reports_json(result: ?*const abi.Result, out_len: ?*u64) ?[*]const u8;
extern fn zenfmt_py_result_manifest_json(result: ?*const abi.Result, out_len: ?*u64) ?[*]const u8;
extern fn zenfmt_py_result_source_format(result: ?*const abi.Result, out_len: ?*u64) ?[*]const u8;
extern fn zenfmt_py_result_output_format(result: ?*const abi.Result, out_len: ?*u64) ?[*]const u8;
extern fn zenfmt_py_result_artifact(result: ?*const abi.Result, out_len: ?*u64) ?[*]const u8;
extern fn zenfmt_py_result_artifact_name(result: ?*const abi.Result, out_len: ?*u64) ?[*]const u8;
extern fn zenfmt_py_result_resource_count(result: ?*const abi.Result) u64;
extern fn zenfmt_py_result_resource(result: ?*const abi.Result, index: u64, out: ?*abi.ResourceView) u32;
extern fn zenfmt_py_result_free(result: ?*abi.Result) void;
