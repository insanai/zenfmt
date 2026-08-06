#let zds-number = "0011"
#let zds-title = "The PDF Reader"
#let zds-state = "discussion"
#let zds-created = "2026-08-06"
#let zds-discussion = "Mapping, omissions, and round-trip expectations for the native PDF reader"
#let zds-labels = ("formats", "pdf", "reader",)
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

The format record for `zenfmt_pdf` (`ai.insan.zenfmt.pdf`), a native Zig PDF
text extractor with no C dependency. PDF is unlike every other zenfmt input:
it describes placed glyphs, not document structure. This reader recovers
structure by projection — lines from positions, paragraphs from vertical
rhythm, headings from font-size tiers — and says so in a `pdf.layout-projection`
note on every conversion. This record is the plugin's ledger under ZDS 0001:
the mapping as implemented, the deliberate omissions with their reasons, and
what a round trip may and may not expect.

= Scope

The reader consumes the PDF file structure directly: the header (allowing up
to 1 KiB of leading junk per spec), classic cross-reference tables,
cross-reference streams (`/W`-packed, PNG-predicted), the `/Prev` incremental
update chain, hybrid `/XRefStm` bridges, and compressed objects inside
`/ObjStm` object streams. Streams decode through FlateDecode (zlib framing
with a raw-deflate fallback for sloppy producers), ASCIIHexDecode, and
ASCII85Decode, under the same ratio-and-size budgets as the ZIP layer.

Text decodes per font: an embedded `/ToUnicode` CMap when present
(`bfchar`/`bfrange`, including array destinations and surrogate pairs),
otherwise the named base encoding (WinAnsi, MacRoman, Standard) with
`/Differences` resolved through a compact Adobe Glyph List subset covering
the Latin repertoire plus `uniXXXX` names. Type0 fonts are read as two-byte
codes; without a ToUnicode map their characters are counted and reported as
`pdf.unmappable-text` rather than guessed.

Everything runs on explicit bounded machinery: a non-recursive object parser
(`max_depth`), a bounded form-XObject frame stack (depth 8), reference
resolution bounded at 32 hops with in-progress loop detection, page-tree
walking with a visited set and an 8192-page cap, and 64 cross-reference
sections at most.

= Mapping

#tbl(
  columns: (auto, 1fr),
  table.header([*Source*], [*Tree result*]),
  [Shown text (`Tj`, `TJ`, `'`, `"`)],
  [Decoded to UTF-8 and grouped into device-space lines by baseline
   position.],
  [Consecutive lines in vertical rhythm],
  [One `paragraph`; a gap exceeding 1.7 × the line's font size, a page
   change, or an upward jump starts a new one. A line ending in `-`
   followed by a lowercase continuation joins without the hyphen.],
  [Line whose font size ≥ 1.6 × the document's median body size],
  [`heading` level 1; ≥ 1.35 × level 2; ≥ 1.12 × *and* bold-named font,
   level 3. Tightly stacked heading lines of one tier merge into one
   heading.],
  [Glyph widths (`/FirstChar`+`/Widths`; CID `/W` ranges and lists with
   `/DW`, `/MissingWidth`)],
  [A device-space pen position, advanced per glyph by width/1000 × size
   plus `Tc` (and `Tw` on the space code), scaled by `Tz`. Two shows on
   one baseline join with no space when the next show starts within
   0.15 × size of the pen, and with exactly one space beyond that — so
   `(Dumm) Tj … (y) Tj` reads `Dummy`, not `Dumm y`.],
  [`TJ` kerning adjustments],
  [Pen movement of −n/1000 × size when the font has width metrics (the
   gap rule above decides about the space); for width-less fonts, the
   fallback heuristic reads ≤ −180/1000 as a word space.],
  [Form XObjects (`Do` on `/Subtype /Form`)],
  [Executed inline, own resources honored, bounded depth 8.],
  [Painted rule lattices (`m`/`l`/`re` painted by `S`/`f`/`B` variants)],
  [A lattice of at least three spanning vertical and three spanning
   horizontal rules on one page becomes a `table`; line fragments are
   assigned to cells by device position. All rows land in `table_body`:
   PDF has no header semantics, and guessing one from typography would be
   wrong more often than right.],
  [Whitespace-aligned columns],
  [Three or more consecutive lines whose fragment starts cluster onto the
   same two-plus x positions become a `table` with those columns. Single
   shared columns, short runs, and drifting positions stay paragraphs —
   detection prefers prose when in doubt.],
  [Image XObjects (`Do` on `/Subtype /Image`)],
  [Extracted as-is and committed beside the artifact through the media
   pipeline: `DCTDecode` streams verbatim as JPEG, `JPXDecode` as
   JPEG 2000, and Flate or uncompressed 8-bit `DeviceRGB`/`DeviceGray`
   rasters wrapped losslessly as PNG. Each XObject registers once however
   often it is drawn; each drawing anchors an `image` at its position in
   the flow.],
  [`/Info` `Title`, `Author`, `Subject`],
  [`metaString` `title`, `author`, `subject`; UTF-16BE with BOM and
   PDFDocEncoding both decoded.],
)

