#import "theme.typ": *
#import "figures.typ": *

= Reference

This chapter is the desk reference: the CLI, every format, every stable
report code, every limit, and the design records, collected beside one
another. Everything here is taken from the code's own tables. Where the book
and the binary disagree, trust the binary and file the difference as a bug.

== The command line

```text
usage: zenfmt [options] INPUT
```

`INPUT` is a file path, or `-` for stdin. Stdin requires `--from` and either
`-o PATH` or `--stdout`. The reason is plain: a stream has no extension to
detect from and no name to derive the output path from.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Flag*], [*Value*], [*Meaning*]),
  [`--from`, `-f`], [`FORMAT`], [Input format. Default: from the extension,
    then from content signatures.],
  [`--to`, `-t`], [`FORMAT`], [Output format. Default: `markdown`.],
  [`--output`, `-o`], [`PATH`], [Output file. Default: `INPUT` with the
    writer's extension.],
  [`--stdout`], [], [Write the document to stdout instead of a file. No
    artifact or manifest file is committed.],
  [`--metadata-out`], [`PATH`], [Persist the manifest produced with
    `--stdout`. Only meaningful with `--stdout`.],
  [`--overwrite`], [], [Replace existing artifact and manifest paths.
    Without it an existing destination is a refusal
    (`core.destination-exists`).],
  [`--preserve-facets`], [], [Serialize full facet rows into the
    manifest instead of the default digest-and-count summaries.],
  [`--filters`], [], [Run the filter pipeline compiled into this binary.],
  [`--list-formats`], [], [Print the bundle's readers and writers with
    their extensions.],
  [`--list-filters`], [], [Print the filters compiled into this binary, in
    pipeline order.],
  [`--strict`], [], [Refuse declared loss before anything commits.
    Graded: bare `--strict` (content), `--strict=structure`,
    `--strict=exact`.],
  [`--quiet`], [], [Suppress notes.],
  [`--reports`], [`FORM`], [`text` (default) or `json`.],
  [`--limit`], [`NAME=VALUE`], [Override one resource limit. Repeatable.
    The names are in the limits table below.],
  [`--help`, `-h`], [], [Show the generated help.],
  [`--version`, `-V`], [], [Show the version.],
)

=== Exit codes

#table(
  columns: (auto, auto, 1fr),
  table.header([*Code*], [*Class*], [*Meaning*]),
  [0], [success], [The artifact committed, and on path output the manifest
    with it. Notes and warnings may still be present. Read the reports.],
  [1], [conversion], [The input could not be converted: malformed content,
    an invalid tree, an I/O failure, or a graded `--strict` refusal of
    declared loss.],
  [2], [usage], [The invocation is wrong: an unknown format, an
    undetectable input, a flag mistake. Fixable at the command line.],
  [3], [limit], [A resource limit refused the input: archive bombs, depth
    bombs, oversized inputs, refused encryption. The security refusals
    have no override.],
)

== The formats

19 readers, one writer. Every reader's plugin id is
`ai.insan.zenfmt.<format>`. Detection weighs both kinds of evidence:
for in-memory input the content signature always runs, and when it
contradicts the extension, content wins with a `core.extension-mismatch`
note. File inputs whose extension routes are read directly. `--from`
overrides everything.

