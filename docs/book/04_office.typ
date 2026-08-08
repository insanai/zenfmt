#import "theme.typ": *
#import "figures.typ": *
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "@preview/cetz:0.5.2" as cetz

#part_page("III", [Every format], [
  Nineteen readers feed one writer. We open each container the way its
  authors intended. We take what maps. We file a report for what does not.
])

= Every Format Is a Container

#objectives([
  By the end of this chapter you should be able to name the three container
  families and place any input format in one of them. You should be able to
  explain why the ZIP reader trusts only the central directory, and trace a
  CFB stream through its FAT chain. For any office format, you should be
  able to state one thing zenfmt maps faithfully and one thing it reports
  as lost.
])

#checkpoint([representation], [
  Recall from Part II that a reader never returns a tree. It narrates one
  through the `Emitter`: `beginBlock`, `text`, `endBlock`. The validator
  checks the result. Every reader in this chapter is such a narration.
  They differ only in what they read.
])

== Three families

Every input zenfmt accepts arrives in one of three shapes. The shape
decides which support library opens it, which limits guard it, and which
attacks it must survive.

#diagram_figure(
  alt: "The container taxonomy as a layered graph. Two shared container "
    + "libraries sit in the middle: zenfmt_ooxml, which opens ZIP packages, "
    + "and zenfmt_cfb, which opens compound files. Above zenfmt_ooxml sit "
    + "the modern Office and OpenDocument readers together with EPUB; above "
    + "zenfmt_cfb sit the legacy binary Office readers. The stream formats "
    + "sit apart from both, parsing their bytes directly with no container "
    + "layer beneath them.",
  [The container taxonomy. The format libraries sit on two shared
  container libraries. `zenfmt_ooxml` opens ZIP packages and `zenfmt_cfb`
  opens compound files. Stream formats parse their bytes directly.],
  diagram(
    spacing: (14mm, 10mm),
    edge-stroke: 0.8pt + gray,
    node((1, 0), [input bytes], ..accent_style),
    node((0, 1), [ZIP package], ..node_style),
    node((1, 1), [CFB compound file], ..node_style),
    node((2, 1), [raw stream], ..node_style),
    node((0, 2), align(left)[
      docx docm xlsx xlsm \ pptx pptm ppsx ppsm \ odt ods odp epub xlsb
    ], ..aside_style),
    node((1, 2), align(left)[doc xls \ ppt pps pot], ..aside_style),
    node((2, 2), align(left)[rtf pdf html \ markdown asciidoc \ rst csv text], ..aside_style),
    edge((1, 0), (0, 1), "-|>", [`PK..`]),
    edge((1, 0), (1, 1), "-|>", [`D0 CF 11 E0`]),
    edge((1, 0), (2, 1), "-|>"),
    edge((0, 1), (0, 2), "-|>"),
    edge((1, 1), (1, 2), "-|>"),
    edge((2, 1), (2, 2), "-|>"),
  ),
)

The dispatch is content sniffing. It is not faith in file extensions. A
ZIP container names its own subtype. The characteristic part names appear
verbatim in the central directory: `word/document.xml`,
`xl/workbook.bin`, `ppt/presentation.xml`. The OpenDocument and EPUB
families carry a `mimetype` entry, and its value is stored uncompressed
for exactly this reason. Detectors can find
`application/vnd.oasis.opendocument.spreadsheet` or
`application/epub+zip` without inflating anything.

A compound file names its subtype one level down. Its directory entries
are UTF-16LE stream names. Finding `WordDocument`, `Workbook`, or
`PowerPoint Document` in the directory sectors settles doc versus xls
versus ppt. Nothing needs to be parsed first.

#definition([Content signature], [
  A byte pattern that a format's own tooling is obliged to write: magic
  numbers, mandatory part names, the `mimetype` entry. zenfmt routes on
  signatures first and treats the extension as a hint. A `.docx` that is
  really RTF converts as RTF.
])

== The ZIP discipline

