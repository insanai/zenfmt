//! The DOCX diagnostic catalog (ZDS 0002, Diagnostics): every report the
//! reader can emit, each answering the four questions. ZDS 0003 cites
//! these codes in its mapping and omissions tables.

const std = @import("std");
const core = @import("zenfmt_core");

pub fn archiveReport(err: anytype, name: []const u8) core.Report {
    _ = name;
    return switch (err) {
        error.HostileEntryName => .{
            .severity = .err,
            .code = "docx.hostile-archive",
            .title = "THE ARCHIVE LOOKS HOSTILE",
            .problem = "An entry in this archive has a name that tries to " ++
                "escape the archive: an absolute path, a `..` component, " ++
                "a backslash, or a NUL byte. No legitimate document " ++
                "produces such names.",
            .consequence = "The archive was refused outright and no " ++
                "output file was created.",
            .exit_class = .limit,
            .directions = &.{.{
                .title = "Do not trust this file",
                .explanation = "Treat the file as suspect. If it is " ++
                    "supposed to be a real document, re-export it from " ++
                    "the original application.",
            }},
        },
        error.EncryptedEntry => .{
            .severity = .err,
            .code = "docx.encrypted",
            .title = "THE DOCUMENT IS ENCRYPTED",
            .problem = "This archive contains encrypted entries, and " ++
                "zenfmt does not decrypt documents.",
            .consequence = "The conversion stopped and no output file " ++
                "was created.",
            .directions = &.{.{
                .title = "Remove the protection first",
                .explanation = "Open the document in its native " ++
                    "application, remove the password protection, save, " ++
                    "and convert the unprotected copy.",
            }},
        },
        error.LimitExceeded => .{
            .severity = .err,
            .code = "docx.archive-limit",
            .title = "ARCHIVE EXPANDS TOO FAR",
            .problem = "Expanding this archive exceeded a resource " ++
                "limit: too many entries, an entry too large, or a " ++
                "compression ratio in zip-bomb territory.",
            .consequence = "The conversion stopped while the limit held " ++
                "and no output file was created.",
            .exit_class = .limit,
            .directions = &.{.{
                .title = "Raise the limit if the file is trusted",
                .explanation = "If the document is legitimate and from a " ++
                    "trusted source, raise only the relevant limit for " ++
                    "this run — for example --limit " ++
                    "max_compression_ratio=600. This permits " ++
                    "substantially more decompression.",
            }},
        },
        error.UnsupportedMethod => .{
            .severity = .err,
            .code = "docx.unsupported-compression",
            .title = "UNSUPPORTED COMPRESSION METHOD",
            .problem = "An entry uses a compression method other than " ++
                "stored or deflate, which no office application writes.",
            .consequence = "The conversion stopped and no output file " ++
                "was created.",
            .directions = &.{.{
                .title = "Re-export the document",
                .explanation = "Re-save the document from its native " ++
                    "application; office suites write standard deflate " ++
                    "archives.",
            }},
        },
        else => .{
            .severity = .err,
            .code = "docx.not-an-archive",
            .title = "NOT A READABLE DOCX ARCHIVE",
            .problem = "This file is not a ZIP archive zenfmt can read: " ++
                "it may be truncated, corrupted, or not a DOCX at all.",
            .consequence = "The conversion stopped and no output file " ++
                "was created.",
            .directions = &.{.{
                .title = "Check the file",
                .explanation = "Open the file in Word or LibreOffice to " ++
                    "verify it is intact. If it opens there, keep the " ++
                    "file and report this. If the format was misdetected, " ++
                    "select the real one with --from.",
            }},
        },
    };
}

pub fn missingPartReport(name: []const u8, part: []const u8) core.Report {
    _ = name;
    _ = part;
    return .{
        .severity = .err,
        .code = "docx.missing-document-part",
        .title = "THE MAIN DOCUMENT PART IS MISSING",
        .problem = "The archive opens, but the main document part the " ++
            "package relationships point at is not in it.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the document",
            .explanation = "The file is structurally incomplete. " ++
                "Re-save it from its native application and convert the " ++
                "fresh copy.",
        }},
    };
}