#table(
  columns: (4fr, 5fr, 8fr, 6fr, 3fr),
  table.header([*Format*], [*Extensions*], [*Content signature*],
    [*Facets*], [*Record*]),
  [`docx`], [`.docx .docm`], [ZIP central directory names
    `word/document.xml`], [style, revision, layout, media], [0003],
  [`doc`], [`.doc`], [CFB magic + `WordDocument` stream], [style,
    provenance], [0012],
  [`odt`], [`.odt`], [ZIP + OpenDocument text mimetype], [style,
    revision, media], [0006],
  [`rtf`], [`.rtf`], [Leading `{\rtf`], [style], [0004],
  [`xlsx`], [`.xlsx .xlsm`], [ZIP names `xl/workbook.xml`], [grid],
    [0005],
  [`xlsb`], [`.xlsb`], [ZIP names `xl/workbook.bin`], [grid], [0012],
  [`xls`], [`.xls`], [CFB magic + `Workbook` or `Book` stream], [grid],
    [0012],
  [`ods`], [`.ods`], [ZIP + OpenDocument spreadsheet mimetype], [grid],
    [0008],
  [`csv`], [`.csv .tsv`], [extension only], [none], [0002],
  [`pptx`], [`.pptx .pptm .ppsx .ppsm`], [ZIP names
    `ppt/presentation.xml`], [layout, media], [0007],
  [`ppt`], [`.ppt .pps .pot`], [CFB magic + `PowerPoint Document`
    stream], [provenance], [0012],
  [`odp`], [`.odp`], [ZIP + OpenDocument presentation mimetype],
    [layout], [0009],
  [`epub`], [`.epub`], [ZIP + `application/epub+zip` mimetype],
    [provenance], [0010],
  [`pdf`], [`.pdf`], [Leading `%PDF`], [layout, provenance, media],
    [0011],
  [`html`], [`.html .htm`], [extension only], [extension nodes], [0002],
  [`markdown`], [`.md .markdown`], [extension only], [none], [0002],
  [`asciidoc`], [`.adoc .asciidoc`], [extension only], [none], [0002],
  [`rst`], [`.rst`], [extension only], [none], [0002],
  [`text`], [`.txt .text`], [extension only. The fallback is never silent:
    an undetectable input is a usage refusal.], [none], [0002],
)

*Word processing.* DOCX maps styles to headings through `basedOn` chains,
synthesizes lists from numbering properties, folds merged table cells, and
carries footnotes. Comments and text boxes are counted omissions; tracked
insertions and deletions additionally ride as revision facets, and style
names, page size, and image bytes are carried too. Legacy DOC resolves
Heading 1 through 9 from the binary stylesheet and extracts hyperlink
fields; other named styles survive as style facets. ODT resolves automatic
styles, images, sections, and inline footnotes. RTF covers tables, lists,
fields, footnotes, and outline headings.

*Spreadsheets.* All five spreadsheet readers project one sheet to one `h2`
plus one table, first row as header, with typed cells. Dates render ISO.
Percentages multiply out. Formulas keep their cached values, and a note
says so.

*Presentations.* A slide projects to a title heading plus body content:
lists, tables, links, images. Speaker notes land in a `container` classed
`notes`. Every presentation conversion carries its projection warning.
Charts and animation do not survive, and the reader says so rather than
pretending; shape geometry, though, now rides in layout facets in EMU.

*Publishing.* EPUB walks container, then package, then spine, and parses
chapters with the HTML machinery. DRM is refused outright. PDF is native
Zig text extraction: xref and object streams, FlateDecode, ToUnicode CMaps,
width metrics, heading tiers from font sizes. It carries a
layout-projection note on every conversion, because a PDF has pages, not
structure.

== Report codes

Every diagnostic carries a stable code, asserted by at least one test. The
catalog below groups the codes by namespace. Severity is the worst the code
is issued at. Class is the exit class when the code is fatal; "none" marks
notes and warnings, which fail a conversion only under `--strict`.

=== Engine (`core.*`)

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Code*], [*Severity*], [*Class*], [*Meaning*]),
  [`core.out-of-memory`], [error], [conversion], [The reserved
    allocation-failure report. Always available, never allocated.],
  [`core.destination-exists`], [error], [conversion], [The output exists
    and `--overwrite` was not given.],
  [`core.file-operation-failed`], [error], [conversion], [An open, write,
    flush, or rename failed. The report names the operation and path.],
  [`core.input-too-large`], [error], [limit], [The input exceeds
    `max_input_bytes`.],
  [`core.invalid-document-tree`], [error], [conversion], [A plugin or
    filter produced a tree the validator rejects.],
  [`core.nested-table-flattened`], [warning], [none], [The
    `flatten-nested-tables` filter replaced an inner table.],
  [`core.stale-or-invalid-manifest`], [warning], [none], [An adjacent
    input manifest failed digest or schema checks and was ignored.],
  [`core.strict-refused`], [error], [conversion], [The graded `--strict`
    predicate refused the priced loss. Nothing was committed.],
  [`core.construct-refused`], [error], [conversion], [The document
    contains a construct the selected writer refuses to degrade in any
    mode.],
  [`core.extension-mismatch`], [note], [none], [The file extension and
    the content signature disagreed; content evidence routed the file.],
  [`cli.usage`], [error], [usage], [The command line itself was invalid;
    the report highlights the offending argument.],
  [`core.undetectable-input-format`], [error], [usage], [No extension
    match and no content signature. The report lists every known
    format.],
  [`core.unknown-input-format`], [error], [usage], [`--from` or `--to`
    named a format this bundle does not carry. The report suggests the
    nearest name.],
)

