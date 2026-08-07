//! The ODT reader's diagnostic catalog and media helpers, split out of
//! `reader.zig` (file-size rule).

const std = @import("std");
const core = @import("zenfmt_core");

pub fn archiveReport() core.Report {
    return .{
        .severity = .err,
        .code = "odt.not-an-archive",
        .title = "NOT A READABLE ODT ARCHIVE",
        .problem = "This file is not a ZIP archive zenfmt can read, or it " ++
            "trips an archive safety limit.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Check the file",
            .explanation = "Open the file in LibreOffice to verify it is " ++
                "intact, and check the detected format.",
        }},
    };
}

pub fn missingContentReport() core.Report {
    return .{
        .severity = .err,
        .code = "odt.missing-content",
        .title = "THE CONTENT PART IS MISSING",
        .problem = "The archive opens but contains no content.xml, so it " ++
            "is not an OpenDocument text file.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the document",
            .explanation = "Re-save the document from LibreOffice or its " ++
                "producing application and convert the fresh copy.",
        }},
    };
}

pub fn malformedReport() core.Report {
    return .{
        .severity = .err,
        .code = "odt.malformed-xml",
        .title = "MALFORMED XML INSIDE THE DOCUMENT",
        .problem = "A part inside this document is not well-formed XML, " ++
            "or nests beyond the safety limit.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the document",
            .explanation = "Open the document in LibreOffice; if it " ++
                "opens, re-save it and convert the fresh copy.",
        }},
    };
}

/// MIME type from the part name's extension; unknown types stay opaque
/// rather than guessed.
pub fn imageMime(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "application/octet-stream";
    const extension = name[dot + 1 ..];
    const table = [_]struct { extension: []const u8, mime: []const u8 }{
        .{ .extension = "png", .mime = "image/png" },
        .{ .extension = "jpg", .mime = "image/jpeg" },
        .{ .extension = "jpeg", .mime = "image/jpeg" },
        .{ .extension = "gif", .mime = "image/gif" },
        .{ .extension = "bmp", .mime = "image/bmp" },
        .{ .extension = "svg", .mime = "image/svg+xml" },
        .{ .extension = "tif", .mime = "image/tiff" },
        .{ .extension = "tiff", .mime = "image/tiff" },
    };
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(row.extension, extension)) return row.mime;
    }
    return "application/octet-stream";
}

pub fn mediaLimitNote() core.Report {
    return .{
        .severity = .note,
        .code = "odt.media-limit",
        .title = "MEDIA EXTRACTION STOPPED AT THE LIMIT",
        .problem = "This document embeds more image data than the " ++
            "resource limits allow to extract.",
        .consequence = "Images past the limit keep their in-archive " ++
            "references; the text converted completely.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Raise the resource limits if the images matter",
            .explanation = "Run again with --limit max_resources=N or " ++
                "--limit max_resource_bytes=N to extract more.",
        }},
    };
}

pub fn annotationReport() core.Report {
    return .{
        .severity = .warning,
        .code = "odt.annotations-dropped",
        .title = "ANNOTATIONS DROPPED",
        .problem = "This document contains annotations (comments), and " ++
            "comments have no place in the shared document tree.",
        .consequence = "The annotations are absent from the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source ODT if the annotations " ++
                "matter; they exist only there.",
        }},
    };
}

pub fn frameDroppedReport() core.Report {
    return .{
        .severity = .warning,
        .code = "odt.frame-dropped",
        .title = "A DRAWING FRAME WAS DROPPED",
        .problem = "This document contains a drawing frame with neither " ++
            "an image source nor a description, such as a decorative " ++
            "shape.",
        .consequence = "The frame is absent from the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source ODT if the drawing matters; " ++
                "it exists only there.",
        }},
    };
}