= Deliberate omissions

Each omission is visible at run time through the listed report code.

#tbl(
  columns: (auto, auto, 1fr),
  table.header([*Construct*], [*Report*], [*Reason*]),
  [Encrypted documents],
  [`pdf.encryption-refused`],
  [No decryption is implemented, even empty-password RC4; refusing outright
   is honest and keeps hostile crypto surface out of the reader. No
   override.],
  [Multi-column text, headers, footers],
  [`pdf.layout-projection`],
  [Tables are reconstructed when drawn rules or aligned columns support
   them; column flow, running headers, and footers are not. The note
   fires on every conversion so the projection is never mistaken for
   structure fidelity.],
  [Images in undecoded encodings (CCITT, JBIG2, indexed/CMYK color,
   inline `BI` data)],
  [`pdf.images-omitted`],
  [JPEG, JPEG 2000, and 8-bit RGB/gray rasters are extracted as-is;
   the rest are counted and dropped rather than transcoded. Extraction
   past the media limits stops with `pdf.media-limit`.],
  [Link annotations],
  [`pdf.links-omitted`],
  [PDF links are rectangles over the page, not text spans; mapping them
   back to words requires glyph metrics. Counted per document.],
  [CCITT, JBIG2, LZW, Crypt filters on content streams],
  [`pdf.unsupported-filter`],
  [LZW is rare enough in the wild to refuse until a corpus shows
   otherwise; DCT and JPX streams are image payloads and pass through
   the image path instead.],
  [Symbol/Dingbats and unmapped subset fonts],
  [`pdf.unmappable-text`],
  [No honest Unicode mapping exists; characters are counted, not
   guessed.],
  [Scanned pages],
  [`pdf.no-text`],
  [OCR is out of scope; the warning tells the user to run OCR first.],
)

Width metrics from the font dictionaries (`/Widths`, CID `/W`) *are*
consulted for the pen-position spacing model above. Still not consulted:
metrics inside embedded font programs themselves (a subset font that omits
`/Widths` falls back to the 500/1000 default and the TJ heuristic), per-glyph
kerning pairs, and vertical writing mode (`/W2`). Table recovery uses rule
and alignment geometry as mapped above; recovering multi-column reading
order remains future work, gated on a corpus benchmark.

= Round-trip expectations

PDF is read-only in zenfmt; there is no PDF writer, so the round trip is
`pdf → markdown → markdown` from the second pass onward, and the usual
markdown fixed-point rules apply. A PDF converted twice yields identical
bytes and an identical manifest. Paragraph and heading boundaries are
heuristic; they are stable for a given input but are not warranted to match
the authoring application's structure.

= Security

- Decompression is budgeted per stream (`max(encoded, 64) ×
  max_compression_ratio`, capped by `max_entry_uncompressed`) and enforced by
  the streaming reader, so a flate bomb fails during expansion.
- Reference loops (`a → b → a`, self-referencing `/Length`, an object stream
  containing itself) are detected by an in-progress set plus a 32-hop bound:
  `error.Malformed`, never a hang.
- The page tree walk keeps a visited set; shared or cyclic `/Kids` nodes are
  entered once. Page count is capped at 8192 (`pdf.limit`, exit class
  `limit`).
- Object nesting is bounded by `max_depth`; the operand stack, graphics
  stack, and form frame stack are fixed arrays with explicit bounds.
- Encrypted trailers are refused before any object parse.

= References

- ZDS 0002, _zenfmt: architecture_ — engine contract, limits, diagnostics.
- ISO 32000-1 (PDF 1.7), sections 7 (file structure), 9 (text and fonts).
- Adobe Glyph List specification (glyph-name to Unicode mapping).
