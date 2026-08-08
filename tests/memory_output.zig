//! Memory publication parity (ZDS 0014): a `.memory` conversion returns the
//! complete artifact ensemble — artifact bytes plus embedded resources —
//! with the same deterministic naming, target rewriting, digests, and
//! manifest as path publication. Failure never populates the ensemble.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const core = @import("zenfmt_core");

const test_dir = ".zig-cache/tmp/zenfmt-memory-e2e";
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
    .id = "ai.insan.zenfmt.test-memory-media",
    .format = "memfix",
    .extensions = &.{"memfix"},
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
        .{ .alt = "Quarterly chart" },
    );
}

const external_reader = core.Reader(.{
    .id = "ai.insan.zenfmt.test-memory-external",
    .format = "memext",
    .extensions = &.{"memext"},
    .read = readExternal,
});

const ExternalBundle = core.Bundle(.{
    .readers = .{external_reader},
    .writers = .{@import("zenfmt_markdown").writer},
});

test "memory and path publication agree byte for byte" {
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, test_dir) catch {};
    try cwd.createDirPath(io, test_dir);
    defer cwd.deleteTree(io, test_dir) catch {};

    const input_data = "irrelevant";
    const output_path = test_dir ++ "/doc.md";

    var path_conversion = Bundle.convert(gpa, io, .{
        .input = .{ .bytes = .{ .name = "doc.memfix", .data = input_data } },
        .output = .{ .path = output_path },
    });
    defer path_conversion.deinit(gpa);
    try testing.expectEqual(core.Status.success, path_conversion.status);
    try testing.expectEqual(@as(?zenfmt.MemoryEnsemble, null), path_conversion.ensemble);

    var memory_conversion = Bundle.convert(gpa, io, .{
        .input = .{ .bytes = .{ .name = "doc.memfix", .data = input_data } },
        .output = .{ .memory = .{ .artifact_name = "doc.md" } },
    });
    defer memory_conversion.deinit(gpa);
    try testing.expectEqual(core.Status.success, memory_conversion.status);

    const ensemble = memory_conversion.ensemble.?;
    try testing.expectEqualStrings("doc.md", ensemble.artifact_name);
    try testing.expectEqualStrings("memfix", memory_conversion.source_format.?);
    try testing.expectEqualStrings("markdown", memory_conversion.output_format.?);

    // Artifact bytes match the published file, including the rewritten
    // image target.
    const published = try cwd.readFileAlloc(io, output_path, gpa, .limited(4096));
    defer gpa.free(published);
    try testing.expectEqualStrings(published, ensemble.artifact);
    try testing.expectEqualStrings(
        "![a diagram](doc_media/image-1.png)\n",
        ensemble.artifact,
    );

    // The embedded resource carries the same relative name, bytes, and
    // digest as the published media file.
    try testing.expectEqual(@as(usize, 1), ensemble.resources.len);
    const resource = ensemble.resources[0];
    try testing.expectEqualStrings("doc_media/image-1.png", resource.rel_path);
    try testing.expectEqualStrings(png_bytes, resource.bytes);
    const published_media = try cwd.readFileAlloc(
        io,
        test_dir ++ "/doc_media/image-1.png",
        gpa,
        .limited(4096),
    );
    defer gpa.free(published_media);
    try testing.expectEqualStrings(published_media, resource.bytes);
    try testing.expectEqualSlices(
        u8,
        &zenfmt.manifest.digestHex(png_bytes),
        &resource.digest_hex,
    );

    // The canonical manifest is byte-identical across the two modes.
    const sidecar = try cwd.readFileAlloc(
        io,
        output_path ++ ".zenfmt.json",
        gpa,
        .limited(1 << 20),
    );
    defer gpa.free(sidecar);
    try testing.expectEqualStrings(sidecar, memory_conversion.manifest_json.?);
    try testing.expectEqualStrings(
        path_conversion.manifest_json.?,
        memory_conversion.manifest_json.?,
    );

    // Reports agree in order and code.
    try testing.expectEqual(
        path_conversion.reports.len,
        memory_conversion.reports.len,
    );
    for (path_conversion.reports, memory_conversion.reports) |a, b| {
        try testing.expectEqualStrings(a.code, b.code);
    }

    // Memory output touched no filesystem output of its own: the only
    // artifacts on disk are the ones path publication created above.
    try testing.expectEqual(
        core.Conversion.StreamState.none,
        memory_conversion.stream,
    );
}

test "failed memory conversion returns no ensemble" {
    const gpa = testing.allocator;

    var conversion = Bundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.memfix", .data = "ignored" } },
        .output = .{ .memory = .{ .artifact_name = "doc.md" } },
        .to = "nope",
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.failed, conversion.status);
    try testing.expectEqual(@as(?zenfmt.MemoryEnsemble, null), conversion.ensemble);
    try testing.expectEqual(@as(?[]const u8, null), conversion.manifest_json);
    try testing.expectEqual(@as(?[]const u8, null), conversion.source_format);
    try testing.expectEqual(@as(?[]const u8, null), conversion.output_format);
}

test "external resources appear in the manifest but not in the ensemble" {
    const gpa = testing.allocator;

    var conversion = ExternalBundle.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "doc.memext", .data = "ignored" } },
        .output = .{ .memory = .{ .artifact_name = "doc.md" } },
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.success, conversion.status);

    const ensemble = conversion.ensemble.?;
    try testing.expectEqual(@as(usize, 0), ensemble.resources.len);
    try testing.expectEqualStrings(
        "![remote chart](https://example.test/chart.svg \"chart\")\n",
        ensemble.artifact,
    );
    const sidecar = conversion.manifest_json.?;
    try testing.expect(std.mem.indexOf(u8, sidecar, "\"kind\":\"external\"") != null);
    try testing.expect(std.mem.indexOf(u8, sidecar, "\"alt\":\"Quarterly chart\"") != null);
}

test "memory conversion through the default bundle returns text artifacts" {
    const gpa = testing.allocator;

    var conversion = zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "note.md", .data = "# Title\n\nbody\n" } },
        .output = .{ .memory = .{ .artifact_name = "note.md" } },
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(core.Status.success, conversion.status);
    const ensemble = conversion.ensemble.?;
    try testing.expect(ensemble.artifact.len > 0);
    try testing.expect(std.unicode.utf8ValidateSlice(ensemble.artifact));
    try testing.expectEqualStrings("markdown", conversion.source_format.?);
    try testing.expectEqualStrings("markdown", conversion.output_format.?);
}

test "memory conversion propagates allocation failure canonically" {
    var reached_end = false;
    var fail_index: usize = 0;
    while (fail_index < 512) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var conversion = Bundle.convert(failing.allocator(), testing.io, .{
            .input = .{ .bytes = .{ .name = "doc.memfix", .data = "ignored" } },
            .output = .{ .memory = .{ .artifact_name = "doc.md" } },
        });
        const induced = failing.has_induced_failure;
        if (induced) {
            try testing.expectEqual(core.Status.failed, conversion.status);
            try testing.expectEqual(@as(usize, 1), conversion.reports.len);
            try testing.expectEqualStrings(
                "core.out-of-memory",
                conversion.reports[0].code,
            );
            try testing.expectEqual(
                @as(?zenfmt.MemoryEnsemble, null),
                conversion.ensemble,
            );
        } else {
            reached_end = true;
        }
        conversion.deinit(failing.allocator());
        if (!induced) break;
    }
    try testing.expect(reached_end);
}
