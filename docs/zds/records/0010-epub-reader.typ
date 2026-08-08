#let zds-number = "0010"
#let zds-title = "The EPUB Reader"
#let zds-state = "committed"
#let zds-created = "2026-08-06"
#let zds-discussion = "Mapping, omissions, and round-trip expectations for the EPUB reader"
#let zds-labels = ("formats", "epub", "reader",)
#let zds-authors = ("Zen Contributors <team@insan.ai>",)
#let zds-category = "Format Record"
#let zds-status = "Committed"
#let zds-last-updated = "2026-08-08"

#import "../../shared/zds.typ": zds-document

#let tbl(..args) = table(
  stroke: 0.5pt + rgb("d7dee8"),
  inset: 6pt,
  ..args,
)

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

= Abstract

EPUB is a ZIP container whose reading order is a manifest: `META-INF/container.xml` names an
OPF package document, the package's manifest maps ids to entries, and its spine orders the
XHTML chapters. The reader (`zenfmt_epub`, plugin id `ai.insan.zenfmt.epub`) parses the
container and package itself and delegates every chapter to the shared HTML reader
(`zenfmt_html.parseFragment`), so EPUB fidelity is HTML fidelity plus packaging. Dublin Core
metadata becomes document metadata; DRM is refused outright.

= Scope

The reader consumes `.epub` files (`input = .seekable`). EPUB 2 and EPUB 3 packages are
both accepted: the reader takes the first `rootfile`, reads any OPF version, and ignores
features it does not know rather than refusing them. The output is the standard zenfmt
node set; no EPUB-specific nodes exist.

= Mapping

#tbl(
  columns: (4fr, 5fr, 4fr),
  table.header([*Source*], [*Tree result*], [*Facets*]),
  [`dc:title`, `dc:creator`, `dc:language`, `dc:date` (first of each)],
  [Metadata strings `title`, `author`, `language`, `date`.],
  [None.],
  [Spine `itemref` whose manifest item is `application/xhtml+xml` or
    `text/html`],
  [Chapter content through the HTML reader, concatenated in spine order.],
  [`ProvenanceFacet` on each chapter's first block: plugin
    `ai.insan.zenfmt.epub`, member = the spine item's archive entry path,
    confidence `exact` (ZDS 0013).],
  [Chapter markup (headings, paragraphs, lists, tables, emphasis, links,
    code)],
  [Exactly the HTML reader's mapping (ZDS 0002, tolerant tag soup),
    including `<details>` as an extension node.],
  [None beyond the chapter provenance above.],
  [`img` inside a chapter],
  [`image` node; a relative source is rebased to its container entry path
    (`OEBPS/images/pic.png`), the alt text becomes the description.],
  [None.],
  [Relative chapter-to-chapter links],
  [`link` with the target rebased to the container entry path; fragments
    kept.],
  [None.],
  [Absolute URLs, `mailto:`, pure fragments],
  [`link` targets passed through unchanged.],
  [None.],
)

Chapters concatenate without synthetic separators: when a chapter does not begin with a
heading, no heading is invented. The spine, not the navigation document, is the reading
order.

= Deliberate omissions

#tbl(
  columns: (1.2fr, 1.2fr, 0.8fr),
  table.header([*Construct*], [*Decision*], [*Report*]),
  [DRM (`META-INF/encryption.xml` present)],
  [refused outright, no override],
  [`epub.drm-refused`],
  [non-XHTML spine items (cover images, embedded media, unknown ids)],
  [skipped, counted once],
  [`epub.skipped-spine-item`],
  [spine chapters missing from the archive],
  [skipped, counted once],
  [`epub.missing-chapter`],
  [CSS styling, fonts, page-progression, fixed layout],
  [dropped silently (presentation, not content)],
  [none],
  [`toc.ncx` and `nav.xhtml` navigation structure],
  [not consulted; the spine already orders the book],
  [none],
  [multiple renditions],
  [only the first `rootfile` is read],
  [none],
)

Refusal codes for the packaging itself: `epub.missing-container` (no
`META-INF/container.xml`), `epub.missing-package` (the OPF cannot be loaded or no chapter
could be read), `epub.malformed-package` (OPF not well-formed XML), and `epub.bad-archive`
with `epub.archive-limit` (the ZIP layer's refusals, the same limits as every other
container format).

= Round-trip expectations

EPUB is read-only: zenfmt writes Markdown. A converted book keeps chapter order, heading
structure, prose, lists, tables, links (with container-entry targets for internal
references), and image references with alt text. It loses styling, pagination, fonts, and
any spine item that is not an XHTML document. Converting the produced Markdown back through
the Markdown reader reaches the writer's round-trip fixed point, as for every reader.

= Security Considerations

The ZIP layer applies the central-directory-only reader and all archive limits from ZDS
0002 (entry count and size, compression ratio, hostile names, encryption, unsupported
methods; refusals without overrides). Chapter parsing inherits the HTML reader's
`max_depth` bound, and the XML parser refuses DOCTYPE in the container and package
documents. DRM is a refusal, not a bypass: zenfmt never decrypts content.

= References

- EPUB 3.3, W3C Recommendation: container, package, and spine semantics.
- ZDS 0002: the HTML reader mapping and the archive limits this reader inherits.