The ZIP reader in `zenfmt_ooxml` reads the central directory only. Local
file headers are advisory copies. A hostile archive makes them disagree
with the directory, so zenfmt never walks them. From the directory it
accepts exactly two compression methods, stored and deflate, and it
enforces the archive limits of chapter 6 while streaming, not after.

Three rules have no override flag, because no legitimate document needs
one:

+ A hostile entry name rejects the whole archive before any entry is
  read. Hostile means absolute, drive-lettered, or containing `..`.
+ An encrypted entry is a refusal, never a skip.
+ Any compression method other than stored or deflate is a refusal.

Decompression is budgeted per entry. An entry may expand to at most
`max(compressed_size, 64)` times `max_compression_ratio` bytes. The check
runs as the inflate stream produces output. A zip bomb therefore dies in
the middle of the stream with `docx.archive-limit`, or the sibling code
of whichever format opened the archive. It costs zenfmt the budget, not
the bomb's full yield.

== The compound-file discipline

The legacy binary formats predate ZIP-in-Office by a decade. Their
container, MS-CFB, is a small FAT filesystem inside a file. It has
512-byte sectors, a File Allocation Table mapping each sector to the
next, and a directory of 128-byte entries with UTF-16LE names. Streams
smaller than 4,096 bytes live in a mini stream of 64-byte mini-sectors
with its own mini-FAT.

