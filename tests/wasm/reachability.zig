//! What the browser bundle cannot do (ZDS 0015, Engine separation required
//! for WASM).
//!
//! The security claim is that a pure bundle has no filesystem authority
//! compiled into it. Most of that claim is enforced by the compiler — the
//! path branches are not analyzed for such a bundle, so a slip is a build
//! failure, not a test failure — and the rest is proven on the built module
//! by the import audit.
//!
//! What is left for a test is the visible behaviour: asking a pure bundle for
//! a path must produce a structured refusal that says what to do instead,
//! rather than a crash, a silent empty result, or a guess.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");

test "the two bundles differ in host authority and nothing else" {
    try testing.expectEqual(core.host.Mode.host, zenfmt.Default.host_mode);
    try testing.expectEqual(core.host.Mode.pure, zenfmt.Browser.host_mode);
    try testing.expectEqual(zenfmt.Default.readers.len, zenfmt.Browser.readers.len);
    try testing.expectEqual(zenfmt.Default.writers.len, zenfmt.Browser.writers.len);
    try testing.expectEqualStrings(
        zenfmt.Default.default_output_format,
        zenfmt.Browser.default_output_format,
    );
    for (zenfmt.Default.readers, zenfmt.Browser.readers) |native, browser| {
        try testing.expectEqualStrings(native.format, browser.format);
        try testing.expectEqualStrings(native.id, browser.id);
        try testing.expectEqual(native.data_version, browser.data_version);
    }
}

test "a pure bundle refuses a path input with directions, not a crash" {
    const gpa = testing.allocator;
    var conversion = zenfmt.Browser.convert(gpa, .{}, .{
        .input = .{ .path = "README.md" },
        .output = .{ .memory = .{ .artifact_name = "README.md" } },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    // A caller mistake, not a fault in a document: an embedding that asks a
    // browser build to open a file has misunderstood the API.
    try testing.expectEqual(core.report.ExitClass.usage, conversion.exit_class);
    try testing.expect(conversion.ensemble == null);
    try testing.expectEqual(@as(usize, 1), conversion.reports.len);

    const refusal = conversion.reports[0];
    try testing.expectEqualStrings("core.host-io-unavailable", refusal.code);
    try testing.expect(refusal.directions.len >= 1);
}

test "a pure bundle refuses an output path before any reader runs" {
    const gpa = testing.allocator;
    const path = ".zig-cache/tmp/zenfmt-pure-should-never-exist.md";
    var conversion = zenfmt.Browser.convert(gpa, .{}, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = "# Title\n" } },
        .output = .{ .path = path },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqual(core.report.ExitClass.usage, conversion.exit_class);
    try testing.expect(conversion.ensemble == null);
    try testing.expectEqual(@as(usize, 1), conversion.reports.len);
    try testing.expectEqualStrings(
        "core.host-io-unavailable",
        conversion.reports[0].code,
    );

    // And nothing was written on the way to refusing.
    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(testing.io, path, .{}),
    );
}
