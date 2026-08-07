//! DOCX end-to-end and adversarial tests (ZDS 0002, phase 4 exit
//! criteria): a real-shaped document with headings, styled runs,
//! hyperlinks, lists, merged-cell tables, and footnotes converts
//! correctly, and every refusal refuses with the specific report the
//! adversarial corpus asserts.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const zip = @import("zenfmt_ooxml").zip;

const content_types =
    \\<?xml version="1.0"?>
    \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>
;

const package_rels =
    \\<?xml version="1.0"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    \\</Relationships>
;

const styles_xml =
    \\<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    \\<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>
    \\<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/></w:style>
    \\</w:styles>
;

const numbering_xml =
    \\<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    \\<w:abstractNum w:abstractNumId="0">
    \\<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl>
    \\<w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
    \\</w:abstractNum>
    \\<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
    \\</w:numbering>
;

const document_rels =
    \\<?xml version="1.0"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\<Relationship Id="rId5" Type="http://x/hyperlink" Target="https://ziglang.org/" TargetMode="External"/>
    \\</Relationships>
;

const footnotes_xml =
    \\<w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    \\<w:footnote w:id="1"><w:p><w:r><w:t>The note body.</w:t></w:r></w:p></w:footnote>
    \\</w:footnotes>
;

const document_xml =
    \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    \\  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    \\<w:body>
    \\<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>The Report</w:t></w:r></w:p>
    \\<w:p><w:r><w:t xml:space="preserve">Plain then </w:t></w:r>
    \\<w:r><w:rPr><w:b/><w:i/></w:rPr><w:t>bold italic</w:t></w:r>
    \\<w:r><w:t xml:space="preserve"> then a </w:t></w:r>
    \\<w:hyperlink r:id="rId5"><w:r><w:t>link</w:t></w:r></w:hyperlink>
    \\<w:r><w:t xml:space="preserve"> and a note</w:t></w:r>
    \\<w:r><w:footnoteReference w:id="1"/></w:r>
    \\<w:r><w:t>.</w:t></w:r></w:p>
    \\<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
    \\<w:r><w:t>first item</w:t></w:r></w:p>
    \\<w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="1"/></w:numPr></w:pPr>
    \\<w:r><w:t>nested bullet</w:t></w:r></w:p>
    \\<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
    \\<w:r><w:t>second item</w:t></w:r></w:p>
    \\<w:tbl>
    \\<w:tblGrid><w:gridCol w:w="2400"/><w:gridCol w:w="2400"/></w:tblGrid>
    \\<w:tr><w:trPr><w:tblHeader/></w:trPr>
    \\<w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc>
    \\<w:tc><w:p><w:r><w:t>Count</w:t></w:r></w:p></w:tc></w:tr>
    \\<w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr>
    \\<w:p><w:r><w:t>merged across both</w:t></w:r></w:p></w:tc></w:tr>
    \\</w:tbl>
    \\<w:p><w:r><w:t>after table</w:t></w:r></w:p>
    \\</w:body>
    \\</w:document>
;

fn buildDocx(gpa: std.mem.Allocator) ![]u8 {
    return zip.buildStoredArchive(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = content_types },
        .{ .name = "_rels/.rels", .data = package_rels },
        .{ .name = "word/document.xml", .data = document_xml },
        .{ .name = "word/styles.xml", .data = styles_xml },
        .{ .name = "word/numbering.xml", .data = numbering_xml },
        .{ .name = "word/_rels/document.xml.rels", .data = document_rels },
        .{ .name = "word/footnotes.xml", .data = footnotes_xml },
    });
}

fn convertDocx(gpa: std.mem.Allocator, bytes: []const u8, out: *std.Io.Writer) zenfmt.Conversion {
    return zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "report.docx", .data = bytes } },
        .output = .{ .writer = out },
        .from = "docx",
    });
}