#diagram_figure(
  alt: "A compound-file stream drawn as numbered sector boxes connected by "
    + "arrows. Each sector's entry in the file allocation table names the "
    + "next sector, so the stream is a chain rather than a contiguous run, "
    + "and a sentinel value marks the end. A second chain is drawn looping "
    + "back on itself to show a crafted file: the walk is bounded by the "
    + "total sector count, so the loop is detected and refused rather than "
    + "followed forever.",
  [A CFB stream is a chain of sectors threaded through the FAT. Sentinel
  values terminate chains. A crafted FAT that loops back is detected,
  because every walk is bounded by the sector count, and the file is
  refused as malformed.],
  cetz.canvas(length: 1cm, {
    import cetz.draw: *
    let cells = ([hdr], [FAT], [dir], [S0], [S1], [S2], [S3])
    for (i, label) in cells.enumerate() {
      let x = i * 1.6
      rect((x, 0), (x + 1.6, 0.8),
        fill: if i < 3 { amber_light } else { blue_light },
        stroke: 0.7pt + if i < 3 { amber } else { blue })
      content((x + 0.8, 0.4), text(size: 8pt)[#label])
      content((x + 0.8, -0.3), text(size: 7pt, fill: gray)[#(i - 1)])
    }
    line((4.8 + 0.8, 0.8), (4.8 + 0.8, 1.35), (8.0 + 0.8, 1.35), (8.0 + 0.8, 0.85),
      stroke: 0.8pt + green, mark: (end: ">"))
    line((8.0 + 0.8, 0.8), (8.0 + 0.8, 1.7), (6.4 + 0.8, 1.7), (6.4 + 0.8, 0.85),
      stroke: 0.8pt + green, mark: (end: ">"))
    content((5.9, 2.1), text(size: 8pt, fill: green)[FAT chain: S0 to S3 to S2 to end])
  }),
)

`zenfmt_cfb` gives format libraries the same API shape the ZIP reader
gives: `Cfb.open(arena, bytes, limits)`, then `find(name)`, then
`readStream(arena, entry, limits)`. Every chain walk is bounded by the
sector count. The bounded walks cover the FAT, the DIFAT, the mini-FAT,
and the directory. A cyclic FAT produces `doc.not-a-compound-file`
rather than a hang. The library also owns the two text helpers every CFB
tenant needs, cp1252 and UTF-16LE decoding, because the formats inside
predate UTF-8.

== XML as events

Between the container and the reader sits one more shared machine: the
pull parser in `zenfmt_xml`. It produces events, never a tree. The events
are `element_start`, `element_end`, `text`, and `done`. A
hundred-megabyte `document.xml` therefore costs bounded memory. Three
decisions matter more than its size:

- No DTD, ever. A `DOCTYPE` declaration is refused outright, with
  `docx.doctype-refused` and its siblings. Office software never writes
  one. Entity-expansion attacks require one. The only entities that
  decode are the five predefined names and numeric references.
- Namespaces match by URI. Elements match on the pair of namespace URI
  and local name, never on prefix. A document that renames `w:` to `x:`
  parses identically.
- Depth is bounded. An explicit stack capped by `max_xml_depth` makes
  deep nesting a limit report, not a stack overflow.

#predict([
  A DOCX part starts with `<!DOCTYPE w:document []>` and otherwise
  parses cleanly. Will zenfmt convert it with a warning, or refuse?
  Decide which principle from chapter 6 applies, then check the
  transcript there.
])

== DOCX: resolution before mapping

WordprocessingML separates what a paragraph is from what it references.
The reader (ZDS 0003) therefore resolves before it maps.

- Styles. A paragraph names a style id. The file `word/styles.xml`
  chains styles through `basedOn`, bounded at 16 hops. The chain decides
  whether the paragraph is `Heading1` through `Heading9`. A heading
  arrives as `heading` with its level. Every other named style is
  preserved as plugin data in the manifest, so a future DOCX writer can
  restore it.
- Numbering. A list item names a pair, `numId` and `ilvl`. The file
  `word/numbering.xml` maps concrete to abstract numbering, which
  decides bullet versus ordered. Word stores no list structure at all,
  so zenfmt synthesizes it with a stack keyed on level. A level jump
  opens intervening empty items. A level decrease closes lists. Each
  table cell gets its own list base, so a table never leaks list state.
- Fields. `HYPERLINK` lives in a field machine. `fldChar begin` starts
  instruction capture. `separate` parses the URL and opens a link.
  `end` closes it. Readers keep the cached field result. The instruction
  text never leaks into output.

Character formatting is a set of flags on runs: bold, italic, strike,
superscript, subscript, small caps, underline. Markdown wants nesting
instead. Every flag-based reader (DOCX, RTF, ODT) converts flags to the
canonical nesting order and shares the common prefix between consecutive
runs.

#diagram_figure(
  alt: "Two adjacent formatted runs, the first bold and the second bold and "
    + "italic, shown as the inline tree they become. A single strong node "
    + "spans both runs, and an emphasis node nests inside it covering only "
    + "the second. The alternative — closing all formatting at the run "
    + "boundary and reopening it — would produce two sibling strong nodes "
    + "instead, which is not the structure a person reading the document "
    + "would describe.",
  [Two adjacent runs, bold then bold-italic. Closing everything and
  reopening would emit two separate bold spans. Sharing the common prefix
  keeps one `strong` node. This is the tree a person would draw.],
  diagram(
    spacing: (10mm, 8mm),
    edge-stroke: 0.8pt + gray,
    node((1, 0), [`strong`], ..node_style),
    node((0, 1), [text \ "bold "], ..aside_style),
    node((2, 1), [`emphasis`], ..node_style),
    node((2, 2), [text \ "italic"], ..aside_style),
    edge((1, 0), (0, 1), "-|>"),
    edge((1, 0), (2, 1), "-|>"),
    edge((2, 1), (2, 2), "-|>"),
  ),
)

#definition([Canonical inline order], [
  `link`, `strong`, `emphasis`, `strikethrough`, `superscript`,
  `subscript`, `small_caps`, `underline`, outermost first. The list lives
  in `core/src/payload.zig`. Flag sets always nest in this order, so
  equal formatting produces byte-equal Markdown from every source format.
])

Tables read their column count from `tblGrid` before the first row.
Leading `tblHeader` rows route into `table_head`. A `gridSpan` becomes
the cell's `col_span`. A `vMerge` continuation cell folds into its
originating cell. These degradations file one
`docx.merged-cells-degraded` note per table, not one per cell.

