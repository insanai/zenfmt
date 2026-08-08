//! The default bundle: the plugins shipped by the standard zenfmt CLI.
//!
//! Adding a format to the standard distribution is one import and one line
//! in a tuple here; the `Bundle` constructor validates the table at compile
//! time and the engine never learns a format name any other way.

const core = @import("zenfmt_core");
const text = @import("zenfmt_text");
const markdown = @import("zenfmt_markdown");
const csv = @import("zenfmt_csv");
const docx = @import("zenfmt_docx");
const rtf = @import("zenfmt_rtf");
const xlsx = @import("zenfmt_xlsx");
const odt = @import("zenfmt_odt");
const pptx = @import("zenfmt_pptx");
const html = @import("zenfmt_html");
const asciidoc = @import("zenfmt_asciidoc");
const rst = @import("zenfmt_rst");
const ods = @import("zenfmt_ods");
const odp = @import("zenfmt_odp");
const epub = @import("zenfmt_epub");
const pdf = @import("zenfmt_pdf");
const doc = @import("zenfmt_doc");
const xls = @import("zenfmt_xls");
const ppt = @import("zenfmt_ppt");
const xlsb = @import("zenfmt_xlsb");

/// The plugin tables, named once so every bundle built from them is the same
/// bundle. The browser module must not be able to ship a different format
/// list from the CLI (ZDS 0015), and the surest way to guarantee that is to
/// give them nothing to disagree about.
pub const readers = .{
    text.reader,
    markdown.reader,
    csv.reader,
    docx.reader,
    rtf.reader,
    xlsx.reader,
    odt.reader,
    pptx.reader,
    html.reader,
    asciidoc.reader,
    rst.reader,
    ods.reader,
    odp.reader,
    epub.reader,
    pdf.reader,
    doc.reader,
    xls.reader,
    ppt.reader,
    xlsb.reader,
};

pub const writers = .{markdown.writer};

/// The bundle the CLI and the Python library use: full host authority.
pub const Default = core.Bundle(.{
    .readers = readers,
    .writers = writers,
});

/// The same formats with no filesystem authority compiled in, for the browser
/// module and any other embedding that converts caller-owned bytes. It is a
/// host-adapter variant, not a reduced engine: same readers, same writer,
/// same document semantics.
pub const Browser = core.Bundle(.{
    .readers = readers,
    .writers = writers,
    .host = .pure,
});

test "the default bundle exposes its formats" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 19), Default.readers.len);
    try std.testing.expectEqual(@as(usize, 1), Default.writers.len);
    try std.testing.expectEqualStrings("markdown", Default.default_output_format);
    try std.testing.expectEqualStrings("md", Default.primaryExtension("markdown").?);
}

test "the browser bundle is the default bundle without host authority" {
    const std = @import("std");
    try std.testing.expectEqual(Default.readers.len, Browser.readers.len);
    try std.testing.expectEqual(Default.writers.len, Browser.writers.len);
    for (Default.readers, Browser.readers) |native, browser| {
        try std.testing.expectEqualStrings(native.format, browser.format);
        try std.testing.expectEqualStrings(native.id, browser.id);
    }
    try std.testing.expectEqual(core.host.Mode.host, Default.host_mode);
    try std.testing.expectEqual(core.host.Mode.pure, Browser.host_mode);
}
