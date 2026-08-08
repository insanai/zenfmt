//! The PPTX diagnostic catalog (ZDS 0002: every deliberate omission and
//! refusal has a stable code, and the codes appear in tests).

const core = @import("zenfmt_core");

pub fn archiveReport() core.Report {
    return .{
        .severity = .err,
        .code = "pptx.not-an-archive",
        .title = "NOT A READABLE PPTX ARCHIVE",
        .problem = "This file is not a ZIP archive zenfmt can read, or it " ++
            "trips an archive safety limit.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Check the file",
            .explanation = "Open the file in PowerPoint or LibreOffice to " ++
                "verify it is intact, and check the detected format.",
        }},
    };
}

pub fn notPresentationReport() core.Report {
    return .{
        .severity = .err,
        .code = "pptx.missing-presentation",
        .title = "THE PRESENTATION PART IS MISSING",
        .problem = "The archive opens but does not contain a readable " ++
            "ppt/presentation.xml, so it is not a presentation.",
        .consequence = "The conversion stopped and no output file was " ++
            "created.",
        .directions = &.{.{
            .title = "Re-export the file",
            .explanation = "Re-save the presentation from its native " ++
                "application and convert the fresh copy.",
        }},
    };
}

pub fn projectionNote() core.Report {
    return .{
        .severity = .warning,
        .code = "pptx.presentation-projection",
        .title = "A PRESENTATION LOSES ITS GEOMETRY",
        .problem = "A slide deck is a spatial, animated medium. This " ++
            "projection keeps the readable content: titles, body text, " ++
            "lists, tables, hyperlinks, image references, and speaker " ++
            "notes.",
        .consequence = "Positioning, animation, transitions, charts, " ++
            "SmartArt, and embedded media are absent from the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source PPTX; the visual design " ++
                "exists only there. Run with --strict to stop instead of " ++
                "converting with these losses.",
        }},
    };
}

pub fn mediaLimitNote() core.Report {
    return .{
        .severity = .note,
        .code = "pptx.media-limit",
        .title = "MEDIA EXTRACTION STOPPED AT THE LIMIT",
        .problem = "This deck embeds more picture data than the media " ++
            "limits allow to be extracted.",
        .consequence = "Pictures past the limit keep their archive path " ++
            "references; their bytes were not extracted.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Raise the limit",
            .explanation = "Raise --limit max_resources or " ++
                "--limit max_resource_bytes if the remaining pictures " ++
                "matter.",
        }},
    };
}

pub fn mergedCellNote() core.Report {
    return .{
        .severity = .note,
        .code = "pptx.merged-cells",
        .title = "MERGED TABLE CELLS FLATTENED",
        .problem = "A table on a slide merges cells across rows or " ++
            "columns, and Markdown tables have no merged cells.",
        .consequence = "Each merged region keeps its content in the " ++
            "top-left cell; the covered cells are absent from the output.",
        .loss = .structural,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source presentation if the " ++
                "merged-cell layout matters.",
        }},
    };
}