== Spreadsheets: one projection, three encodings

All four spreadsheet formats project identically. Each sheet becomes a
level-2 heading carrying the sheet name, then one GFM table whose first
row is the header. The reason is simple: a user comparing `.xlsx` output
with `.xls` output should see the same document. What differs is only the
cell encoding.

#book_figure(
  [The same cell, three ways. The projection is shared. Only the decoding
  differs, which is why the three readers agree byte-for-byte.],
  table(
    columns: (auto, 1fr, 1fr),
    table.header([*Format*], [*Encoding*], [*The characteristic trap*]),
    [xlsx / xlsm],
    [XML: `<c r="B2" t="s"><v>7</v></c>` with shared strings. Styles map
      `numFmtId` to date or percent.],
    [Self-closing `<row/>` and `<c/>` elements produce no end event. Both
      must still materialize, or the table loses its shape.],
    [xlsb],
    [Binary records in a ZIP: a record id of 1 or 2 bytes, a length
      varint of 1 to 4 bytes, then records such as `BrtCellRk`,
      `BrtCellIsst`, and cached `BrtFmlaNum`.],
    [`BrtBundleSh` in real files carries a 40-byte preamble where the
      spec example shows 36. The reader accepts both by requiring exact
      record consumption.],
    [xls],
    [BIFF8 records in a CFB stream: `BOUNDSHEET`, `SST` with `CONTINUE`
      splits, `RK` packed numbers, `FORMULA` plus a cached `STRING`.],
    [An `SST` string may switch encodings at a `CONTINUE` boundary. The
      1904 `DATEMODE` flag shifts every serial date.],
  ),
)

Dates deserve a sentence. A spreadsheet date is a float counting days
from an epoch. zenfmt renders it as ISO `YYYY-MM-DD` using the
civil-from-days algorithm, never a locale. A formula converts as its
cached value. When the cache is absent, the reader files one
`formula-without-cached-value` note and moves on. zenfmt evaluates
nothing.

== Presentations: the honest projection

A slide deck is a spatial, animated medium. A Markdown file is neither.
Every presentation reader emits an unconditional warning before its first
slide: `pptx.presentation-projection`, `ppt.presentation-projection`, or
`odp.presentation-projection`. The warning states that positioning,
animation, and non-text shapes do not survive. This is the report system
used exactly as designed. The loss is structural and guaranteed, so the
diagnostic is unconditional. `--strict` turns it into a refusal for
pipelines that must not accept it.

What does survive: slide order from `sldIdLst` resolved through
relationships, title placeholders as level-2 headings, body text with
bullet levels rebuilt as nested lists, `a:tbl` tables, external
hyperlinks resolved through each slide's own relationship part, images
with their alt text, and speaker notes as a `container` classed `notes`.
The binary `.ppt` walks its record tree instead. Every record is a
header of version, instance, type, and length. The reader harvests
`TextHeaderAtom` classifications and the `TextCharsAtom` or
`TextBytesAtom` payloads under them. ODP walks `draw:page` frames classed
`title`, `outline`, and `notes`, and reads slide tables from
`table:table` elements inside frames.

== OpenDocument text: styles and a re-parse trick

ODT keeps heading levels in the open: `text:h` carries
`text:outline-level`. Lists are explicit. Those two facts remove DOCX's
two hardest inferences. The difficulty that remains is style resolution.
A `text:span` names an automatic style. That style may chain by
`style:parent-style-name` into `styles.xml`. Only at the end of the chain
does the reader learn that `fo:font-weight` is bold.

One implementation detail is worth retelling. Footnote bodies appear
inline, inside the paragraph that references them. The AST wants note
bodies deferred to the end. So the reader captures the note body's raw
byte range during the main pass and re-parses it afterwards. The captured
fragment floated free of its namespace declarations, so the reader wraps
it in a synthetic `<office:wrap>` element that re-binds the `office:`,
`text:`, `table:`, `draw:`, and `svg:` prefixes. The pull parser neither
knows nor cares that the document is synthetic.

