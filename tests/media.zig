//! End-to-end media extraction: a reader that registers image bytes gets
//! them committed into `<stem>_media/` beside a path artifact, with the
//! image URL rewritten and the manifest listing each file's digest. Stream
//! output extracts nothing and keeps the reader's original URL.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");

const test_dir = ".zig-cache/tmp/zenfmt-media-e2e";
const png_bytes = "\x89PNG\r\n\x1a\nfakepixels";

fn readFixture(ctx: *core.ReadContext) core.ReadError!void {
    const paragraph = try ctx.out.beginParagraph();
    const image = try ctx.out.beginImage("embedded:pic", "");
    try ctx.out.text("a diagram");
    ctx.out.endInline(image);
    ctx.out.endBlock(paragraph);
    _ = try ctx.out.resource("embedded:pic", png_bytes, "image/png");
}

const fixture_reader = core.Reader(.{
    .id = "ai.insan.zenfmt.test-media",
    .format = "mediafix",
    .extensions = &.{"mediafix"},
    .input = .seekable,
    .data_version = 1,
    .read = readFixture,
});

const Bundle = core.Bundle(.{
    .readers = .{fixture_reader},
    .writers = .{@import("zenfmt_markdown").writer},
});

fn readExternal(ctx: *core.ReadContext) core.ReadError!void {
    const paragraph = try ctx.out.beginParagraph();
    const image = try ctx.out.beginImage("https://example.test/chart.svg", "chart");
    try ctx.out.text("remote chart");
    ctx.out.endInline(image);
    ctx.out.endBlock(paragraph);
    _ = try ctx.out.externalResource(
        "https://example.test/chart.svg",
        "image/svg+xml",
        .{ .alt = "Quarterly chart", .pixel_width = 640, .pixel_height = 480 },
    );
}

const external_reader = core.Reader(.{
    .id = "ai.insan.zenfmt.test-external-resource",
    .format = "externalfix",
    .extensions = &.{"externalfix"},
    .read = readExternal,
});

const ExternalBundle = core.Bundle(.{
    .readers = .{external_reader},
    .writers = .{@import("zenfmt_markdown").writer},
});

test "media bytes commit beside the artifact and the manifest lists them" {
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, test_dir) catch {};
    try cwd.createDirPath(io, test_dir);
    defer cwd.deleteTree(io, test_dir) catch {};

    const input_path = test_dir ++ "/doc.mediafix";
    const output_path = test_dir ++ "/doc.md";
    try cwd.writeFile(io, .{ .sub_path = input_path, .data = "irrelevant" });

    var conversion = Bundle.convert(gpa, io, .{
        .input = .{ .path = input_path },
        .output = .{ .path = output_path },
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.success, conversion.status);

    // The artifact references the extracted file, not the reader's source.
    const artifact = try cwd.readFileAlloc(io, output_path, gpa, .limited(4096));
    defer gpa.free(artifact);
    try testing.expectEqualStrings("![a diagram](doc_media/image-1.png)\n", artifact);

    // The bytes landed exactly.
    const media = try cwd.readFileAlloc(
        io,
        test_dir ++ "/doc_media/image-1.png",
        gpa,
        .limited(4096),
    );
    defer gpa.free(media);
    try testing.expectEqualStrings(png_bytes, media);

    // The manifest lists the file with its digest.
    const manifest_bytes = try cwd.readFileAlloc(
        io,
        output_path ++ ".zenfmt.json",
        gpa,
        .limited(1 << 20),
    );
    defer gpa.free(manifest_bytes);
    const digest = zenfmt.manifest.digestHex(png_bytes);
    const expected = try std.fmt.allocPrint(
        gpa,
        "\"media\":[{{\"digest\":{{\"algorithm\":\"blake3-256\"," ++
            "\"scope\":\"content\",\"value\":\"{s}\"}}," ++
            "\"kind\":\"embedded\",\"mime\":\"image/png\"," ++
            "\"path\":\"doc_media/image-1.png\"," ++
            "\"source\":\"embedded:pic\"}}]",
        .{&digest},
    );
    defer gpa.free(expected);
    try testing.expect(std.mem.indexOf(u8, manifest_bytes, expected) != null);
}

test "stream output extracts nothing and keeps the source URL" {
    const io = testing.io;
    const gpa = testing.allocator;

    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = Bundle.convert(gpa, io, .{
        .input = .{ .bytes = .{ .name = "doc.mediafix", .data = "irrelevant" } },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.success, conversion.status);
    try testing.expectEqualStrings("![a diagram](embedded:pic)\n", out.buffered());
    // No `media` key: nothing was committed anywhere.
    try testing.expect(std.mem.indexOf(u8, conversion.manifest_json.?, "\"media\"") == null);
}

test "external resources stay external and retain typed metadata" {
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const directory = test_dir ++ "-external";

    cwd.deleteTree(io, directory) catch {};
    try cwd.createDirPath(io, directory);
    defer cwd.deleteTree(io, directory) catch {};

    const output_path = directory ++ "/doc.md";
    var conversion = ExternalBundle.convert(gpa, io, .{
        .input = .{ .bytes = .{ .name = "doc.externalfix", .data = "ignored" } },
        .output = .{ .path = output_path },
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.success, conversion.status);

    const artifact = try cwd.readFileAlloc(io, output_path, gpa, .limited(4096));
    defer gpa.free(artifact);
    try testing.expectEqualStrings(
        "![remote chart](https://example.test/chart.svg \"chart\")\n",
        artifact,
    );
    const sidecar = conversion.manifest_json.?;
    try testing.expect(std.mem.indexOf(u8, sidecar, "\"kind\":\"external\"") != null);
    try testing.expect(std.mem.indexOf(u8, sidecar, "\"scope\":\"reference\"") != null);
    try testing.expect(std.mem.indexOf(u8, sidecar, "\"alt\":\"Quarterly chart\"") != null);
    try testing.expect(std.mem.indexOf(u8, sidecar, "\"pixel_height\":480") != null);
    try testing.expect(std.mem.indexOf(u8, sidecar, "\"pixel_width\":640") != null);
}

test "publication preflight leaves the whole media ensemble unpublished" {
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const directory = test_dir ++ "-preflight";

    cwd.deleteTree(io, directory) catch {};
    try cwd.createDirPath(io, directory);
    defer cwd.deleteTree(io, directory) catch {};

    const output_path = directory ++ "/doc.md";
    try cwd.writeFile(io, .{ .sub_path = output_path, .data = "existing" });
    var conversion = Bundle.convert(gpa, io, .{
        .input = .{ .bytes = .{ .name = "doc.mediafix", .data = "ignored" } },
        .output = .{ .path = output_path },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqualStrings(
        "core.destination-exists",
        conversion.reports[0].code,
    );
    const artifact = try cwd.readFileAlloc(io, output_path, gpa, .limited(64));
    defer gpa.free(artifact);
    try testing.expectEqualStrings("existing", artifact);
    try testing.expectError(
        error.FileNotFound,
        cwd.access(io, output_path ++ ".zenfmt.json", .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        cwd.access(io, directory ++ "/doc_media/image-1.png", .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        cwd.access(io, directory ++ "/doc_media", .{}),
    );
}
