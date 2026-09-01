//! End-to-end conversion tests over the umbrella `zenfmt` module: the
//! phase 1 exit criterion, exercised the way an embedding application and
//! the CLI both use the library.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const ooxml = @import("zenfmt_ooxml");

const test_dir = ".zig-cache/zenfmt-e2e";

test "bytes to stream: text becomes markdown with a manifest value" {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);

    var conversion = zenfmt.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{
            .name = "note.txt",
            .data = "line one\nline two\n\nsecond *paragraph*\n",
        } },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    try testing.expectEqualStrings(
        "line one\nline two\n\nsecond \\*paragraph\\*\n",
        out.buffered(),
    );

    // The returned manifest binds the exact output bytes.
    const manifest_json = conversion.manifest_json.?;
    const digest = zenfmt.manifest.digestHex(out.buffered());
    try testing.expect(std.mem.indexOf(u8, manifest_json, &digest) != null);
    try testing.expect(std.mem.indexOf(u8, manifest_json, "\"format\":\"markdown\"") != null);
    try testing.expect(std.mem.indexOf(u8, manifest_json, "\"format\":\"text\"") != null);
}

test "xlsx custom date and time columns render as temporal values in markdown" {
    const workbook =
        \\<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        \\  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        \\<sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets>
        \\</workbook>
    ;
    const rels =
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId1"
        \\  Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
        \\  Target="worksheets/sheet1.xml"/>
        \\</Relationships>
    ;
    const styles =
        \\<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\<numFmts count="5">
        \\<numFmt numFmtId="164" formatCode="yyyy-mm-dd"/>
        \\<numFmt numFmtId="165" formatCode="yyyy-mm-dd hh:mm"/>
        \\<numFmt numFmtId="166" formatCode="yyyy-mm-dd hh:mm:ss"/>
        \\<numFmt numFmtId="167" formatCode="hh:mm"/>
        \\<numFmt numFmtId="168" formatCode="0.00%"/>
        \\</numFmts>
        \\<cellXfs count="6">
        \\<xf numFmtId="0"/><xf numFmtId="164"/><xf numFmtId="165"/>
        \\<xf numFmtId="166"/><xf numFmtId="167"/><xf numFmtId="168"/>
        \\</cellXfs>
        \\</styleSheet>
    ;
    const sheet =
        \\<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        \\<sheetData>
        \\<row r="1"><c r="A1" t="inlineStr"><is><t>Case</t></is></c>
        \\<c r="B1" t="inlineStr"><is><t>Value</t></is></c></row>
        \\<row r="2"><c r="A2" t="inlineStr"><is><t>Date only</t></is></c>
        \\<c r="B2" s="1"><v>46212</v></c></row>
        \\<row r="3"><c r="A3" t="inlineStr"><is><t>Date and time</t></is></c>
        \\<c r="B3" s="2"><v>46212.60416666666</v></c></row>
        \\<row r="4"><c r="A4" t="inlineStr"><is><t>Date and seconds</t></is></c>
        \\<c r="B4" s="3"><v>46212.60434027778</v></c></row>
        \\<row r="5"><c r="A5" t="inlineStr"><is><t>Time only</t></is></c>
        \\<c r="B5" s="4"><v>0.6041666666666666</v></c></row>
        \\<row r="6"><c r="A6" t="inlineStr"><is><t>Rate</t></is></c>
        \\<c r="B6" s="5"><v>0.125</v></c></row>
        \\</sheetData>
        \\</worksheet>
    ;
    const bytes = try ooxml.zip.buildStoredArchive(testing.allocator, &.{
        .{ .name = "xl/workbook.xml", .data = workbook },
        .{ .name = "xl/_rels/workbook.xml.rels", .data = rels },
        .{ .name = "xl/styles.xml", .data = styles },
        .{ .name = "xl/worksheets/sheet1.xml", .data = sheet },
    });
    defer testing.allocator.free(bytes);

    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = zenfmt.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "dates.xlsx", .data = bytes } },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "| Date only        | 2026-07-09          |") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "| Date and time    | 2026-07-09 14:30:00 |") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "| Date and seconds | 2026-07-09 14:30:15 |") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "| Time only        | 14:30:00            |") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "| Rate             | 12.5%               |") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "46212.604") == null);
}