== EPUB: a website in a box

EPUB is ZIP holding XHTML. `META-INF/container.xml` names the OPF
package. The package's `manifest` maps ids to files. Its `spine` fixes
reading order. Dublin Core metadata (`dc:title`, `dc:creator`,
`dc:language`) becomes document metadata in the manifest. Each spine
chapter then flows through the same HTML machinery the standalone HTML
reader uses: `parseFragment` with the chapter's directory as a base, so
relative image and link targets rebase onto archive-entry paths. Chapters
concatenate without synthetic headings. The book's own headings are
trusted. A `META-INF/encryption.xml` file means `epub.drm-refused`, with
no override.

== PDF: geometry, not structure

PDF is the one input with no document structure at all. It is placed
glyphs. The reader (ZDS 0011) parses the object graph: classic xref
tables and cross-reference streams, object streams, FlateDecode with PNG
predictors. It decodes text through `ToUnicode` CMaps or the standard
encodings. It tracks the text matrix and a glyph-width pen, so words join
and split where the geometry says they do.

Structure is then recovered, conservatively. A font-size histogram per
document sets heading tiers: a line at 1.6 times the body median or more
becomes `h1`, at 1.35 times `h2`, at 1.12 times with bold `h3`. Vertical
gaps split paragraphs. Hyphenated line-wraps rejoin. Tables are claimed
only when the geometry insists. That means a drawn lattice of rules, or
start-x positions clustering into the same columns across at least three
consecutive baselines. Paragraphs win every doubt. Embedded images are
saved as-is where the encoding permits: JPEG and JPEG 2000 streams
verbatim, Flate bitmaps wrapped losslessly as PNG, through the media
pipeline of chapter 7. Where it does not permit (CCITT, JBIG2), they are
counted in `pdf.images-omitted`. The unconditional
`pdf.layout-projection` warning tells the user exactly what kind of
recovery they are reading.

== Legacy Word: the piece table

The `.doc` WordDocument stream does not store text in order. The File
Information Block points into a table stream, named `0Table` or `1Table`
(a FIB flag says which). The table stream holds the piece table: a sorted
array of character positions (cp) paired with descriptors that map each
cp range to a file offset (fc) range. Bit 30 of the fc marks 8-bit
cp1252 pieces; without it, the piece is 16-bit UTF-16LE.

