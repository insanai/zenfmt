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
  columns: (auto, 1fr),
  table.header([*Source*], [*Tree result*]),
  [`text:h`], [`heading`, level from `text:outline-level`, clamped to six.],
  [`text:p`], [`paragraph`; `plain` inside list items.],
  [`text:span`],
  [Style containers from the resolved style: `fo:font-weight` bold,
    `fo:font-style` italic, `style:text-underline-style`,
    `style:text-line-through-style`, `style:text-position` super and sub,
    `fo:font-variant` small caps. Automatic styles in `content.xml` win
    over `styles.xml`; parent chains flatten with a sixteen-hop bound.
    Containers open in the canonical order and merge across spans.],
  [Paragraph styles], [Contribute the same character properties to the
    whole paragraph.],
  [`text:a`], [`link`, target from `xlink:href`.],
  [`text:list`, `text:list-item`],
  [`list` and `list_item`, nesting structurally. Ordered when the list's
    style names a `text:list-level-style-number` at its first level;
    bullet otherwise or when the style is unknown.],
  [`text:s`, `text:tab`], [A space.],
  [`text:line-break`], [`hard_break`.],
  [`text:note`],
  [`note`. The body's byte range is captured during the walk and
    re-parsed after the document body, where note bodies belong.],
  [`table:table` family], [`table`; `table:table-header-rows` rows in
    `table_head`; `table:number-columns-spanned` becomes `col_span`;
    covered cells are skipped.],
)

= Deliberate omissions

#tbl(
  columns: (auto, 1fr),
  table.header([*Report code or fate*], [*What*]),
  [`odt.annotations-dropped`], [`office:annotation` comment threads.],
  [Skipped silently], [Font declarations, settings, scripts, master
    styles, tracked-change tables, form controls: file plumbing with no
    content of their own.],
  [Not yet mapped], [Images and frames (`draw:` namespace), change
    marks in running text, and bookmarks: their containing text
    survives; the constructs do not. Recorded here as decisions, each a
    candidate amendment.],
)

= Round-trip expectations

None in this release: ODT is read-only and writes no preservation
namespace. Style names are not carried; unlike DOCX there is not yet a
demonstrated consumer for them.

= Security

The shared archive limits apply; `content.xml` is mandatory
(`odt.missing-content`), malformed or too-deep XML refuses with
`odt.malformed-xml`, and note-body re-parsing wraps captured fragments in
a namespace-rebinding element so no fragment escapes the parser's rules.

= References

- ZDS 0002, _Reading the Office Formats_.
- OASIS Open Document Format for Office Applications v1.3.