=== Markdown writer (`markdown.*`)

The writer's codes are loss notes. Markdown cannot represent the construct,
the writer degraded it deliberately, and the manifest says so.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Code*], [*Severity*], [*Meaning*]),
  [`markdown.style-dropped`], [note], [Underline, small caps, and similar
    styling have no Markdown syntax. The text is kept plain.],
  [`markdown.extension-fallback`], [note], [A namespaced plugin extension
    the writer does not understand rendered as its source-neutral
    fallback content.],
  [`markdown.container-attributes-dropped`], [note], [A container's id,
    classes, or attributes have no plain-Markdown form.],
  [`markdown.cell-span-degraded`], [note], [GFM tables cannot span. Merged
    cells flatten into their first cell.],
  [`markdown.table-cell-flattened`], [note], [Block content inside a cell
    became one line.],
  [`markdown.nested-table-dropped`], [warning], [A table inside a table
    cell cannot be written. Its text content was kept.],
  [`markdown.definition-list-degraded`], [note], [Definition lists render
    as emphasized terms plus indented paragraphs.],
  [`markdown.list-number-style-degraded`], [note], [Alpha and roman list
    numbering becomes decimal.],
  [`markdown.citation-dropped`], [note], [Citations render as their text.
    Keys are not preserved in Markdown.],
  [`markdown.raw-dropped`], [note], [A raw block for another format was
    omitted.],
  [`markdown.invalid-utf8`], [error], [The tree contained invalid UTF-8.
    That is an engine invariant violation surfaced at the writer.],
)

=== Office Open XML (`docx.*`, `xlsx.*`, `pptx.*`)

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Code*], [*Severity*], [*Class*], [*Meaning*]),
  [`docx.not-an-archive`], [error], [conversion], [Not a ZIP container.],
  [`docx.hostile-archive`], [error], [limit], [Path traversal names or
    other hostile central-directory content. No override exists.],
  [`docx.archive-limit`], [error], [limit], [An entry count, size, ratio,
    or name-length limit tripped: the zip-bomb family.],
  [`docx.encrypted`], [error], [conversion], [OOXML encryption. zenfmt
    never attempts decryption.],
  [`docx.unsupported-compression`], [error], [conversion], [An entry uses
    a method other than stored or deflate.],
  [`docx.doctype-refused`], [error], [limit], [A DOCTYPE in a part. The
    XML parser refuses DTDs outright.],
  [`docx.xml-too-deep`], [error], [limit], [Element nesting beyond
    `max_xml_depth`.],
  [`docx.malformed-xml`], [error], [conversion], [A part fails to parse.],
  [`docx.missing-document-part`], [error], [conversion], [The package
    relationships name no main document.],
  [`docx.unhandled-construct`], [warning], [none], [Recognized
    WordprocessingML handled by nobody. Named in the report.],
  [`docx.media-limit`], [note], [none], [Image extraction stopped at the
    resource limits; later images keep their in-archive references.],
  [`docx.merged-cells-degraded`], [note], [none], [`gridSpan` and `vMerge`
    folded for the Markdown table.],
  [`docx.comment-dropped`], [warning], [none], [Comments are review
    apparatus, not content.],
  [`xlsx.not-an-archive`], [error], [conversion], [Not a ZIP container.],
  [`xlsx.missing-workbook`], [error], [conversion], [No readable
    `xl/workbook.xml`.],
  [`xlsx.formula-without-cached-value`], [note], [none], [Formulas are not
    evaluated. Cells without cached values are empty.],
  [`pptx.not-an-archive`], [error], [conversion], [Not a ZIP container.],
  [`pptx.missing-presentation`], [error], [conversion], [No readable
    `ppt/presentation.xml`.],
  [`pptx.presentation-projection`], [warning], [none], [The standing loss
    statement: geometry, charts, and animation are absent.],
  [`pptx.merged-cells`], [note], [none], [Table span folding, as in
    DOCX.],
  [`pptx.media-limit`], [note], [none], [Embedded picture extraction
    stopped at the resource limits; the rest keep path references.],
)

