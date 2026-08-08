#let zds-number = "0005"
#let zds-title = "The XLSX Reader"
#let zds-state = "committed"
#let zds-created = "2026-08-06"
#let zds-discussion = "Mapping, omissions, and round-trip expectations for the XLSX reader"
#let zds-labels = ("formats", "xlsx", "reader",)
#let zds-authors = ("Zen Contributors <team@insan.ai>",)
#let zds-category = "Format Record"
#let zds-status = "Committed"
#let zds-last-updated = "2026-08-08"

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

The format record for `zenfmt_xlsx` (`ai.insan.zenfmt.xlsx`). A workbook is
a set of grids; the projection is direct: each sheet becomes a level-two
heading naming it, followed by one table with the sheet's first row as its
header. The interesting decisions are about numbers, because a spreadsheet's
raw storage lies to humans: serial dates and percentage fractions are
formatted, everything else passes through verbatim.

= Mapping

Every non-empty cell also carries a `GridFacet` (ZDS 0013): sheet name,
zero-based row and column, value type, the formula source when present, and
the cached value exactly as the source spelled it. Markdown ignores the
facet; a future spreadsheet writer re-emits the formula from it.

#tbl(
  columns: (auto, 1fr, 1fr),
  table.header([*Source*], [*Tree result*], [*Facets*]),
  [`xl/workbook.xml` sheet list], [One `heading` (level 2) per sheet, in
    workbook order, resolved through the workbook relationships.],
  [none.],
  [Sheet rows and cells], [One `table` per sheet; the first row is
    `table_head`, the rest `table_body`. Sparse rows are materialized:
    skipped cells become empty cells, and short rows pad to the sheet's
    widest row.],
  [`GridFacet` per non-empty cell; padding cells carry none.],
  [`t="s"` cells], [The shared string from `xl/sharedStrings.xml`.],
  [`GridFacet` with value type `text`.],
  [`t="inlineStr"`, `t="str"` cells], [Their text.],
  [`GridFacet` with value type `text`.],
  [`t="b"` cells], [`TRUE` or `FALSE`.],
  [`GridFacet` with value type `boolean`; `t="e"` cells carry
    `error_value`.],
  [Number cells with a date format],
  [ISO `yyyy-mm-dd`, from the serial through Hinnant's civil-from-days.
    Built-in format ids 14–22 and 45–47 count as dates; serials below 60
    inherit Excel's fictional 1900-02-29 and land one day early, which
    real spreadsheets never exercise.],
  [`GridFacet` with value type `date`; the cached field keeps the raw
    serial.],
  [Number cells with a percentage format], [The fraction times one
    hundred with a `%` sign; ids 9 and 10.],
  [`GridFacet` with value type `number` and the raw fraction cached.],
  [Other number cells], [The raw value, verbatim.],
  [`GridFacet` with value type `number`.],
  [`<f>` formulas], [Never evaluated; the cached `<v>` is used.
    `xlsx.formula-without-cached-value` when there is none.],
  [`GridFacet.formula` carries the formula source text verbatim.],
)

= Deliberate omissions

#tbl(
  columns: (auto, 1fr),
  table.header([*What*], [*Why*]),
  [Cell styling, colors, borders, widths], [A GFM table has none of it.],
  [Charts, images, pivot tables, defined names], [No tree node exists,
    and inventing one is a ZDS 0002 amendment, not a reader's decision.],
  [Custom number formats beyond dates and percentages],
  [Format-string interpretation is a rendering engine; the raw value is
    honest, a wrong rendering is not.],
  [Hidden rows, columns, and sheets], [Hiding is presentation; the data
    is the content. Everything converts.],
)

= Round-trip expectations

None: XLSX is read-only and no preservation namespace is written. A
spreadsheet round trip would need cell-level typing that Markdown cannot
carry; the honest form of that feature is a CSV writer, not a promise here.

= Security

The shared `zenfmt_ooxml` archive limits and the DTD-free XML parser apply
unchanged. Sheet materialization is bounded: cells beyond the widest
declared reference cap at 1,024 columns per row, so a hostile dimension
string cannot inflate output quadratically.

= References

- ZDS 0002, _Reading the Office Formats_.
- ECMA-376 Part 1, SpreadsheetML.
