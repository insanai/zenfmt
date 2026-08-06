#let zds-number = "0007"
#let zds-title = "The PPTX Reader"
#let zds-state = "discussion"
#let zds-created = "2026-08-06"
#let zds-discussion = "Mapping, omissions, and round-trip expectations for the PPTX reader"
#let zds-labels = ("formats", "pptx", "reader",)
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

The format record for `zenfmt_pptx` (`ai.insan.zenfmt.pptx`). A slide deck
is a spatial, animated medium; this projection keeps its readable
content — titles, body text, bullet structure, tables, hyperlinks, image
references, and speaker notes — and drops its geometry. Of every format
zenfmt reads, a presentation loses the most, and the reader says so with
an unconditional warning rather than letting clean-looking output imply
fidelity.

= Mapping

#tbl(
  columns: (auto, 1fr),
  table.header([*Source*], [*Tree result*]),
  [`p:sldIdLst`], [Slides in presentation order, resolved through the
    presentation relationships.],
  [Title placeholders (`type="title"`, `"ctrTitle"`)],
  [`heading`, level 2, one per slide with a title.],
  [Other text bodies], [`paragraph` per `a:p`; empty paragraphs vanish.],
  [`a:pPr` bullets (`lvl`, `buChar`, `buAutoNum`, `buNone`)],
  [Nested `list`/`list_item` structure: an explicit bullet or a level
    above zero enters a list at `lvl + 1`; `buAutoNum` makes the target
    level ordered; `buNone` (and level zero without an explicit bullet)
    stays a paragraph. Level jumps open intervening levels as empty
    items, mirroring the DOCX numbering machine.],
  [`a:tbl` in a `p:graphicFrame`],
  [`table`: `a:tblGrid` counts the columns, `firstRow="1"` on `a:tblPr`
    routes the first row into `table_head`, everything else lands in
    `table_body`. `gridSpan`/`rowSpan` carry through the cell payload;
    `hMerge`/`vMerge` continuation cells fold into their origin with one
    `pptx.merged-cells` note per table.],
  [`a:hlinkClick` in `a:rPr`],
  [`link`, resolved through the slide relationships. Only external
    targets (a URL scheme) become links; a jump to another slide has no
    Markdown counterpart and degrades to plain text.],
  [`a:rPr` with `b="1"`, `i="1"`], [`strong`, `emphasis`; identical
    consecutive runs share one styled span.],
  [`p:pic`], [`image` in its own paragraph: the source is the `a:blip`
    embed target resolved through the slide relationships, the
    description comes from `p:cNvPr` `descr` (falling back to `name`).
    A picture with neither source nor description is skipped.],
  [`a:br`], [`hard_break`.],
  [Speaker notes], [The slide's notes part, appended after the slide as a
    `container` with class `notes`, read with the same machinery and its
    own relationships.],
)

= Deliberate omissions

One report carries the projection's headline:
`pptx.presentation-projection`, a warning emitted for every conversion,
naming what is absent — positioning, animation, transitions, charts,
SmartArt, and embedded media. Individual constructs inside that scope are
not separately counted; the medium itself is the omission.

#tbl(
  columns: (auto, 1fr),
  table.header([*Code*], [*What it covers*]),
  [`pptx.presentation-projection`], [The unconditional geometry warning
    above.],
  [`pptx.merged-cells`], [Merged table cells flattened to their top-left
    origin, one note per affected table.],
)

Bullet inheritance from slide layouts and masters is not resolved: a
paragraph whose bullet exists only in the master's list style converts as
a paragraph unless it carries a level or an explicit bullet of its own.
Resolving the full layout/master inheritance chain is the natural next
amendment here.

= Round-trip expectations

None, emphatically: this is a text extraction. Nothing about a
Markdown-to-PPTX trip is promised or implied, and no preservation
namespace is written.

= Security

The shared archive limits and DTD-free XML parsing apply unchanged.
Slide-relative relationship targets are normalized so `..` segments cannot
address outside the package namespace.

= References

- ZDS 0002, _Reading the Office Formats_.
- ECMA-376 Part 1, PresentationML and DrawingML.