pub fn doctypeReport(name: []const u8) core.Report {
    _ = name;
    return .{
        .severity = .err,
        .code = "docx.doctype-refused",
        .title = "XML WITH A DOCTYPE REFUSED",
        .problem = "A part in this document carries a DOCTYPE " ++
            "declaration. No office application writes one, and DTD " ++
            "processing is how XML entity-expansion attacks work, so " ++
            "zenfmt never processes them.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .exit_class = .limit,
        .directions = &.{.{
            .title = "Do not trust this file",
            .explanation = "Treat the file as suspect; a legitimate " ++
                "document re-exported from its native application will " ++
                "not carry a DOCTYPE.",
        }},
    };
}

pub fn xmlDepthReport(name: []const u8) core.Report {
    _ = name;
    return .{
        .severity = .err,
        .code = "docx.xml-too-deep",
        .title = "XML NESTS TOO DEEPLY",
        .problem = "A part in this document nests XML elements deeper " ++
            "than the limit, which real documents never do.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .exit_class = .limit,
        .directions = &.{.{
            .title = "Raise the limit if the file is trusted",
            .explanation = "If this is a legitimate document, raise the " ++
                "depth limit for this run with --limit " ++
                "max_xml_depth=<depth>. Deeper nesting costs " ++
                "proportionally more stack.",
        }},
    };
}

pub fn malformedXmlReport(name: []const u8) core.Report {
    _ = name;
    return .{
        .severity = .err,
        .code = "docx.malformed-xml",
        .title = "MALFORMED XML INSIDE THE DOCUMENT",
        .problem = "A part inside this document is not well-formed XML, " ++
            "so the document cannot be read.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the document",
            .explanation = "Open the document in Word or LibreOffice; if " ++
                "it opens, re-save it and convert the fresh copy. If it " ++
                "does not, the file is corrupted and the original " ++
                "producer must repair it.",
        }},
    };
}

pub fn unhandledReport(element: []const u8) core.Report {
    return .{
        .severity = .warning,
        .code = "docx.unhandled-construct",
        .title = "UNHANDLED CONSTRUCT",
        .problem = "This document uses a WordprocessingML construct " ++
            "zenfmt does not yet handle. Its children, if any, were " ++
            "processed as ordinary content.",
        .consequence = "Whatever the construct itself expressed is " ++
            "absent from the output.",
        .loss = .dropped,
        .context = .{ .logical = element },
        .directions = &.{.{
            .title = "Keep the source and report this",
            .explanation = "Keep the source document. If the missing " ++
                "construct matters, report it with this code and the " ++
                "producing application's name so a mapping can be added.",
        }},
    };
}

pub fn mergedCellNote() core.Report {
    return .{
        .severity = .note,
        .code = "docx.merged-cells-degraded",
        .title = "MERGED CELLS DEGRADED",
        .problem = "This document merges table cells across rows or " ++
            "columns.",
        .consequence = "Merged content sits in its first cell; the " ++
            "covered positions are empty.",
        .loss = .structural,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source document if the merged-cell " ++
                "layout matters.",
        }},
    };
}

pub fn droppedReport(
    comptime code: []const u8,
    comptime title: []const u8,
    comptime problem: []const u8,
    comptime consequence: []const u8,
) core.Report {
    return .{
        .severity = .warning,
        .code = code,
        .title = title,
        .problem = problem,
        .consequence = consequence,
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source DOCX if those details " ++
                "matter; they exist only there. Run with --strict to " ++
                "stop instead of converting with losses.",
        }},
    };
}

pub fn degradedNote(
    comptime code: []const u8,
    comptime title: []const u8,
    comptime problem: []const u8,
    comptime consequence: []const u8,
) core.Report {
    return .{
        .severity = .note,
        .code = code,
        .title = title,
        .problem = problem,
        .consequence = consequence,
        .loss = .presentation,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source DOCX if those details matter.",
        }},
    };
}

pub fn addCounted(
    reports: *core.Reports,
    template: core.Report,
    count: u32,
) error{OutOfMemory}!void {
    var value = template;
    value.count = count;
    try reports.add(value);
}

pub fn mediaLimitNote() core.Report {
    return .{
        .severity = .note,
        .code = "docx.media-limit",
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