test "an unknown explicit format fails with a usage-class report" {
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);

    var conversion = zenfmt.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "note.txt", .data = "hello\n" } },
        .output = .{ .writer = &out },
        .from = "docs",
    });
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(zenfmt.Status.failed, conversion.status);
    try testing.expectEqual(zenfmt.report.ExitClass.usage, conversion.exit_class);
    try testing.expectEqual(@as(usize, 1), conversion.reports.len);
    try testing.expectEqualStrings("core.unknown-input-format", conversion.reports[0].code);
    // Nothing was written to the stream.
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
    // A failed conversion never returns a manifest.
    try testing.expectEqual(@as(?[]const u8, null), conversion.manifest_json);
}

test "path to path: artifact and adjacent manifest are committed together" {
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, test_dir) catch {};
    try cwd.createDirPath(io, test_dir);
    defer cwd.deleteTree(io, test_dir) catch {};

    const input_path = test_dir ++ "/report.txt";
    const output_path = test_dir ++ "/report.md";
    try cwd.writeFile(io, .{ .sub_path = input_path, .data = "alpha\n\nbeta\n" });

    var conversion = zenfmt.convert(gpa, io, .{
        .input = .{ .path = input_path },
        .output = .{ .path = output_path },
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(zenfmt.Status.success, conversion.status);

    const artifact = try cwd.readFileAlloc(io, output_path, gpa, .limited(4096));
    defer gpa.free(artifact);
    try testing.expectEqualStrings("alpha\n\nbeta\n", artifact);

    const manifest_bytes = try cwd.readFileAlloc(
        io,
        output_path ++ ".zenfmt.json",
        gpa,
        .limited(1 << 20),
    );
    defer gpa.free(manifest_bytes);

    // The committed manifest verifies against the committed artifact.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const loaded = try zenfmt.manifest.load(arena_state.allocator(), manifest_bytes, .{});
    try testing.expectEqualStrings("markdown", loaded.artifact_format);
    const digest = zenfmt.manifest.digestHex(artifact);
    try testing.expectEqualStrings(&digest, &loaded.artifact_digest_hex);
}

test "an existing destination is refused without overwrite and replaced with it" {
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, test_dir) catch {};
    try cwd.createDirPath(io, test_dir);
    defer cwd.deleteTree(io, test_dir) catch {};

    const input_path = test_dir ++ "/again.txt";
    const output_path = test_dir ++ "/again.md";
    try cwd.writeFile(io, .{ .sub_path = input_path, .data = "one\n" });
    try cwd.writeFile(io, .{ .sub_path = output_path, .data = "existing" });

    var refused = zenfmt.convert(gpa, io, .{
        .input = .{ .path = input_path },
        .output = .{ .path = output_path },
    });
    defer refused.deinit(gpa);
    try testing.expectEqual(zenfmt.Status.failed, refused.status);
    try testing.expectEqualStrings("core.destination-exists", refused.reports[0].code);

    // The existing file is untouched.
    const untouched = try cwd.readFileAlloc(io, output_path, gpa, .limited(4096));
    defer gpa.free(untouched);
    try testing.expectEqualStrings("existing", untouched);

    var replaced = zenfmt.convert(gpa, io, .{
        .input = .{ .path = input_path },
        .output = .{ .path = output_path },
        .overwrite = true,
    });
    defer replaced.deinit(gpa);
    try testing.expectEqual(zenfmt.Status.success, replaced.status);
}

