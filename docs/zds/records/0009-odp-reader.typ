#let zds-number = "0009"
#let zds-title = "The ODP Reader"
#let zds-state = "discussion"
#let zds-created = "2026-08-06"
#let zds-discussion = "Mapping, omissions, and round-trip expectations for the ODP reader"
#let zds-labels = ("formats", "odp", "reader",)
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

The format record for `zenfmt_odp` (`ai.insan.zenfmt.odp`). An OpenDocument
presentation projects exactly like PPTX: each `draw:page` becomes a
level-two heading followed by the text of its frames, and speaker notes
append as a `container` classed `notes`. As with PPTX, the reader says
loudly — `odp.presentation-projection`, a warning on every conversion —
that a slide deck loses the most in this projection.

= Mapping

#tbl(
  columns: (auto, 1fr),
  table.header([*Source*], [*Tree result*]),
  [`draw:page`], [One slide in document order.],
  [Frame classed `title` (`presentation:class`)], [Its first paragraph is
    the slide's `heading` (level 2). Slides without a title frame fall
    back to the page's `draw:name`; empty slides still contribute their
    heading.],
  [Other frames' `text:p`], [Paragraphs, in frame order.],
  [`text:span`], [Character styles resolved through
    `office:automatic-styles` and `styles.xml` with
    `style:parent-style-name` chains (16 hops), exactly the ODT rules:
    bold weight → `strong`, italic → `emphasis`, and the rest of the
    canonical nesting order.],
  [`text:a`], [`link` with the `xlink:href` target.],
  [`text:list`], [`list`; ordered when the list style's first level is
    `text:list-level-style-number`, as in ODT.],
  [`table:table` inside a frame], [A `table`, streamed as in the ODT
    reader. Every row lands in `table_body` — presentations have no
    header semantics — unless the deck declares
    `table:table-header-rows`, which maps to `table_head`.
    `table:covered-table-cell` folds into its originating cell and
    `table:number-columns-spanned` carries as the cell's column span.],
  [`presentation:notes`], [A `container` with class `notes` appended
    after the slide's frames.],
  [`office:annotation`], [Dropped with `odp.annotations-dropped`.],
)

= Deliberate omissions

#tbl(
  columns: (auto, 1fr),
  table.header([*What*], [*Why*]),
  [Positioning, sizes, z-order, rotation], [A linear document has no
    spatial layout; this is the projection the warning names.],
  [Animations, transitions, timings], [Behavior, not content.],
  [Images, charts, media, non-text shapes], [Dropped; the projection
    warning covers them. Carrying images is future work shared with the
    PPTX reader.],
  [Master pages and layout inheritance], [Slide masters carry design,
    not content; placeholder text is never document text.],
  [Presenter console settings, `presentation:settings`], [Tooling state.],
)

= Round-trip expectations

None: ODP is read-only and no preservation namespace is written. The
projection is deliberately lossy and the loss is announced on every
conversion; a Markdown-to-slides authoring path is a different feature
with its own record.

= Security

The shared `zenfmt_ooxml` archive limits and the DTD-free XML parser apply
unchanged. The frame machine is the same bounded, non-recursive design as
the ODT reader: a 256-frame stack and `skipElement` for subtrees the
mapping drops.

= References

- ZDS 0002, _Reading the Office Formats_.
- ZDS 0006, _The ODT Reader_ (style resolution shared with this reader).
- ZDS 0007, _The PPTX Reader_ (the projection conventions).
- OASIS OpenDocument v1.3 Part 3, `draw:*` and `presentation:*`.
