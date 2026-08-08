//! `max_output_bytes` enforcement (ZDS 0014): the shared artifact sink
//! refuses the byte that would cross the limit in every output mode, the
//! conversion fails with `core.output-too-large` and exit class `limit`,
//! and nothing is published or returned.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");

const test_dir = ".zig-cache/tmp/zenfmt-output-limit-e2e";
const input_markdown = "# Title\n\nbody paragraph with several words\n";

/// The exact artifact size of the fixture input through the default bundle,
/// measured once so boundary tests stay exact without hardcoding writer
/// output.
fn artifactSize(gpa: std.mem.Allocator) !u64 {
    var conversion = zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = input_markdown } },
        .output = .{ .memory = .{ .artifact_name = "note.md" } },
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.success, conversion.status);
    return conversion.ensemble.?.artifact.len;
}

fn limitsWithOutputCap(cap: u64) zenfmt.Limits {
    var limits: zenfmt.Limits = .{};
    limits.max_output_bytes = cap;
    return limits;
}

test "memory output at the exact limit succeeds and one byte less fails" {
    const gpa = testing.allocator;
    const size = try artifactSize(gpa);
    try testing.expect(size > 1);

    var exact = zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = input_markdown } },
        .output = .{ .memory = .{ .artifact_name = "note.md" } },
        .limits = limitsWithOutputCap(size),
    });
    defer exact.deinit(gpa);
    try testing.expectEqual(core.Status.success, exact.status);

    var refused = zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = input_markdown } },
        .output = .{ .memory = .{ .artifact_name = "note.md" } },
        .limits = limitsWithOutputCap(size - 1),
    });
    defer refused.deinit(gpa);
    try testing.expectEqual(core.Status.failed, refused.status);
    try testing.expectEqualStrings(
        "core.output-too-large",
        refused.reports[0].code,
    );
    try testing.expectEqual(core.report.ExitClass.limit, refused.exit_class);
    try testing.expectEqual(@as(?zenfmt.MemoryEnsemble, null), refused.ensemble);
    try testing.expectEqual(@as(?[]const u8, null), refused.manifest_json);
}

test "path output over the limit publishes nothing" {
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, test_dir) catch {};
    try cwd.createDirPath(io, test_dir);
    defer cwd.deleteTree(io, test_dir) catch {};

    const output_path = test_dir ++ "/note.md";
    var conversion = zenfmt.convert(gpa, io, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = input_markdown } },
        .output = .{ .path = output_path },
        .limits = limitsWithOutputCap(1),
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqualStrings(
        "core.output-too-large",
        conversion.reports[0].code,
    );
    try testing.expectEqual(core.report.ExitClass.limit, conversion.exit_class);
    try testing.expectError(error.FileNotFound, cwd.access(io, output_path, .{}));
    try testing.expectError(
        error.FileNotFound,
        cwd.access(io, output_path ++ ".zenfmt.json", .{}),
    );
}

test "stream output over the limit fails without completing" {
    const gpa = testing.allocator;

    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = input_markdown } },
        .output = .{ .writer = &out },
        .limits = limitsWithOutputCap(1),
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqualStrings(
        "core.output-too-large",
        conversion.reports[0].code,
    );
    try testing.expect(conversion.stream != .complete);
    try testing.expect(conversion.stream != .none);
}

test "a zero output limit is an invalid configuration" {
    const gpa = testing.allocator;

    var conversion = zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = input_markdown } },
        .output = .{ .memory = .{ .artifact_name = "note.md" } },
        .limits = limitsWithOutputCap(0),
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqualStrings(
        "core.invalid-limit-configuration",
        conversion.reports[0].code,
    );
}

test "the CLI limit override accepts max_output_bytes" {
    var limits: zenfmt.Limits = .{};
    try limits.override("max_output_bytes=1024");
    try testing.expectEqual(@as(u64, 1024), limits.max_output_bytes);
}
