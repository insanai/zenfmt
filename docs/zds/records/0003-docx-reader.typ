#let zds-number = "0003"
#let zds-title = "The DOCX Reader"
#let zds-state = "discussion"
#let zds-created = "2026-08-06"
#let zds-discussion = "Mapping, omissions, and round-trip expectations for the DOCX reader"
#let zds-labels = ("formats", "docx", "reader",)
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

The format record for `zenfmt_docx` (`ai.insan.zenfmt.docx`), the
WordprocessingML reader delivered in phase 4 of ZDS 0002. That record carries
the architectural mapping table; this one is the plugin's own ledger — the
obligations ZDS 0001 places on every format record: the mapping as
implemented, the deliberate omissions with their reasons, and what a round
trip may and may not expect.

= Scope

The reader consumes `.docx` packages through the shared `zenfmt_ooxml` ZIP
layer and `zenfmt_xml` pull parser, under every limit in ZDS 0002's archive
table. The main part is resolved through the package relationships, never
guessed. `styles.xml`, `numbering.xml`, `word/_rels/document.xml.rels`, and
`word/footnotes.xml` are read when present; a document missing any optional
part still converts.

= Mapping

As implemented; the rationale is in ZDS 0002, _Reading the Office Formats_.

#tbl(
  columns: (auto, 1fr, 1fr),
  table.header([*Source*], [*Tree result*], [*Facets*]),
  [`w:p`], [`paragraph`; `plain` inside synthesized list items.],
  [`StyleFacet` when a non-heading `w:pStyle` names it: the style id.],
  [`w:p` with heading `w:pStyle`],
  [`heading`. Built-in `Heading1`..`Heading9` and any style whose
    `w:basedOn` chain reaches one; levels above six clamp with
    `docx.heading-level-clamped`.],
  [none.],
  [`w:p` with `w:numPr`],
  [`list_item` in a synthesized list: the inference machine from ZDS 0002,
    with ordered-versus-bullet and start from `numbering.xml`, bullets when
    the pointer dangles.],
  [none.],
  [`w:r` with `w:rPr` flags],
  [Nested `strong`, `emphasis`, `strikethrough`, `superscript`,
    `subscript`, `small_caps`, `underline` in the canonical order; the
    common prefix of consecutive runs is shared. Toggles with
    `w:val="0"`/`"false"`/`"none"` clear.],
  [none.],
  [`w:rFonts` naming a monospace family], [`code`, degraded: a font became a role.],
  [none.],
  [`w:t`, `w:delText`], [Text; only `w:t` content is significant, never
    inter-element whitespace.],
  [none.],
  [`w:br`], [`hard_break`; `w:type="page"` counts toward
    `docx.page-breaks-dropped`.],
  [none.],
  [`w:tab`], [A space.],
  [none.],
  [`w:hyperlink`], [`link`, target through the relationships or `#anchor`.],
  [none.],
  [`HYPERLINK` fields], [`link` around the cached result runs; other
    fields keep their cached result and drop the instruction.],
  [none.],
  [`w:tbl` / `w:tr` / `w:tc`],
  [`table` with columns from `w:tblGrid`; leading `w:tblHeader` rows in
    `table_head`; `w:gridSpan` becomes `col_span`; `w:vMerge`
    continuations fold into the origin with
    `docx.merged-cells-degraded`.],
  [none.],
  [`w:drawing`, `w:pict`],
  [`image` with the relationship target as source and `descr` as alt
    text; sourceless, descriptionless shapes emit nothing.],
  [The image part's bytes register with the resource store under the same
    source name, digested at registration; extraction past the limits
    degrades to `docx.media-limit`.],
  [`w:footnoteReference`], [`note`; the body parses from
    `word/footnotes.xml` after the document body.],
  [none.],
  [`w:sdt`], [`container` (block) or `span` (inline) with the control's
    tag as its class.],
  [none.],
  [`w:ins`, `w:moveTo`], [Content kept: insertions accepted.],
  [`RevisionFacet` on the containing paragraph: kind `insertion`, the
    `w:author` and `w:date` attributes. An insertion wrapping whole
    paragraphs binds to the first paragraph it opens.],
  [`w:del`, `w:moveFrom`], [Content dropped and counted, as before.],
  [`RevisionFacet` on the containing paragraph: kind `deletion` with
    author and date, so the fact of the deletion survives the drop.],
  [`w:sectPr` with `w:pgSz`], [Counted toward
    `docx.section-properties-dropped`, as before.],
  [One page `LayoutFacet` on the first body block: width and height in
    EMU, converted from twips at 635 EMU per twip.],
)

= Deliberate omissions

Recognized and dropped, each with the named report; the counts aggregate.

#tbl(
  columns: (auto, 1fr),
  table.header([*Report code*], [*What is recognized and dropped*]),
  [`docx.comments-dropped`], [Comments and comment ranges.],
  [`docx.tracked-deletions-dropped`], [`w:del` and `w:moveFrom` content.],
  [`docx.page-breaks-dropped`], [Explicit page breaks.],
  [`docx.bookmarks-dropped`], [Bookmarks and cross-reference anchors.],
  [`docx.section-properties-dropped`], [Page size, margins, columns.],
  [`docx.text-boxes-dropped`], [Text boxes and shapes with text.],
  [`docx.embedded-objects-dropped`], [OLE objects: charts, spreadsheets.],
  [`docx.unhandled-construct`],
  [Any other WordprocessingML element: children processed, construct
    reported — the runtime twin of this table.],
)

Deferred rather than dropped: OMML mathematics (the `math` node exists; the
mapping does not yet). Image byte extraction, deferred in the first draft of
this record, now lands in the resource store as the mapping table shows.

= Round-trip expectations

DOCX to Markdown is a one-way projection in the first release. What survives
a later DOCX → Markdown → DOCX trip is bounded by Markdown's vocabulary plus
the preservation namespace: the reader records the distinct non-heading
paragraph style ids it saw under `ai.insan.zenfmt.docx` (version 1,
`paragraph_style_ids`) in the artifact manifest, digest-bound to the output.
A future DOCX writer may consult it; nothing may require it. The facet rows
in the mapping table widen that channel (ZDS 0013): style names, tracked
changes, and page geometry now travel typed in the shared IR, and the
manifest summarizes them per kind, with full rows under `--preserve-facets`.

= Security

Everything from ZDS 0002 applies: central-directory-only ZIP reading, the
no-override name rules, refusal of encrypted entries and unknown
compression, no DTD processing (`docx.doctype-refused`), and the XML depth
limit (`docx.xml-too-deep`). The adversarial corpus in `tests/docx.zig`
asserts each refusal by report code.

= References

- ZDS 0002, _Reading the Office Formats_ — the architectural mapping this
  record instantiates.
- ECMA-376 Part 1 (WordprocessingML), Part 2 (Open Packaging Conventions).