test "a stale adjacent manifest warns and is ignored" {
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, test_dir) catch {};
    try cwd.createDirPath(io, test_dir);
    defer cwd.deleteTree(io, test_dir) catch {};

    const input_path = test_dir ++ "/edited.txt";
    try cwd.writeFile(io, .{ .sub_path = input_path, .data = "current content\n" });
    try cwd.writeFile(io, .{
        .sub_path = input_path ++ ".zenfmt.json",
        .data = "{ not even json",
    });

    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = zenfmt.convert(gpa, io, .{
        .input = .{ .path = input_path },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    var found = false;
    for (conversion.reports) |item| {
        if (std.mem.eql(u8, item.code, "core.stale-or-invalid-manifest")) found = true;
    }
    try testing.expect(found);
}

test "an oversized adjacent manifest names the exact safe override" {
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = std.Io.Dir.cwd();
    const directory = test_dir ++ "-large-manifest";
    cwd.deleteTree(io, directory) catch {};
    try cwd.createDirPath(io, directory);
    defer cwd.deleteTree(io, directory) catch {};

    const input_path = directory ++ "/edited.txt";
    try cwd.writeFile(io, .{ .sub_path = input_path, .data = "body\n" });
    try cwd.writeFile(io, .{
        .sub_path = input_path ++ ".zenfmt.json",
        .data = "{bad",
    });
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = zenfmt.convert(gpa, io, .{
        .input = .{ .path = input_path },
        .output = .{ .writer = &out },
        .limits = .{ .max_manifest_bytes = 4 },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    const diagnostic = conversion.reports[0];
    try testing.expectEqualStrings(
        "core.stale-or-invalid-manifest",
        diagnostic.code,
    );
    try testing.expect(std.mem.indexOf(
        u8,
        diagnostic.directions[0].explanation,
        "--limit max_manifest_bytes=8",
    ) != null);
}

test "invalid programmatic limits explain the exact correction" {
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = zenfmt.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "note.txt", .data = "hello" } },
        .output = .{ .writer = &out },
        .limits = .{ .max_depth = 0 },
    });
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(zenfmt.Status.failed, conversion.status);
    try testing.expectEqualStrings(
        "core.invalid-limit-configuration",
        conversion.reports[0].code,
    );
    try testing.expect(std.mem.indexOf(
        u8,
        conversion.reports[0].directions[0].explanation,
        "ConvertOptions.limits.max_depth",
    ) != null);
}

test "input size diagnostics name the measured size and exact override" {
    var buffer: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = zenfmt.convert(testing.allocator, testing.io, .{
        .input = .{ .bytes = .{ .name = "large.txt", .data = "12345" } },
        .output = .{ .writer = &out },
        .limits = .{ .max_input_bytes = 4 },
    });
    defer conversion.deinit(testing.allocator);

    try testing.expectEqual(zenfmt.Status.failed, conversion.status);
    const diagnostic = conversion.reports[0];
    try testing.expectEqualStrings("core.input-too-large", diagnostic.code);
    try testing.expect(std.mem.indexOf(u8, diagnostic.problem, "5 bytes") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        diagnostic.directions[0].explanation,
        "--limit max_input_bytes=5",
    ) != null);
}

test "allocation failure at every site still returns the reserved report" {
    var buffer: [4096]u8 = undefined;

    var fail_index: usize = 0;
    while (fail_index < 200) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var out = std.Io.Writer.fixed(&buffer);
        var conversion = zenfmt.convert(failing.allocator(), testing.io, .{
            .input = .{ .bytes = .{
                .name = "note.txt",
                .data = "some words here\n\nand more\n",
            } },
            .output = .{ .writer = &out },
        });
        const status = conversion.status;
        if (status == .failed) {
            try testing.expectEqual(@as(usize, 1), conversion.reports.len);
            try testing.expectEqualStrings("core.out-of-memory", conversion.reports[0].code);
        }
        conversion.deinit(failing.allocator());
        if (status == .success and !failing.has_induced_failure) break;
    }
    // The loop must reach a fail index beyond every allocation the
    // conversion performs, proving OOM was induced at every site.
    try testing.expect(fail_index < 200);
}
