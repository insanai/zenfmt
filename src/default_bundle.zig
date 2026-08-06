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

pub const Default = core.Bundle(.{
    .readers = .{
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
    },
    .writers = .{markdown.writer},
});

test "the default bundle exposes its formats" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 19), Default.readers.len);
    try std.testing.expectEqual(@as(usize, 1), Default.writers.len);
    try std.testing.expectEqualStrings("markdown", Default.default_output_format);
    try std.testing.expectEqualStrings("md", Default.primaryExtension("markdown").?);
}
