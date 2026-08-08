//! The Markdown writer's diagnostic catalog (ZDS 0002, Diagnostics):
//! every degradation and drop the writer can report.

const core = @import("zenfmt_core");

pub fn styleDroppedNote(style: []const u8) core.Report {
    _ = style;
    return .{
        .severity = .note,
        .code = "markdown.style-dropped",
        .title = "STYLE DROPPED",
        .problem = "This document uses underline, small caps, superscript, " ++
            "or subscript styling, which CommonMark cannot spell.",
        .consequence = "The styled text was kept; the styling was dropped.",
        .loss = .presentation,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source document if the exact styling " ++
                "matters; the text itself is intact in the output.",
        }},
    };
}

/// The rule-table spelling of `styleDroppedNote`: the note ignores which
/// style fired, so the capability rule needs no argument.
pub fn styleDroppedRuleNote() core.Report {
    return styleDroppedNote("");
}

pub fn containerAttrsNote() core.Report {
    return .{
        .severity = .note,
        .code = "markdown.container-attributes-dropped",
        .title = "CONTAINER ATTRIBUTES DROPPED",
        .problem = "A container in this document carries an " ++
            "identifier, classes, or attributes, and Markdown has no " ++
            "plain syntax for an attributed container.",
        .consequence = "The container's content was kept; its " ++
            "attributes were dropped.",
        .loss = .presentation,
        .directions = &.{.{
            .title = "Choose which representation is authoritative",
            .explanation = "Keep the source and its adjacent manifest if " ++
                "the container roles matter. If Markdown is authoritative, " ++
                "remove the id, classes, and attributes before converting.",
        }},
    };
}

pub fn definitionListNote() core.Report {
    return .{
        .severity = .note,
        .code = "markdown.definition-list-degraded",
        .title = "DEFINITION LIST DEGRADED",
        .problem = "This document contains a definition list, and GFM " ++
            "has no definition-list syntax.",
        .consequence = "Each term was emitted as a bold paragraph and " ++
            "each definition as ordinary paragraphs below it.",
        .loss = .structural,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source document if the exact " ++
                "definition-list structure matters downstream.",
        }},
    };
}

pub fn extensionFallbackNote() core.Report {
    return .{
        .severity = .note,
        .code = "markdown.extension-fallback",
        .title = "EXTENSION LOWERED TO FALLBACK",
        .problem = "This document carries a namespaced plugin extension " ++
            "construct that the Markdown writer does not understand.",
        .consequence = "The extension's source-neutral fallback content " ++
            "was written; the extension identity and any behavior it " ++
            "implied were dropped.",
        .loss = .structural,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source document, or convert with a " ++
                "writer that declares this extension namespace, if the " ++
                "construct itself matters downstream.",
        }},
    };
}

pub fn citationDroppedNote() core.Report {
    return .{
        .severity = .note,
        .code = "markdown.citation-dropped",
        .title = "CITATION DROPPED",
        .problem = "This document contains a structured citation, and GFM " ++
            "has no citation syntax.",
        .consequence = "The citation's visible text was kept; the " ++
            "structured reference data was dropped.",
        .loss = .presentation,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source document if the citation data " ++
                "matters for downstream processing.",
        }},
    };
}

pub fn rawDroppedNote() core.Report {
    return .{
        .severity = .note,
        .code = "markdown.raw-dropped",
        .title = "RAW CONTENT DROPPED",
        .problem = "This document embeds raw content in a format that is " ++
            "neither Markdown nor HTML.",
        .consequence = "The raw fragment was dropped; emitting it " ++
            "verbatim would corrupt the output.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source document; the fragment exists " ++
                "only there.",
        }},
    };
}

pub fn cellFlattenedNote() core.Report {
    return .{
        .severity = .note,
        .code = "markdown.table-cell-flattened",
        .title = "TABLE CELL FLATTENED",
        .problem = "A table cell holds more than one block, or a block " ++
            "that is not a paragraph, and a GFM pipe-table cell is a " ++
            "single line of inline text.",
        .consequence = "The cell's content was flattened onto one line.",
        .loss = .structural,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source document if the cell's block " ++
                "structure matters.",
        }},
    };
}

pub fn tableCaptionNote() core.Report {
    return .{
        .severity = .note,
        .code = "markdown.table-caption-degraded",
        .title = "TABLE CAPTION MOVED INTO FLOW",
        .problem = "This table has a caption, and a GFM pipe table has no " ++
            "syntax that associates caption blocks with the table.",
        .consequence = "The caption content was flattened onto one line " ++
            "after the table; its association and block structure were dropped.",
        .loss = .structural,
        .directions = &.{.{
            .title = "Choose a format with table captions",
            .explanation = "Keep the source, or select a target writer that " ++
                "declares table-caption support, if the association matters.",
        }},
    };
}

pub fn nestedTableWarning() core.Report {
    return .{
        .severity = .warning,
        .code = "markdown.nested-table-dropped",
        .title = "NESTED TABLE DROPPED",
        .problem = "A table cell contains another table, and a GFM pipe " ++
            "table cannot nest.",
        .consequence = "The inner table was replaced with the placeholder " ++
            "`(nested table)`.",
        .loss = .dropped,
        .directions = &.{.{
            .title = "Restructure or keep the source",
            .explanation = "Restructure the source so tables do not nest, " ++
                "or keep the source document; the inner table's content " ++
                "exists only there.",
        }},
    };
}

pub fn spanNote() core.Report {
    return .{
        .severity = .note,
        .code = "markdown.cell-span-degraded",
        .title = "CELL SPAN DEGRADED",
        .problem = "This table merges cells across rows or columns, and a " ++
            "GFM pipe table has no merged cells.",
        .consequence = "Merged content was placed in the first cell of " ++
            "its span and the remaining positions were left empty.",
        .loss = .structural,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source document if the merged-cell " ++
                "layout matters.",
        }},
    };
}

pub fn numberStyleNote() core.Report {
    return .{
        .severity = .note,
        .code = "markdown.list-number-style-degraded",
        .title = "LIST NUMBER STYLE DEGRADED",
        .problem = "This document numbers a list with letters or Roman " ++
            "numerals, and Markdown ordered lists use decimal numbers.",
        .consequence = "The list was renumbered decimally from its " ++
            "recorded start.",
        .loss = .presentation,
        .directions = &.{.{
            .title = "Keep the source",
            .explanation = "Keep the source document if the numbering " ++
                "style matters.",
        }},
    };
}