#diagram_figure(
  alt: "A piece table drawn as two parallel rows. The upper row is logical "
    + "character-position order, the order a reader sees. The lower row is "
    + "physical file order. Arrows between them cross, because the pieces "
    + "were appended to the file as the document was edited rather than "
    + "rewritten in place: reading the file front to back would produce the "
    + "text out of order, so the piece table, not the file layout, defines "
    + "reading order.",
  [The piece table maps logical character positions to physical file
  ranges. Reading order is cp order, not file order. An edit in 1997
  Word appended a piece, not the text.],
  cetz.canvas(length: 1cm, {
    import cetz.draw: *
    for (i, label) in ([cp 0 to 120], [cp 120 to 200], [cp 200 to 310]).enumerate() {
      let x = i * 2.9
      rect((x, 1.6), (x + 2.9, 2.4), fill: blue_light, stroke: 0.7pt + blue)
      content((x + 1.45, 2.0), text(size: 8pt)[#label])
    }
    for (i, label) in ([fc 0x400 (16-bit)], [fc 0x1200 (8-bit)], [fc 0x900 (8-bit)]).enumerate() {
      let x = i * 2.9
      rect((x, 0), (x + 2.9, 0.8), fill: green_light, stroke: 0.7pt + green)
      content((x + 1.45, 0.4), text(size: 7.5pt)[#label])
      line((x + 1.45, 1.55), (x + 1.45, 0.85), stroke: 0.8pt + gray, mark: (end: ">"))
    }
  }),
)

Paragraph marks arrive as `\r` characters in the decoded stream. Heading
styles resolve through the stylesheet (STSH) by built-in style
identifier. The paragraph's style index is found through the PAPX
formatted-disk-page chain. Hyperlink fields hide between the field
characters `0x13`, `0x14`, and `0x15`. The reader keeps the cached
result and parses the instruction for its URL. Cell marks (`0x07`)
flatten into paragraphs with a `doc.tables-flattened` note. That is the
honest reading of a structure this reader does not yet rebuild.

== What each format loses, and what the facets carry

Every reader's ZDS record carries the full table. This is the shape of
it. The point is not the losses themselves; every converter loses these.
The point is that each loss has a name you can grep for in the manifest,
and that since IR v2 a third column exists: information Markdown cannot
hold that now rides in typed facets, carried for a richer writer instead
of merely mourned.

#table(
  columns: (4fr, 5fr, 6fr, 5fr),
  table.header([*Format*], [*Converts faithfully*],
    [*Deliberate, reported losses*], [*Carried in facets*]),
  [docx], [headings, styled runs, links, lists, tables, footnotes, images],
  [comments (`docx.comment-dropped`), text boxes, merged cells degrade
    (`docx.merged-cells-degraded`)],
  [style names, tracked insertions and deletions, page size, image
    bytes as resources],
  [rtf], [styled text, tables, lists, links, footnotes, headings],
  [image bytes (`rtf.images-dropped`), OLE objects
    (`rtf.objects-dropped`), nested tables flatten],
  [stylesheet names on styled paragraphs],
  [xlsx/xlsb/xls/ods], [typed cells, dates, cached formula values, sheet
    structure],
  [charts, cell formatting],
  [grid facets: sheet, exact row and column, value type, formula source
    where the format spells it, cached value, merges],
  [pptx/ppt/odp], [titles, body text, tables, links, images, notes],
  [animation, charts (`presentation-projection`)],
  [slide geometry in EMU (pptx, odp), per-slide provenance (ppt),
    picture bytes as resources (pptx)],
  [odt], [headings, styles, lists, tables, images, footnotes],
  [sourceless frames (`odt.frame-dropped`)],
  [common style names, annotations as comment revisions, image bytes as
    resources],
  [epub], [chapters in spine order, metadata, images, links],
  [CSS entirely, fonts; DRM'd books refuse (`epub.drm-refused`)],
  [per-chapter provenance naming the spine member],
  [pdf], [text, headings by size, paragraphs, geometric tables, embedded
    images],
  [layout itself (`pdf.layout-projection`), unmappable glyphs
    (`pdf.unmappable-text`), CCITT and JBIG2 images],
  [page positions in EMU with projected confidence, per-page
    provenance],
  [doc], [full text in both encodings, heading styles, hyperlinks],
  [table grids flatten (`doc.tables-flattened`), embedded objects],
  [STSH style names, heading provenance with stream positions],
)

Carried is not converted. The Markdown artifact is the same either way;
the facets ride in the manifest as counted, digested summaries, and in
full under `--preserve-facets`. What changed is that the loss ledger
now distinguishes three fates instead of two: rendered, reported as
lost, or carried for a writer that can use it.

#teach_back([
  Explain to a colleague why the ZIP reader ignores local file headers,
  why the DOCX reader needs a numbering stack when Word stores no list
  structure, and why all three spreadsheet readers emit byte-identical
  Markdown for equal content. If the last one stalls, re-read the
  canonical-order definition.
])

#exercise([4.1], [
  Take any `.docx` you own and run `zenfmt file.docx --reports=json`.
  Match every report code you receive to a row of the omissions table in
  ZDS 0003. Which losses did your document actually exercise?
], hint: [Most documents trip two or three codes, not the whole table.])

#exercise([4.2], [
  Rename a real `.xlsx` to `evil.docx` and convert it. Explain the output
  using the content-signature rule. Then find the sniffing order in
  `core/src/root.zig` that made it work.
])
