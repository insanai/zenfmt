//! Browser-bundle parity (ZDS 0015, Determinism and artifact parity).
//!
//! For the same bytes, name, options, and limits, the browser bundle must
//! produce the same artifact as the native one. The two differ only in host
//! authority, so any divergence here is a bug in that separation rather than
//! a browser-specific behaviour to be documented.
//!
//! These run natively and cost milliseconds. The browser bundle is not a
//! WebAssembly artifact — it is the same engine with the filesystem compiled
//! out — so its document semantics can be checked without a runtime, and only
//! the ABI and the adapter need one.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");

/// Every committed integration fixture, so a reader added to the bundle
/// without a fixture is a visible gap rather than a silent one.
const fixtures = [_][]const u8{
    "python/tests/integration/fixtures/note.md",
    "python/tests/integration/fixtures/note.txt",
    "python/tests/integration/fixtures/table.csv",
    "python/tests/integration/fixtures/page.html",
    "python/tests/integration/fixtures/doc.adoc",
    "python/tests/integration/fixtures/doc.rst",
    "python/tests/integration/fixtures/doc.rtf",
    "python/tests/integration/fixtures/min.docx",
    "python/tests/integration/fixtures/min.xlsx",
    "python/tests/integration/fixtures/min.pptx",
    "python/tests/integration/fixtures/min.odt",
    "python/tests/integration/fixtures/min.ods",
    "python/tests/integration/fixtures/min.odp",
    "python/tests/integration/fixtures/min.epub",
    "python/tests/integration/fixtures/min.pdf",
    "python/tests/integration/fixtures/tiny.doc",
    "python/tests/integration/fixtures/tiny.xls",
    "python/tests/integration/fixtures/tiny.ppt",
};

fn readFixture(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        path,
        gpa,
        .limited(16 * 1024 * 1024),
    );
}

fn optionsFor(name: []const u8, data: []const u8) core.ConvertOptions {
    return .{
        .input = .{ .bytes = .{ .name = name, .data = data } },
        .output = .{ .memory = .{ .artifact_name = name } },
    };
}

fn expectSameConversion(
    native: *const core.Conversion,
    browser: *const core.Conversion,
    name: []const u8,
) !void {
    errdefer std.debug.print("divergence on {s}\n", .{name});

    try testing.expectEqual(native.status, browser.status);
    try testing.expectEqual(native.exit_class, browser.exit_class);

    if (native.source_format) |expected| {
        try testing.expectEqualStrings(expected, browser.source_format.?);
    } else {
        try testing.expect(browser.source_format == null);
    }
    if (native.output_format) |expected| {
        try testing.expectEqualStrings(expected, browser.output_format.?);
    } else {
        try testing.expect(browser.output_format == null);
    }

    if (native.ensemble) |expected| {
        const actual = browser.ensemble.?;
        try testing.expectEqualStrings(expected.artifact_name, actual.artifact_name);
        try testing.expectEqualSlices(u8, expected.artifact, actual.artifact);
        try testing.expectEqual(expected.resources.len, actual.resources.len);
        for (expected.resources, actual.resources) |want, got| {
            try testing.expectEqualStrings(want.rel_path, got.rel_path);
            try testing.expectEqualSlices(u8, want.bytes, got.bytes);
            try testing.expectEqualSlices(u8, &want.digest_hex, &got.digest_hex);
        }
    } else {
        try testing.expect(browser.ensemble == null);
    }

    if (native.manifest_json) |expected| {
        try testing.expectEqualStrings(expected, browser.manifest_json.?);
    } else {
        try testing.expect(browser.manifest_json == null);
    }

    try testing.expectEqual(native.reports.len, browser.reports.len);
    for (native.reports, browser.reports) |want, got| {
        try testing.expectEqual(want.severity, got.severity);
        try testing.expectEqualStrings(want.code, got.code);
        try testing.expectEqualStrings(want.title, got.title);
        try testing.expectEqualStrings(want.problem, got.problem);
        try testing.expectEqualStrings(want.consequence, got.consequence);
        try testing.expectEqual(want.exit_class, got.exit_class);
        try testing.expectEqual(want.count, got.count);
        try testing.expectEqual(want.directions.len, got.directions.len);
        for (want.directions, got.directions) |want_direction, got_direction| {
            try testing.expectEqualStrings(want_direction.title, got_direction.title);
            try testing.expectEqualStrings(
                want_direction.explanation,
                got_direction.explanation,
            );
        }
    }
}

test "the browser bundle converts every fixture exactly as the native one does" {
    const gpa = testing.allocator;
    for (fixtures) |path| {
        const data = readFixture(gpa, path) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer gpa.free(data);
        const name = std.fs.path.basename(path);

        var native = zenfmt.Default.convert(gpa, testing.io, optionsFor(name, data));
        defer native.deinit(gpa);
        var browser = zenfmt.Browser.convert(gpa, .{}, optionsFor(name, data));
        defer browser.deinit(gpa);

        try testing.expectEqual(core.Status.success, native.status);
        try expectSameConversion(&native, &browser, name);
    }
}

test "a document the engine refuses fails identically in both bundles" {
    const gpa = testing.allocator;
    // Not any format the bundle can detect, and not resolvable by name.
    const data = "\x00\x01\x02 not a document \xff\xfe";
    const name = "mystery.bin";

    var native = zenfmt.Default.convert(gpa, testing.io, optionsFor(name, data));
    defer native.deinit(gpa);
    var browser = zenfmt.Browser.convert(gpa, .{}, optionsFor(name, data));
    defer browser.deinit(gpa);

    try testing.expectEqual(core.Status.failed, native.status);
    try expectSameConversion(&native, &browser, name);
}

test "an explicit output format agrees across bundles" {
    const gpa = testing.allocator;
    const data = "# Heading\n\nBody text.\n";
    var options = optionsFor("note.md", data);
    options.from = "markdown";
    options.to = "markdown";
    options.preserve_facets = true;

    var native = zenfmt.Default.convert(gpa, testing.io, options);
    defer native.deinit(gpa);
    var browser = zenfmt.Browser.convert(gpa, .{}, options);
    defer browser.deinit(gpa);

    try testing.expectEqual(core.Status.success, native.status);
    try expectSameConversion(&native, &browser, "note.md");
}
