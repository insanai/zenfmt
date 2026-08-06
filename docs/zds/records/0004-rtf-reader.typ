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
    headers and footers, `pict`, `object`, list tables, revision tables.],
)

= Deliberate omissions

#tbl(
  columns: (auto, 1fr),
  table.header([*Report code*], [*What is recognized and dropped*]),
  [`rtf.unknown-control-words`],
  [Every control word outside the mapping: layout (`\qc`, `\li`, `\sa`),
    fonts and colors (`\f`, `\fs`, `\cf`), sections, and anything a
    producer invented. Skipped, text kept, said once.],
)

Not yet mapped rather than refused: RTF tables (`\trowd`/`\cell`), lists
(`\pn`), fields, footnotes, and hyperlinks. Their visible text survives as
paragraph content; their structure does not. Each is a candidate amendment
to this record, not a silent gap: the omission is recorded here precisely
so it reads as a decision.

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
