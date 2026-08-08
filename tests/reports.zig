//! Rendering a report, not just producing one.
//!
//! The engine's tests check that a failure yields the right code and exit
//! class. That is not the same as checking the report can be *printed*: a
//! direction whose text points at freed memory produces a perfectly correct
//! report object and crashes the moment anyone renders it.
//!
//! That is exactly what happened. `pathFailure` built its directions with
//! `&.{pathDirection(err)}`, an anonymous array holding a value chosen at run
//! time, so the slice pointed into the stack frame that had already returned.
//! Every unit test passed and `zenfmt missing-file.docx` — the commonest
//! mistake a user can make — segfaulted.
//!
//! So these tests render. Producing a report and rendering it are separate
//! claims, and only the second one is what a user experiences.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");

/// Renders every report a conversion produced, exactly as the CLI does.
fn renderAll(gpa: std.mem.Allocator, conversion: *const core.Conversion) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(gpa);
    var scratch: [8 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&scratch);
    try conversion.renderReports(&writer, .{ .quiet = false, .color = false });
    try buffer.appendSlice(gpa, writer.buffered());
    return buffer.toOwnedSlice(gpa);
}

test "a missing input file renders its report instead of crashing" {
    const gpa = testing.allocator;
    var conversion = zenfmt.Default.convert(gpa, testing.io, .{
        .input = .{ .path = "does-not-exist-anywhere.docx" },
        .output = .{ .memory = .{ .artifact_name = "out.md" } },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    const rendered = try renderAll(gpa, &conversion);
    defer gpa.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "A FILE OPERATION FAILED") != null);
    // The direction is the part that was reading freed memory. Asserting its
    // text is what makes this a regression test rather than a smoke test.
    try testing.expect(std.mem.indexOf(u8, rendered, "What you can do") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "parent") != null);
}

test "a missing parent directory for the output renders its report" {
    const gpa = testing.allocator;
    var conversion = zenfmt.Default.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = "# Title\n" } },
        .output = .{ .path = ".zig-cache/tmp/zenfmt-no-such-dir/deeper/out.md" },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    const rendered = try renderAll(gpa, &conversion);
    defer gpa.free(rendered);
    try testing.expect(rendered.len > 0);
}

test "an undetectable document renders every direction it offers" {
    const gpa = testing.allocator;
    var conversion = zenfmt.Default.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "mystery.bin", .data = "\x00\x01\x02\xff" } },
        .output = .{ .memory = .{ .artifact_name = "out.md" } },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    const rendered = try renderAll(gpa, &conversion);
    defer gpa.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "What you can do") != null);
}

test "every direction of every report survives being rendered twice" {
    // Rendering is not supposed to consume anything. If a direction's text
    // were borrowed from a temporary, a second pass is where a stale read is
    // most likely to show up as different output rather than a crash.
    const gpa = testing.allocator;
    var conversion = zenfmt.Default.convert(gpa, testing.io, .{
        .input = .{ .path = "also-missing.xlsx" },
        .output = .{ .memory = .{ .artifact_name = "out.md" } },
    });
    defer conversion.deinit(gpa);

    const first = try renderAll(gpa, &conversion);
    defer gpa.free(first);
    const second = try renderAll(gpa, &conversion);
    defer gpa.free(second);
    try testing.expectEqualStrings(first, second);
}

test "a page with embedded content reports it, and the report renders" {
    // Both memory bugs this file exists for were reports that were correct
    // as objects and unprintable as text. Every reader that gained a report
    // should therefore be exercised through rendering, not just through its
    // code.
    const gpa = testing.allocator;
    const page =
        "<html><body><p>Before</p><svg><circle r=\"1\"/></svg>" ++
        "<iframe src=\"x\"></iframe><p>After</p></body></html>";
    var conversion = zenfmt.Default.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "page.html", .data = page } },
        .output = .{ .memory = .{ .artifact_name = "page.md" } },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.success, conversion.status);
    const rendered = try renderAll(gpa, &conversion);
    defer gpa.free(rendered);
    try testing.expect(
        std.mem.indexOf(u8, rendered, "EMBEDDED CONTENT WAS NOT CONVERTED") != null,
    );
    try testing.expect(std.mem.indexOf(u8, rendered, "What you can do") != null);

    // The surrounding document still converted, which is the point of a
    // warning rather than a refusal.
    const artifact = conversion.ensemble.?.artifact;
    try testing.expect(std.mem.indexOf(u8, artifact, "Before") != null);
    try testing.expect(std.mem.indexOf(u8, artifact, "After") != null);
}

test "script and style are dropped silently, because they are not content" {
    // The rule is that a dropped *construct* is reported. Program text and
    // presentation are not document constructs, and reporting them would
    // make the common case noisy enough that the real warnings get ignored.
    const gpa = testing.allocator;
    const page =
        "<html><head><style>p{color:red}</style></head>" ++
        "<body><p>Text</p><script>var x = 1;</script></body></html>";
    var conversion = zenfmt.Default.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "page.html", .data = page } },
        .output = .{ .memory = .{ .artifact_name = "page.md" } },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.success, conversion.status);
    for (conversion.reports) |value| {
        try testing.expect(
            !std.mem.eql(u8, value.code, "html.skipped-embedded-content"),
        );
    }
}
