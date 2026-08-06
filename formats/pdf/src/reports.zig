//! The PDF reader's diagnostic catalog (ZDS: pdf-reader).
//!
//! Every stable code the reader can emit, one constructor per code, all
//! following the four-question structure.

const core = @import("zenfmt_core");

pub fn notPdfReport() core.Report {
    return .{
        .severity = .err,
        .code = "pdf.not-pdf",
        .title = "NOT A PDF DOCUMENT",
        .problem = "This file has no `%PDF-` header, so it is not a PDF " ++
            "document.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Select the real format",
            .explanation = "If the format was misdetected, select the " ++
                "actual one with --from.",
        }},
    };
}

pub fn malformedReport() core.Report {
    return .{
        .severity = .err,
        .code = "pdf.malformed",
        .title = "PDF STRUCTURE IS BROKEN",
        .problem = "This document's cross-reference structure or object " ++
            "syntax is damaged in a way zenfmt could not work around.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-save the document",
            .explanation = "Open the file in a PDF viewer and save a copy; " ++
                "viewers rebuild damaged cross-reference tables.",
        }},
    };
}

pub fn encryptionReport() core.Report {
    return .{
        .severity = .err,
        .code = "pdf.encryption-refused",
        .title = "ENCRYPTED PDF REFUSED",
        .problem = "This document declares encryption in its trailer. " ++
            "zenfmt does not implement PDF decryption, even for files " ++
            "whose owner password is empty.",
        .consequence = "The conversion stopped and no output file was " ++
            "created. There is no override.",
        .directions = &.{.{
            .title = "Export an unencrypted copy",
            .explanation = "Open the document with its password in a PDF " ++
                "viewer and print or export it to a new, unencrypted PDF.",
        }},
    };
}

pub fn limitReport() core.Report {
    return .{
        .severity = .err,
        .code = "pdf.limit",
        .title = "PDF RESOURCE LIMIT HIT",
        .problem = "Reading this document exceeded a resource limit — " ++
            "a decompression budget, an object count, or a nesting depth.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .exit_class = .limit,
        .directions = &.{.{
            .title = "Raise the limit if the file is trusted",
            .explanation = "Large legitimate documents can exceed the " ++
                "defaults; raise the relevant --limit value only for " ++
                "files you trust.",
        }},
    };
}

pub fn unsupportedFilterReport(name: []const u8) core.Report {
    return .{
        .severity = .warning,
        .code = "pdf.unsupported-filter",
        .title = "UNSUPPORTED STREAM FILTER",
        .problem = "A content or data stream in this document is encoded " ++
            "with a filter zenfmt does not decode (such as JPEG, CCITT, " ++
            "JBIG2, or LZW).",
        .consequence = "That stream was skipped; any text it carried is " ++
            "missing from the output.",
        .loss = .dropped,
        .context = .{ .logical = name },
        .directions = &.{.{
            .title = "Re-save through a PDF printer",
            .explanation = "Printing the document to a new PDF normally " ++
                "re-encodes its streams with Flate, which zenfmt reads.",
        }},
    };
}

pub fn unmappableReport(count: u32) core.Report {
    return .{
        .severity = .warning,
        .code = "pdf.unmappable-text",
        .title = "SOME TEXT COULD NOT BE DECODED",
        .problem = "Some characters use a font whose encoding gives no " ++
            "path back to Unicode — typically a subset font without a " ++
            "ToUnicode map.",
        .consequence = "Those characters are missing from the output; the " ++
            "rest of the text was kept.",
        .loss = .dropped,
        .count = count,
        .directions = &.{.{
            .title = "Check the output where text looks thin",
            .explanation = "Compare suspicious passages against the " ++
                "original; re-exporting the PDF with fonts fully embedded " ++
                "usually restores the mapping.",
        }},
    };
}

pub fn imagesNote(count: u32) core.Report {
    return .{
        .severity = .note,
        .code = "pdf.images-omitted",
        .title = "SOME IMAGES OMITTED",
        .problem = "This document draws images in encodings zenfmt does " ++
            "not extract: CCITT fax, JBIG2, indexed or CMYK color, or " ++
            "inline image data.",
        .consequence = "Those images are absent from the output; JPEG, " ++
            "JPEG 2000, and 8-bit RGB or grayscale images were extracted " ++
            "beside the artifact.",
        .loss = .dropped,
        .count = count,
        .directions = &.{.{
            .title = "Extract the remaining images separately if needed",
            .explanation = "Use a dedicated image extractor for the " ++
                "encodings zenfmt leaves in place.",
        }},
    };
}

pub fn mediaLimitNote(count: u32) core.Report {
    return .{
        .severity = .warning,
        .code = "pdf.media-limit",
        .title = "MEDIA EXTRACTION STOPPED AT THE LIMIT",
        .problem = "This document embeds more image data than the media " ++
            "limits allow to extract.",
        .consequence = "Images past the limit are omitted from the " ++
            "output; the text converted completely.",
        .loss = .dropped,
        .count = count,
        .directions = &.{.{
            .title = "Raise the media limits if the images matter",
            .explanation = "Run again with --limit max_media_files=N or " ++
                "--limit max_media_bytes=N to extract more.",
        }},
    };
}

pub fn linksNote(count: u32) core.Report {
    return .{
        .severity = .note,
        .code = "pdf.links-omitted",
        .title = "LINK ANNOTATIONS OMITTED",
        .problem = "This document has link annotations. Links in PDF are " ++
            "rectangles over the page, not spans in the text, and zenfmt " ++
            "does not reconstruct which words they cover.",
        .consequence = "Link targets are absent from the output; the " ++
            "linked text itself was kept.",
        .loss = .dropped,
        .count = count,
        .directions = &.{.{
            .title = "Copy needed URLs from the source",
            .explanation = "Open the PDF and copy the link addresses that " ++
                "matter; visible URLs in the text were kept as text.",
        }},
    };
}

pub fn projectionNote() core.Report {
    return .{
        .severity = .note,
        .code = "pdf.layout-projection",
        .title = "PAGE LAYOUT PROJECTED TO FLOWING TEXT",
        .problem = "PDF describes placed glyphs, not paragraphs. zenfmt " ++
            "rebuilds lines, paragraphs, and headings from positions and " ++
            "font sizes, and reconstructs tables where drawn rules or " ++
            "aligned columns support them; multi-column text, headers, " ++
            "and footers are not reconstructed.",
        .consequence = "The output is a linear projection of each page " ++
            "in drawing order.",
        .loss = .degraded,
        .directions = &.{.{
            .title = "Prefer the source document when you have it",
            .explanation = "If this PDF was exported from Word or another " ++
                "editor, convert that source file instead; its structure " ++
                "survives completely.",
        }},
    };
}

pub fn noTextReport() core.Report {
    return .{
        .severity = .warning,
        .code = "pdf.no-text",
        .title = "NO EXTRACTABLE TEXT",
        .problem = "No page in this document draws any decodable text. " ++
            "The pages are probably scanned images.",
        .consequence = "The output file is empty of content.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Run OCR first",
            .explanation = "Scanned documents need optical character " ++
                "recognition; convert the OCR result rather than the scan.",
        }},
    };
}
