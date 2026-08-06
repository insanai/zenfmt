//! End-to-end content detection: extensionless inputs must route to the
//! right reader purely by signature — ZIP subtypes by their characteristic
//! part names, OpenDocument and EPUB by their `mimetype` entry.

const std = @import("std");
const testing = std.testing;
const zenfmt = @import("zenfmt");
const ooxml = @import("zenfmt_ooxml");

fn convertNameless(gpa: std.mem.Allocator, data: []const u8, out: *std.Io.Writer) zenfmt.Conversion {
    return zenfmt.convert(gpa, testing.io, .{
        .input = .{ .bytes = .{ .name = "mystery-file", .data = data } },
        .output = .{ .writer = out },
    });
}

test "an extensionless spreadsheet archive routes to the ods reader" {
    const gpa = testing.allocator;
    const content =
        \\<office:document-content
        \\  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
        \\  xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
        \\  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
        \\<office:body><office:spreadsheet>
        \\<table:table table:name="Totals">
        \\<table:table-row>
        \\<table:table-cell><text:p>label</text:p></table:table-cell>
        \\<table:table-cell office:value-type="float" office:value="7"><text:p>7</text:p></table:table-cell>
        \\</table:table-row>
        \\</table:table>
        \\</office:spreadsheet></office:body></office:document-content>
    ;
    const bytes = try ooxml.zip.buildStoredArchive(gpa, &.{
        .{ .name = "mimetype", .data = "application/vnd.oasis.opendocument.spreadsheet" },
        .{ .name = "content.xml", .data = content },
    });
    defer gpa.free(bytes);

    var buffer: [8 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertNameless(gpa, bytes, &out);
    defer conversion.deinit(gpa);
    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "## Totals") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "label") != null);
}

test "an extensionless book archive routes to the epub reader" {
    const gpa = testing.allocator;
    const container =
        \\<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        \\<rootfiles><rootfile full-path="OEBPS/content.opf"
        \\  media-type="application/oebps-package+xml"/></rootfiles>
        \\</container>
    ;
    const package =
        \\<package xmlns="http://www.idpf.org/2007/opf">
        \\<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        \\<dc:title>Signatures</dc:title>
        \\</metadata>
        \\<manifest>
        \\<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
        \\</manifest>
        \\<spine><itemref idref="ch1"/></spine>
        \\</package>
    ;
    const chapter = "<html><body><h1>Found by signature</h1></body></html>";
    const bytes = try ooxml.zip.buildStoredArchive(gpa, &.{
        .{ .name = "mimetype", .data = "application/epub+zip" },
        .{ .name = "META-INF/container.xml", .data = container },
        .{ .name = "OEBPS/content.opf", .data = package },
        .{ .name = "OEBPS/ch1.xhtml", .data = chapter },
    });
    defer gpa.free(bytes);

    var buffer: [8 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var conversion = convertNameless(gpa, bytes, &out);
    defer conversion.deinit(gpa);
    try testing.expectEqual(zenfmt.Status.success, conversion.status);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "# Found by signature") != null);
}
