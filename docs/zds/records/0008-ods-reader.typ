#let zds-number = "0008"
#let zds-title = "The ODS Reader"
#let zds-state = "committed"
#let zds-created = "2026-08-06"
#let zds-discussion = "Mapping, omissions, and round-trip expectations for the ODS reader"
#let zds-labels = ("formats", "ods", "reader",)
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

The format record for `zenfmt_ods` (`ai.insan.zenfmt.ods`). An OpenDocument
spreadsheet projects exactly like an XLSX workbook: each `table:table`
becomes a level-two heading naming the sheet, followed by one table whose
first row is the header. The pleasant difference from XLSX is that ODS cell
values are typed in place — a date is already ISO 8601 text in
`office:date-value` — so no serial-date arithmetic exists in this reader.
The dangerous difference is repetition: `table:number-columns-repeated`
can claim a run to column 16,384 in one attribute, so materialization is
capped, not trusted.

= Mapping

Every non-empty cell also carries a `GridFacet` (ZDS 0013): sheet name,
zero-based row and column, value type, the formula source when present, the
typed value as the source spelled it, and merge extents from the spanned
attributes.

#tbl(
  columns: (auto, 1fr, 1fr),
  table.header([*Source*], [*Tree result*], [*Facets*]),
  [`table:table`], [One `heading` (level 2) from `table:name`, then one
    `table`; the first row is `table_head`, the rest `table_body`. Sheets
    with no non-empty cells are skipped entirely.],
  [`GridFacet` per non-empty cell, naming the sheet.],
  [`office:value-type="float"`], [The `office:value` attribute, verbatim.],
  [Value type `number`; `office:value` cached.],
  [`office:value-type="percentage"`], [The fraction times one hundred
    with a `%` sign.],
  [Value type `number`; the raw fraction cached.],
  [`office:value-type="date"`], [`office:date-value` truncated at `T`:
    the ISO date, no arithmetic.],
  [Value type `date`; `office:date-value` cached in full.],
  [`office:value-type="time"`], [`office:time-value` (`PT13H30M5S`)
    reformatted as `13:30:05`; unparseable durations fall back to the
    displayed text.],
  [Value type `date`; the raw duration cached.],
  [`office:value-type="boolean"`], [`TRUE` or `FALSE` from
    `office:boolean-value`.],
  [Value type `boolean`; `office:boolean-value` cached.],
  [String and currency cells], [The displayed `text:p` content,
    paragraphs joined with a space.],
  [Value type `text` (`number` for currency); the display text cached.],
  [`table:number-columns-repeated`, `table:number-rows-repeated`],
  [Materialized up to the caps below; trailing empty cells and rows are
    grid filler and are trimmed.],
  [Each materialized repeat is a real cell with its own coordinates.],
  [`table:covered-table-cell`], [Skipped: merged continuations fold into
    their originating cell, as in the ODT reader.],
  [The originating cell's `GridFacet` carries `merge_rows` and
    `merge_cols` from the spanned attributes.],
  [`table:formula`], [Never evaluated; the cached typed value is used.
    `ods.formula-without-cached-value` when there is none.],
  [`GridFacet.formula` carries the formula source verbatim, `of:=` prefix
    included.],
  [`office:annotation`], [Dropped with `ods.annotations-dropped`.],
  [none.],
)

= Deliberate omissions

#tbl(
  columns: (auto, 1fr),
  table.header([*What*], [*Why*]),
  [Cell styling, colors, borders, widths], [A GFM table has none of it.],
  [Charts, images, embedded objects], [No tree node exists for them in a
    table cell, and inventing one is a ZDS 0002 amendment.],
  [Custom number-format styles (`number:number-style` et al.)],
  [Format-string interpretation is a rendering engine; the typed value is
    honest, a wrong rendering is not.],
  [Hidden rows, columns, and sheets], [Hiding is presentation; the data
    is the content. Everything converts.],
  [Merged-cell geometry in the tree], [`table:number-columns-spanned` is
    not carried to the cell payload; the covered cells are simply absent,
    keeping rows rectangular for GFM. The extents survive in the
    originating cell's `GridFacet`.],
)

= Round-trip expectations

None: ODS is read-only and no preservation namespace is written, for the
same reason as XLSX — Markdown cannot carry cell-level typing, and the
honest form of that feature is a CSV writer.

= Security

The shared `zenfmt_ooxml` archive limits and the DTD-free XML parser apply
unchanged. Repetition attributes are the format-specific hazard: repeated
cells cap at 1,024 per row, repeated rows at 1,024 per attribute and
65,536 per sheet, and trailing empty runs collapse before emission, so a
one-attribute filler run cannot amplify the input.

= References

- ZDS 0002, _Reading the Office Formats_.
- ZDS 0005, _The XLSX Reader_ (the conventions this reader mirrors).
- OASIS OpenDocument v1.3 Part 3, `table:*` and `office:*` attributes.