=== OpenDocument (`odt.*`, `ods.*`, `odp.*`)

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Code*], [*Severity*], [*Class*], [*Meaning*]),
  [`odt.not-an-archive`], [error], [conversion], [Not a ZIP container.],
  [`odt.missing-content`], [error], [conversion], [No `content.xml`.],
  [`odt.malformed-xml`], [error], [conversion], [`content.xml` fails to
    parse.],
  [`odt.annotations-dropped`], [warning], [none], [Review annotations are
    not content.],
  [`odt.media-limit`], [note], [none], [Image extraction stopped at the
    resource limits; later images keep their in-archive references.],
  [`odt.frame-dropped`], [warning], [none], [A frame with neither image
    source nor text.],
  [`ods.not-an-archive`], [error], [conversion], [As above, for
    spreadsheets.],
  [`ods.missing-content`], [error], [conversion], [No `content.xml`.],
  [`ods.malformed-xml`], [error], [conversion], [Parse failure.],
  [`ods.annotations-dropped`], [warning], [none], [Cell annotations
    omitted.],
  [`ods.formula-without-cached-value`], [note], [none], [Formulas keep
    cached values only.],
  [`odp.not-an-archive`], [error], [conversion], [As above, for
    presentations.],
  [`odp.missing-content`], [error], [conversion], [No `content.xml`.],
  [`odp.malformed-xml`], [error], [conversion], [Parse failure.],
  [`odp.annotations-dropped`], [warning], [none], [Annotations omitted.],
  [`odp.presentation-projection`], [warning], [none], [The projection
    statement, as in PPTX.],
)

=== Legacy binary Office (`doc.*`, `xls.*`, `ppt.*`, `xlsb.*`)

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Code*], [*Severity*], [*Class*], [*Meaning*]),
  [`doc.not-a-compound-file`], [error], [conversion], [Not a CFB
    container.],
  [`doc.missing-word-stream`], [error], [conversion], [No `WordDocument`
    stream.],
  [`doc.encryption-refused`], [error], [conversion], [`fEncrypted` is set
    in the FIB. Never decrypted.],
  [`doc.styles-omitted`], [note], [none], [The document carries no
    readable stylesheet, so headings could not be resolved.],
  [`doc.tables-flattened`], [note], [none], [Binary table structure
    degrades to paragraphs.],
  [`doc.page-breaks-dropped`], [note], [none], [Page breaks have no
    Markdown meaning.],
  [`doc.embedded-objects-dropped`], [note], [none], [OLE objects
    omitted.],
  [`xls.not-a-compound-file`], [error], [conversion], [Not a CFB
    container.],
  [`xls.missing-workbook`], [error], [conversion], [No `Workbook`
    stream.],
  [`xls.encryption-refused`], [error], [conversion], [A `FILEPASS`
    record. Never decrypted.],
  [`xls.unsupported-biff`], [error], [conversion], [Pre-BIFF8 workbooks
    are refused, not misread.],
  [`xls.formula-without-cached-value`], [note], [none], [Cached values
    only, as in XLSX.],
  [`ppt.not-a-compound-file`], [error], [conversion], [Not a CFB
    container.],
  [`ppt.missing-document-stream`], [error], [conversion], [No `PowerPoint
    Document` stream.],
  [`ppt.encryption-refused`], [error], [conversion], [A crypt-session
    container, detected before any output.],
  [`ppt.presentation-projection`], [warning], [none], [The projection
    statement.],
  [`xlsb.not-an-archive`], [error], [conversion], [Not a ZIP container.],
  [`xlsb.missing-workbook`], [error], [conversion], [No
    `xl/workbook.bin`.],
  [`xlsb.sheets-unreadable`], [error], [conversion], [The workbook lists
    sheets but none loaded. An empty result is never silent.],
  [`xlsb.sheet-skipped`], [warning], [none], [Some sheets loaded and some
    did not. The count is in the report.],
)