test "a file-backed docx converts identically to its bytes" {
    const gpa = testing.allocator;
    const io = testing.io;
    const bytes = try buildDocx(gpa);
    defer gpa.free(bytes);

    var bytes_buffer: [16 * 1024]u8 = undefined;
    var bytes_out = std.Io.Writer.fixed(&bytes_buffer);
    var from_bytes = convertDocx(gpa, bytes, &bytes_out);
    defer from_bytes.deinit(gpa);
    try testing.expectEqual(zenfmt.Status.success, from_bytes.status);

    // The same archive through the seekable file path: the reader windows
    // the file (ZDS 0013), and the output does not change by one byte.
    const dir = ".zig-cache/tmp/zenfmt-input-file";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};
    const path = dir ++ "/report.docx";
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });

    var file_buffer: [16 * 1024]u8 = undefined;
    var file_out = std.Io.Writer.fixed(&file_buffer);
    var from_file = zenfmt.convert(gpa, io, .{
        .input = .{ .path = path },
        .output = .{ .writer = &file_out },
    });
    defer from_file.deinit(gpa);
    try testing.expectEqual(zenfmt.Status.success, from_file.status);
    try testing.expectEqualStrings(bytes_out.buffered(), file_out.buffered());
    // Same source digest in both manifests: the streamed file digest
    // matches the slice digest.
    const needle = "\"source\":{\"digest\"";
    const bytes_tail = std.mem.indexOf(u8, from_bytes.manifest_json.?, needle).?;
    const file_tail = std.mem.indexOf(u8, from_file.manifest_json.?, needle).?;
    try testing.expectEqualStrings(
        from_bytes.manifest_json.?[bytes_tail..][0..120],
        from_file.manifest_json.?[file_tail..][0..120],
    );
}

test "a real-shaped docx converts to the expected markdown" {
    const gpa = testing.allocator;
    const bytes = try buildDocx(gpa);
    defer gpa.free(bytes);

    var buffer: [16 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertDocx(gpa, bytes, &out);
    defer conversion.deinit(gpa);

    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    try testing.expectEqualStrings(
        \\# The Report
        \\
        \\Plain then **_bold italic_** then a [link](https://ziglang.org/) and a note[^1].
        \\
        \\1. first item
        \\   - nested bullet
        \\2. second item
        \\
        \\| Name               | Count |
        \\| ------------------ | ----- |
        \\| merged across both |       |
        \\
        \\after table
        \\
        \\[^1]: The note body.
        \\
    , out.buffered());

    // The merged cell was degraded, and the manifest says so.
    var found_merge_note = false;
    for (conversion.reports) |item| {
        if (std.mem.eql(u8, item.code, "docx.merged-cells-degraded")) found_merge_note = true;
    }
    try testing.expect(found_merge_note);
    // Preservation data is absent here: every paragraph style was a
    // heading, so nothing needed carrying.
    try testing.expect(conversion.manifest_json != null);
}

test "sniffing routes an extensionless zip to the docx reader" {
    const gpa = testing.allocator;
    const bytes = try buildDocx(gpa);
    defer gpa.free(bytes);

    var buffer: [16 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "mystery-file", .data = bytes } },
        .output = .{ .writer = &out },
    });
    defer conversion.deinit(gpa);
    try testing.expectEqual(zenfmt.Status.success, conversion.status);
}

// ------------------------------------------------------------ adversarial

test "a zip bomb is refused with the archive-limit report" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Highly compressible content: a deflate stream of zeros.
    const expanded = try arena.alloc(u8, 4 * 1024 * 1024);
    @memset(expanded, 0);
    const compressed_buffer = try arena.alloc(u8, 64 * 1024);
    var fixed = std.Io.Writer.fixed(compressed_buffer);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var compress = try std.compress.flate.Compress.init(
        &fixed,
        window,
        .raw,
        std.compress.flate.Compress.Options.best,
    );
    try compress.writer.writeAll(expanded);
    try compress.writer.flush();
    const bomb_payload = fixed.buffered();

    // Hand-assemble an archive whose entry declares the deflate payload.
    const bomb = try buildDeflateArchive(arena, "word/document.xml", bomb_payload, expanded.len);

    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "bomb.docx", .data = bomb } },
        .output = .{ .writer = &out },
        .from = "docx",
        .limits = .{ .max_compression_ratio = 100, .max_entry_uncompressed = 1 << 20 },
    });
    defer conversion.deinit(gpa);

    try testing.expectEqual(zenfmt.Status.failed, conversion.status);
    try testing.expectEqual(zenfmt.report.ExitClass.limit, conversion.exit_class);
    var found = false;
    for (conversion.reports) |item| {
        if (std.mem.eql(u8, item.code, "docx.archive-limit")) found = true;
    }
    try testing.expect(found);
}

test "a doctype inside the document is refused" {
    const gpa = testing.allocator;
    const bytes = try zip.buildStoredArchive(gpa, &.{
        .{ .name = "word/document.xml", .data = "<!DOCTYPE lol [<!ENTITY a \"b\">]><w:document/>" },
    });
    defer gpa.free(bytes);

    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertDocx(gpa, bytes, &out);
    defer conversion.deinit(gpa);
    try testing.expectEqual(zenfmt.Status.failed, conversion.status);
    try testing.expectEqualStrings("docx.doctype-refused", conversion.reports[0].code);
}

