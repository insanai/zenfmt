#let zds-number = "0006"
#let zds-title = "The ODT Reader"
#let zds-state = "discussion"
#let zds-created = "2026-08-06"
#let zds-discussion = "Mapping, omissions, and round-trip expectations for the ODT reader"
#let zds-labels = ("formats", "odt", "reader",)
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

The format record for `zenfmt_odt` (`ai.insan.zenfmt.odt`). OpenDocument
Text shares the container machinery with the OOXML family and is friendlier
in structure: headings carry their level, lists nest explicitly. The hard
part is exactly where ZDS 0002 predicted — character styling is indirect,
through named styles resolved along `style:parent-style-name` chains.

= Mapping

#tbl(
  columns: (auto, 1fr, 1fr),
  table.header([*Source*], [*Tree result*], [*Facets*]),
  [`text:h`], [`heading`, level from `text:outline-level`, clamped to six.],
  [`StyleFacet` when the style resolves to a common name from
    `styles.xml`.],
  [`text:p`], [`paragraph`; `plain` inside list items.],
  [`StyleFacet` when the style resolves to a common name: an automatic
    `P1`-style name follows its parent chain and the facet carries the
    name a person chose, never a generator's counter.],
  [`text:span`],
  [Style containers from the resolved style: `fo:font-weight` bold,
    `fo:font-style` italic, `style:text-underline-style`,
    `style:text-line-through-style`, `style:text-position` super and sub,
    `fo:font-variant` small caps. Automatic styles in `content.xml` win
    over `styles.xml`; parent chains flatten with a sixteen-hop bound.
    Containers open in the canonical order and merge across spans.],
  [none.],
  [Paragraph styles], [Contribute the same character properties to the
    whole paragraph.],
  [none.],
  [`text:a`], [`link`, target from `xlink:href`.],
  [none.],
  [`text:list`, `text:list-item`],
  [`list` and `list_item`, nesting structurally. Ordered when the list's
    style names a `text:list-level-style-number` at its first level;
    bullet otherwise or when the style is unknown.],
  [none.],
  [`text:s`, `text:tab`], [A space.],
  [none.],
  [`text:line-break`], [`hard_break`.],
  [none.],
  [`text:note`],
  [`note`. The body's byte range is captured during the walk and
    re-parsed after the document body, where note bodies belong.],
  [none.],
  [`table:table` family], [`table`; `table:table-header-rows` rows in
    `table_head`; `table:number-columns-spanned` becomes `col_span`;
    covered cells are skipped.],
  [none.],
  [`text:section`], [`container` with class `section`.],
  [none.],
  [`draw:frame` with `draw:image`],
  [`image`: the source from `xlink:href` (typically `Pictures/…` inside
    the package), the description from `svg:desc`, then `svg:title`,
    then the frame's `draw:name`. Inline frames sit in their paragraph;
    anchored frames outside one get a wrapping paragraph. Embedded
    `office:binary-data` is never spilled into text. A frame inside a
    frame (an image within a text box) flows as regular content.],
  [Internal package parts register with the resource store under the
    `xlink:href` source name, digested at registration; extraction past
    the limits degrades to `odt.media-limit`. External references stay
    references.],
  [`office:annotation`],
  [Dropped from the flow and counted, as before.],
  [`RevisionFacet` on the containing paragraph, or the next one when the
    comment sits between paragraphs: kind `comment`, `dc:creator`,
    `dc:date`, and the first 256 bytes of the comment text.],
)

= Deliberate omissions

#tbl(
  columns: (auto, 1fr),
  table.header([*Report code or fate*], [*What*]),
  [`odt.annotations-dropped`], [`office:annotation` comment threads.],
  [Skipped silently], [Font declarations, settings, scripts, master
    styles, tracked-change tables, form controls: file plumbing with no
    content of their own.],
  [`odt.frame-dropped`], [A `draw:frame` with neither an image source
    nor any description — decorative shapes, mostly.],
  [Not yet mapped], [Change marks in running text and bookmarks: their
    containing text survives; the markers do not. Recorded here as
    decisions, each a candidate amendment.],
)

= Round-trip expectations

ODT is read-only and writes no preservation namespace. Common style names,
comment threads, and image bytes now travel typed through the facet tables
and the resource store (ZDS 0013); the manifest summarizes them per kind,
with full rows under `--preserve-facets`. A future ODT writer may consult
them; nothing may require them.

= Security

The shared archive limits apply; `content.xml` is mandatory
(`odt.missing-content`), malformed or too-deep XML refuses with
`odt.malformed-xml`, and note-body re-parsing wraps captured fragments in
a namespace-rebinding element so no fragment escapes the parser's rules.

= References

- ZDS 0002, _Reading the Office Formats_.
- OASIS Open Document Format for Office Applications v1.3.