=== Publishing (`epub.*`, `pdf.*`, `html.*`)

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Code*], [*Severity*], [*Class*], [*Meaning*]),
  [`epub.drm-refused`], [error], [limit], [`META-INF/encryption.xml` is
    present. Refused with no override.],
  [`epub.missing-container`], [error], [limit], [No
    `META-INF/container.xml`.],
  [`epub.missing-package`], [error], [conversion], [No OPF package, or no
    chapter loaded.],
  [`epub.malformed-package`], [error], [conversion], [The OPF fails to
    parse.],
  [`epub.bad-archive`], [error], [limit], [The ZIP layer refused the
    container.],
  [`epub.archive-limit`], [error], [limit], [A ZIP limit tripped.],
  [`epub.missing-chapter`], [warning], [none], [A spine item's file is
    absent. Counted.],
  [`epub.skipped-spine-item`], [note], [none], [A non-XHTML spine item
    (cover image, stylesheet) was skipped. Counted.],
  [`pdf.not-pdf`], [error], [conversion], [No `%PDF-` header.],
  [`pdf.malformed`], [error], [conversion], [Unrecoverable file
    structure: xref, trailer, or object syntax.],
  [`pdf.encryption-refused`], [error], [conversion], [An `/Encrypt`
    dictionary. Even empty-password encryption is refused.],
  [`pdf.limit`], [error], [limit], [An object-count, size, or indirection
    bound tripped.],
  [`pdf.unsupported-filter`], [warning], [none], [A stream filter zenfmt
    does not decode (CCITT, JBIG2, and others), named in the report.],
  [`pdf.unmappable-text`], [warning], [none], [A font without a usable
    Unicode mapping. Counted per font.],
  [`pdf.layout-projection`], [note], [none], [The standing statement that
    page layout became linear text with heuristic structure.],
  [`pdf.media-limit`], [warning], [none], [Image extraction stopped at
    the media limits; the remainder is omitted.],
  [`pdf.images-omitted`], [note], [none], [Images that could not be
    extracted as-is.],
  [`pdf.links-omitted`], [note], [none], [Link annotations not carried.],
  [`pdf.no-text`], [warning], [none], [No extractable text. Likely a
    scanned document; the report suggests OCR.],
  [`html.invalid-utf8`], [error], [conversion], [The input is not
    UTF-8.],
  [`html.too-deep`], [error], [limit], [Element nesting beyond
    `max_depth`.],
)

=== Lightweight markup (`text.*`, `csv.*`, `rtf.*`, `asciidoc.*`, `rst.*`)

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Code*], [*Severity*], [*Class*], [*Meaning*]),
  [`text.invalid-utf8`], [error], [conversion], [Plain text must be
    UTF-8. zenfmt does not guess encodings.],
  [`csv.invalid-utf8`], [error], [conversion], [As above.],
  [`csv.unterminated-quote`], [error], [conversion], [A quoted field
    never closes. The position is in the report.],
  [`csv.ragged-row`], [note], [none], [Rows of differing width were
    padded to the widest.],
  [`rtf.not-rtf`], [error], [conversion], [No `{\rtf` group.],
  [`rtf.groups-too-deep`], [error], [limit], [Group nesting beyond the
    reader's bound.],
  [`rtf.unknown-control-words`], [note], [none], [Control words zenfmt
    does not know, counted and sampled.],
  [`rtf.images-dropped`], [warning], [none], [`\pict` data was not
    extracted.],
  [`rtf.objects-dropped`], [warning], [none], [OLE objects omitted.],
  [`rtf.nested-table-flattened`], [note], [none], [Nested tables flatten
    into the outer cell.],
  [`asciidoc.invalid-utf8`], [error], [conversion], [Not UTF-8.],
  [`asciidoc.include-refused`], [warning], [none], [`include::` never
    reads other files. The directive is dropped and named.],
  [`rst.invalid-utf8`], [error], [conversion], [Not UTF-8.],
  [`rst.include-refused`], [warning], [none], [As above, for
    reStructuredText.],
)