test "traversal names and truncation are specific refusals" {
    const gpa = testing.allocator;

    const traversal = try zip.buildStoredArchive(gpa, &.{
        .{ .name = "../../outside", .data = "x" },
    });
    defer gpa.free(traversal);
    {
        var buffer: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        var conversion = convertDocx(gpa, traversal, &out);
        defer conversion.deinit(gpa);
        try testing.expectEqual(zenfmt.Status.failed, conversion.status);
        try testing.expectEqualStrings("docx.hostile-archive", conversion.reports[0].code);
    }

    const intact = try buildDocx(gpa);
    defer gpa.free(intact);
    {
        var buffer: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        var conversion = convertDocx(gpa, intact[0 .. intact.len - 8], &out);
        defer conversion.deinit(gpa);
        try testing.expectEqual(zenfmt.Status.failed, conversion.status);
        try testing.expectEqualStrings("docx.not-an-archive", conversion.reports[0].code);
    }
}

test "deep xml nesting hits the depth refusal" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var deep: std.ArrayList(u8) = .empty;
    try deep.appendSlice(arena, "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>");
    for (0..600) |_| try deep.appendSlice(arena, "<w:smartTag>");
    for (0..600) |_| try deep.appendSlice(arena, "</w:smartTag>");
    try deep.appendSlice(arena, "</w:body></w:document>");

    const bytes = try zip.buildStoredArchive(arena, &.{
        .{ .name = "word/document.xml", .data = deep.items },
    });

    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertDocx(gpa, bytes, &out);
    defer conversion.deinit(gpa);
    try testing.expectEqual(zenfmt.Status.failed, conversion.status);
    try testing.expectEqual(zenfmt.report.ExitClass.limit, conversion.exit_class);
}

/// A single-entry archive whose payload is a raw deflate stream: the
/// zip-bomb fixture.
fn buildDeflateArchive(
    arena: std.mem.Allocator,
    name: []const u8,
    deflated: []const u8,
    expanded_len: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "PK\x03\x04");
    try appendInt(&out, arena, u16, 20);
    try appendInt(&out, arena, u16, 0);
    try appendInt(&out, arena, u16, 8); // deflate
    try appendInt(&out, arena, u32, 0);
    try appendInt(&out, arena, u32, 0); // crc unchecked
    try appendInt(&out, arena, u32, @intCast(deflated.len));
    try appendInt(&out, arena, u32, @intCast(expanded_len));
    try appendInt(&out, arena, u16, @intCast(name.len));
    try appendInt(&out, arena, u16, 0);
    try out.appendSlice(arena, name);
    try out.appendSlice(arena, deflated);

    const dir_offset: u32 = @intCast(out.items.len);
    try out.appendSlice(arena, "PK\x01\x02");
    try appendInt(&out, arena, u16, 20);
    try appendInt(&out, arena, u16, 20);
    try appendInt(&out, arena, u16, 0);
    try appendInt(&out, arena, u16, 8);
    try appendInt(&out, arena, u32, 0);
    try appendInt(&out, arena, u32, 0);
    try appendInt(&out, arena, u32, @intCast(deflated.len));
    try appendInt(&out, arena, u32, @intCast(expanded_len));
    try appendInt(&out, arena, u16, @intCast(name.len));
    try appendInt(&out, arena, u16, 0);
    try appendInt(&out, arena, u16, 0);
    try appendInt(&out, arena, u16, 0);
    try appendInt(&out, arena, u16, 0);
    try appendInt(&out, arena, u32, 0);
    try appendInt(&out, arena, u32, 0);
    try out.appendSlice(arena, name);
    const dir_size: u32 = @intCast(out.items.len - dir_offset);

    try out.appendSlice(arena, "PK\x05\x06");
    try appendInt(&out, arena, u16, 0);
    try appendInt(&out, arena, u16, 0);
    try appendInt(&out, arena, u16, 1);
    try appendInt(&out, arena, u16, 1);
    try appendInt(&out, arena, u32, dir_size);
    try appendInt(&out, arena, u32, dir_offset);
    try appendInt(&out, arena, u16, 0);
    return out.items;
}

fn appendInt(out: *std.ArrayList(u8), arena: std.mem.Allocator, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .little);
    try out.appendSlice(arena, &buffer);
}
