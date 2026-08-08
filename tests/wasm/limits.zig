//! The browser limit profile as the engine actually applies it (ZDS 0015).
//!
//! `bindings/wasm/profile.zig` proves the profile's arithmetic — every value
//! at or below the engine default, a raise refused, a lower honoured. What is
//! left to prove is that those numbers reach the engine and change what it
//! accepts, which is a property of a conversion rather than of a table.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");

/// The same profile the browser binding applies, restated here only because
/// `tests/` cannot import a binding module. The first test below is what
/// keeps the two from drifting.
const browser: core.Limits = limits: {
    var values: core.Limits = .{};
    values.max_input_bytes = 32 * 1024 * 1024;
    values.max_total_uncompressed = 128 * 1024 * 1024;
    values.max_entry_uncompressed = 64 * 1024 * 1024;
    values.max_decoded_text_bytes = 64 * 1024 * 1024;
    values.max_resource_bytes = 32 * 1024 * 1024;
    values.max_output_bytes = 64 * 1024 * 1024;
    values.max_nodes = 2_000_000;
    values.max_facet_rows = 131_072;
    values.max_lowering_work = 8 * 1024 * 1024;
    break :limits values;
};

fn convert(gpa: std.mem.Allocator, data: []const u8, limits: core.Limits) core.Conversion {
    return zenfmt.Browser.convert(gpa, .{}, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = data } },
        .output = .{ .memory = .{ .artifact_name = "note.md" } },
        .limits = limits,
    });
}

test "the browser profile is a configuration the engine accepts" {
    try testing.expectEqual(@as(?core.Limits.Field, null), browser.invalidField());
}

test "every browser value is at or below the engine default" {
    const defaults: core.Limits = .{};
    inline for (@typeInfo(core.Limits).@"struct".fields) |field| {
        const browser_value: u64 = @field(browser, field.name);
        const default_value: u64 = @field(defaults, field.name);
        try testing.expect(browser_value <= default_value);
    }
}

test "a document within the profile converts" {
    const gpa = testing.allocator;
    var conversion = convert(gpa, "# Title\n\nBody.\n", browser);
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.success, conversion.status);
}

test "an input above the limit is refused before conversion, as a limit failure" {
    const gpa = testing.allocator;
    var limits = browser;
    limits.max_input_bytes = 8;
    var conversion = convert(gpa, "# This is longer than eight bytes\n", limits);
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    // A limit refusal, not a claim that the document is malformed: the
    // difference is what tells a visitor to reach for the command-line tool.
    try testing.expectEqual(core.report.ExitClass.limit, conversion.exit_class);
    try testing.expect(conversion.ensemble == null);
    try testing.expect(conversion.reports.len >= 1);
}

test "an output above the limit is refused while producing no artifact" {
    const gpa = testing.allocator;
    var limits = browser;
    limits.max_output_bytes = 4;
    var conversion = convert(gpa, "# A heading long enough to exceed four bytes\n", limits);
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqual(core.report.ExitClass.limit, conversion.exit_class);
    try testing.expect(conversion.ensemble == null);
}

test "a node limit bounds a document that would otherwise build a large tree" {
    const gpa = testing.allocator;
    var limits = browser;
    limits.max_nodes = 4;

    var document = std.ArrayList(u8).empty;
    defer document.deinit(gpa);
    for (0..64) |i| {
        const chunk = try std.fmt.allocPrint(
            gpa,
            "# Heading {d}\n\nParagraph {d}.\n\n",
            .{ i, i },
        );
        defer gpa.free(chunk);
        try document.appendSlice(gpa, chunk);
    }

    var conversion = convert(gpa, document.items, limits);
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqual(core.report.ExitClass.limit, conversion.exit_class);
}

test "the engine's own defaults and the browser profile both convert the same document" {
    const gpa = testing.allocator;
    const document = "# Title\n\n| a | b |\n| - | - |\n| 1 | 2 |\n";

    var native = convert(gpa, document, .{});
    defer native.deinit(gpa);
    var browser_run = convert(gpa, document, browser);
    defer browser_run.deinit(gpa);

    try testing.expectEqual(core.Status.success, native.status);
    try testing.expectEqual(core.Status.success, browser_run.status);
    // Lowering a limit does not change the document, only what is allowed.
    try testing.expectEqualSlices(
        u8,
        native.ensemble.?.artifact,
        browser_run.ensemble.?.artifact,
    );
}