== Limits

Every bound has a name, a default, and a `--limit NAME=VALUE` override.
Depth overrides above the hard cap of 4096 are refused. The cap sizes the
walker stacks, and no input is worth an unbounded stack.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Name*], [*Default*], [*Bounds*]),
  [`max_input_bytes`], [512 MiB], [Bytes read from one input document.],
  [`max_depth`], [256], [Nesting of either node tree, and so every
    explicit walker stack.],
  [`max_archive_entries`], [4096], [Entries admitted from one ZIP central
    directory.],
  [`max_entry_uncompressed`], [256 MiB], [Expanded size of one archive
    entry.],
  [`max_total_uncompressed`], [1 GiB], [Expanded size across all read
    entries.],
  [`max_compression_ratio`], [200], [Expansion ratio, checked during
    streaming decompression.],
  [`max_entry_name_bytes`], [1024], [Archive entry name length.],
  [`max_xml_depth`], [256], [XML element nesting.],
  [`max_scan_chunk_bytes`], [1 MiB], [Scanner scratch per chunk.],
  [`max_manifest_bytes`], [16 MiB], [Size of an adjacent manifest accepted
    on input.],
  [`max_plugin_data_bytes`], [4 MiB], [One plugin-data namespace value.],
  [`max_manifest_depth`], [64], [JSON nesting in an accepted manifest.],
  [`max_report_samples`], [4], [Locations an aggregated report lists
    before counting the rest.],
  [`max_resources`], [256], [Resources a reader may extract from one
    document.],
  [`max_resource_bytes`], [128 MiB], [Total extracted resource bytes per
    document.],
  [`max_nodes`], [16 Mi], [Kernel nodes, blocks plus inlines, per
    document.],
  [`max_facet_rows`], [1 Mi], [Facet rows across all facet tables.],
  [`max_decoded_text_bytes`], [256 MiB], [Decoded text pool bytes,
    distinct from `max_input_bytes`.],
  [`max_lowering_alternatives`], [8], [Lowering alternatives a writer may
    declare per construct.],
  [`max_lowering_work`], [64 Mi], [Lowering rule applications per
    conversion.],
)

== Environment

Building and testing zenfmt needs exactly Zig 0.16.0. Building the design
records and this book additionally needs Typst 0.15 or later. The benchmark
optionally uses pandoc and Node.js (for anydoc). Both are competitors, not
dependencies.

```text
zig build                 # the CLI into zig-out/bin/
zig build test            # the full suite
zig build fmt-check       # formatting
zig build docs            # ZDS records, index, and site
zig build benchmark       # the conversion benchmark (see its chapter)
```

== The design records

The Zen Discussion records under `docs/zds/` carry the decisions this book
describes. Each format record states its mapping table, its deliberate
omissions with their report codes, and its round-trip expectations. That is
the review-time half of the honesty contract. The report system is the
runtime half.

#table(
  columns: (auto, 1fr),
  table.header([*Record*], [*Title and scope*]),
  [0001], [The Zen Discussion Process: the lifecycle, numbering, and
    registry these records live in.],
  [0002], [zenfmt: Architecture and Implementation. The AST, the engine,
    filters, bundles, the manifest, diagnostics, the coding standard, and
    the delivery plan.],
  [0003], [The DOCX Reader.],
  [0004], [The RTF Reader.],
  [0005], [The XLSX Reader.],
  [0006], [The ODT Reader.],
  [0007], [The PPTX Reader.],
  [0008], [The ODS Reader.],
  [0009], [The ODP Reader.],
  [0010], [The EPUB Reader.],
  [0011], [The PDF Reader.],
  [0012], [The Legacy Binary Office Readers: DOC, XLS, PPT, and XLSB, plus
    the CFB container.],
  [0013], [Layered Document IR and Writer Lowering: the IR v2 kernel
    schema, entities and sparse facets, extension nodes, the resource
    store, the lowering planner with graded strict, and the core
    contract repairs. Committed: the system this book describes.],
)

#book_quote(
  [The most consulted page of a reference is the one that admits what the
  system does not do.],
  [the omissions tables, in every format record],
)
