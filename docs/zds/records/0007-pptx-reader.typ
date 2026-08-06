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
is a spatial, animated medium; this projection keeps only its words. Of
every format zenfmt reads, a presentation loses the most, and the reader
says so with an unconditional warning rather than letting clean-looking
output imply fidelity.

= Mapping

#tbl(
  columns: (auto, 1fr),
  table.header([*Source*], [*Tree result*]),
  [`p:sldIdLst`], [Slides in presentation order, resolved through the
    presentation relationships.],
  [Title placeholders (`type="title"`, `"ctrTitle"`)],
  [`heading`, level 2, one per slide with a title.],
  [Other text bodies], [`paragraph` per `a:p`.],
  [`a:rPr` with `b="1"`, `i="1"`], [`strong`, `emphasis`.],
  [`a:br`], [`hard_break`.],
  [Speaker notes], [The slide's notes part, appended after the slide as a
    `container` with class `notes`.],
)

= Deliberate omissions

One report carries the projection's headline:
`pptx.presentation-projection`, a warning emitted for every conversion,
naming what is absent — positioning, animation, transitions, images,
charts, tables, and non-text shapes. Individual constructs inside that
scope are not separately counted; the medium itself is the omission.

Not yet mapped rather than dropped: slide tables (`a:tbl`) and hyperlinks
in runs, both candidates for amendment here.

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
