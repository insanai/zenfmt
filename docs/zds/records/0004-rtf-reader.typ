#let zds-number = "0004"
#let zds-title = "The RTF Reader"
#let zds-state = "discussion"
#let zds-created = "2026-08-06"
#let zds-discussion = "Mapping, omissions, and round-trip expectations for the RTF reader"
#let zds-labels = ("formats", "rtf", "reader",)
#let zds-authors = ("Zen Contributors <team@insan.ai>",)
#let zds-category = "Format Record"
#let zds-status = "Open for Discussion"
#let zds-last-updated = "2026-08-06"

#import "../../shared/zds.typ": zds-document

#show: doc => zds-document(
  zds-number,
  zds-title,
  doc,
  authors: zds-authors,
  state: zds-state,
  created: zds-created,
  discussion: zds-discussion,
  labels: zds-labels,
  category: zds-category,
  status: zds-status,
  last-updated: zds-last-updated,
)

#let tbl(..args) = table(
  stroke: 0.5pt + rgb("d7dee8"),
  inset: 6pt,
  ..args,
)

= Abstract

The format record for `zenfmt_rtf` (`ai.insan.zenfmt.rtf`). RTF is neither
XML nor a container: one brace-delimited group language, read by one
explicit group stack. RTF in the wild comes from dozens of producers with
incompatible habits, so this reader is error-tolerant by design — an
unknown control word is skipped with a note, never a failure.

= Mapping

#tbl(
  columns: (auto, 1fr),
  table.header([*Source*], [*Tree result*]),
  [Document text], [`paragraph` runs, closed by `\par`.],
  [`\b`, `\i`, `\strike`, `\super`, `\sub`, `\scaps`, `\ul`/`\ulnone`],
  [Nested style containers in the canonical order, inherited into nested
    groups, cleared by `\plain`, with the common prefix of consecutive
    text shared. Toggle values of zero clear.],
  [`\line`], [`hard_break`.],
  [`\tab`, `\~`], [A space.],
  [`\'hh`], [The byte decoded in the `\ansicpg` code page; Windows-1252
    is the default and the fallback for pages zenfmt does not carry.],
  [`\uN`], [The Unicode scalar, with the `\uc` skip-count convention for
    the fallback characters that follow.],
  [`\emdash`, `\endash`, quotes, `\bullet`], [Their Unicode characters.],
  [`{\*\...}` and known destinations],
  [Skipped wholesale: `fonttbl`, `colortbl`, `stylesheet`, `info`,
    headers and footers, list tables, revision tables.],
  [`\trowd` / `\cellx` / `\cell` / `\row`],
  [`table` with one column per `\cellx` of the first row definition;
    `\trhdr` rows open `table_head`, the rest `table_body`. Cells open
    lazily when their content arrives and close at `\cell`. A paragraph
    without `\intbl` closes the table.],
  [`\ls` + `\ilvl`, `{\*\pn}`],
  [`list`/`list_item` synthesized by the same inference machine as the
    DOCX reader: open on rising level, close on falling level or a
    changed kind. `\pnlvlblt` is a bullet, `\pndec`/`\pnlvlbody`
    ordered; a bare `\ls` decides by its `\listtext` marker — a digit
    means ordered. Marker fallback text never reaches the output.],
  [`\outlinelevelN`], [`heading` at level N+1 (clamped to six), the
    producing word processor's own outline signal.],
  [`{\field{\*\fldinst HYPERLINK ...}{\fldrslt ...}}`],
  [`link` around the field result, with the quoted or bare URL from the
    instruction. Non-hyperlink fields keep their cached result as plain
    text.],
  [`{\footnote ...}`],
  [`note` reference at the site; the group's raw RTF is replayed after
    the body as the note's block content.],
)

= Deliberate omissions

#tbl(
  columns: (auto, 1fr),
  table.header([*Report code*], [*What is recognized and dropped*]),
  [`rtf.unknown-control-words`],
  [Every control word outside the mapping: layout (`\qc`, `\li`, `\sa`),
    fonts and colors (`\f`, `\fs`, `\cf`), sections, and anything a
    producer invented. Skipped, text kept, said once.],
  [`rtf.images-dropped`],
  [`\pict` groups. RTF embeds image bytes hex-encoded with no file name;
    zenfmt does not extract image bytes in this release.],
  [`rtf.objects-dropped`],
  [`\object` OLE embeddings — spreadsheets, drawings, equations only
    their producing applications can render.],
  [`rtf.nested-table-flattened`],
  [Tables inside table cells (`\itap` above one, `\nestcell`). Markdown
    cells hold only inline content; the nested table's text folds into
    its parent cell.],
)

= Round-trip expectations

None. RTF is read-only, its projection keeps character styling and
paragraph breaks, and no preservation namespace is written in this release.

= Security

The group stack is fixed at 128 deep; deeper nesting is
`rtf.groups-too-deep`, a limit-class refusal — no real producer nests near
that. A file not beginning `{\rtf` is `rtf.not-rtf`. All content-following
refusals from ZDS 0002 apply: nothing in an RTF file causes zenfmt to open
another file.

= References

- ZDS 0002, _Reading the Office Formats_.
- Microsoft Rich Text Format Specification v1.9.1.
