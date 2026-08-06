//! The RTF reader's diagnostic catalog (ZDS 0004).

const core = @import("zenfmt_core");

pub fn notRtfReport() core.Report {
    return .{
        .severity = .err,
        .code = "rtf.not-rtf",
        .title = "NOT AN RTF DOCUMENT",
        .problem = "This file does not begin with `{\\rtf`, so it is not " ++
            "an RTF document.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Select the real format",
            .explanation = "If the format was misdetected, select the " ++
                "actual one with --from.",
        }},
    };
}

pub fn tooDeepReport() core.Report {
    return .{
        .severity = .err,
        .code = "rtf.groups-too-deep",
        .title = "RTF GROUPS NEST TOO DEEPLY",
        .problem = "This document nests RTF groups deeper than any real " ++
            "producer writes.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .exit_class = .limit,
        .directions = &.{.{
            .title = "Do not trust this file",
            .explanation = "Treat the file as suspect; re-export it from " ++
                "its producing application if it is a real document.",
        }},
    };
}

pub fn unknownWordNote() core.Report {
    return .{
        .severity = .note,
        .code = "rtf.unknown-control-words",
        .title = "UNKNOWN CONTROL WORDS SKIPPED",
        .problem = "This document uses RTF control words zenfmt does not " ++
            "recognize. RTF producers vary widely, and the reader is " ++
            "tolerant by design.",
        .consequence = "The unknown instructions were skipped; their text " ++
            "content, if any, was kept.",
        .loss = .degraded,
        .directions = &.{.{
            .title = "Check the output",
            .explanation = "Skim the output for anything missing or " ++
                "misformatted, and keep the source if details matter.",
        }},
    };
}

pub fn imagesDroppedNote() core.Report {
    return .{
        .severity = .warning,
        .code = "rtf.images-dropped",
        .title = "EMBEDDED IMAGES DROPPED",
        .problem = "This document embeds images as hex-encoded `\\pict` " ++
            "data. RTF stores no file names for them, and zenfmt does " ++
            "not extract image bytes.",
        .consequence = "The images do not appear in the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source RTF if the images matter; " ++
                "they exist only there. Run with --strict to stop " ++
                "instead of converting with losses.",
        }},
    };
}

pub fn objectsDroppedNote() core.Report {
    return .{
        .severity = .warning,
        .code = "rtf.objects-dropped",
        .title = "EMBEDDED OBJECTS DROPPED",
        .problem = "This document embeds OLE objects (spreadsheets, " ++
            "drawings, equations) that only their producing " ++
            "applications can render.",
        .consequence = "The objects do not appear in the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source RTF if the objects matter; " ++
                "they exist only there. Run with --strict to stop " ++
                "instead of converting with losses.",
        }},
    };
}

pub fn nestedTableNote() core.Report {
    return .{
        .severity = .note,
        .code = "rtf.nested-table-flattened",
        .title = "NESTED TABLE FLATTENED",
        .problem = "This document nests a table inside a table cell. " ++
            "Markdown tables hold only inline content, so the nested " ++
            "table cannot keep its structure.",
        .consequence = "The nested table's text was folded into its " ++
            "parent cell.",
        .loss = .degraded,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source RTF if the nested layout " ++
                "matters.",
        }},
    };
}
