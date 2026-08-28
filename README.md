# zenfmt

English · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) ·
[한국어](README.ko.md)

A document converter in Zig: read a document in one format, write it in
another, with one representation in the middle.

[Pandoc](https://pandoc.org/) showed how useful a universal document converter
can be. zenfmt is a small attempt to explore that idea in Zig. It does not have
Pandoc's breadth; it concentrates on a compact engine, explicit conversion
reports, and the formats listed below.

**Current release: 0.3.6.** The architecture is specified in
[ZDS 0002](docs/zds/records/0002-zenfmt-architecture.typ) and the IR v2
layer, facets, and writer lowering in
[ZDS 0013](docs/zds/records/0013-layered-document-ir.typ); the library, CLI,
and format plugins are in the tree with a green test suite.

## What it is

zenfmt reads nineteen input formats and writes Markdown. One writer,
deliberately: the AST is easiest to judge when many readers feed a single
consumer.

| family | formats |
|---|---|
| Word processing | `docx`/`docm`, legacy `doc`, `odt`, `rtf` |
| Spreadsheets | `xlsx`/`xlsm`, `xlsb`, legacy `xls`, `ods`, `csv`/`tsv` |
| Presentations | `pptx`/`pptm`/`ppsx`/`ppsm`, legacy `ppt`/`pps`/`pot`, `odp` |
| Publishing | `epub`, `pdf` (native Zig text extraction), `html` |
| Markup | `markdown`, `asciidoc`, `rst`, plain `text` |

Inputs are detected by content signature — ZIP central-directory part names,
OpenDocument and EPUB `mimetype` entries, CFB directory streams, `%PDF`,
`{\rtf` — with the extension only as the first hint. Encrypted documents are
refused with a report, never silently skipped.

```sh
zig build                          # the zenfmt CLI into zig-out/bin/
zenfmt report.docx                 # report.md + report.md.zenfmt.json
zenfmt report.docx --stdout        # document bytes only on stdout
zenfmt --list-formats              # every reader and writer in this binary
```

Every path output gets an adjacent `*.zenfmt.json` manifest: canonical JSON
carrying provenance digests, document metadata, the diagnostic reports,
versioned plugin preservation data, and per-kind facet summaries (full rows
with `--preserve-facets`).

## Python

The same engine ships as a typed, dependency-free Python library
([ZDS 0014](docs/zds/records/0014-python-library.typ)): the `zenfmt`
distribution bundles a native bridge, releases the GIL during conversion,
and returns the complete artifact ensemble — bytes, embedded resources,
the canonical manifest, and structured reports.

```python
import zenfmt

# A str is always a path; the result is the whole in-memory ensemble.
conversion = zenfmt.convert("report.docx")
print(conversion.text)
for report in conversion.reports:
    print(report.code, report.problem)

# Bytes are explicit; text is encoded by the caller.
conversion = zenfmt.convert(uploaded_bytes, name="upload.docx", to="markdown")

# An output path selects transactional publication with the manifest and
# media beside it; graded strictness refuses priced loss before output.
conversion = zenfmt.convert("report.docx", output="build/report.md",
                            strict="structure")
```

Failures raise a compact exception tree (`ConversionError`,
`LimitExceededError`, `UnknownFormatError`, …) whose messages answer the
same four questions as the CLI's diagnostics, directions included. Reusable
policy lives in immutable `zenfmt.Converter` values; there is no global
configuration, environment lookup, or network access.

```sh
zig build python-sync    # stage the host bridge + sync the uv dev env
zig build python-test    # pytest (unit + integration) through uv
zig build python-wheel   # the host platform wheel into zig-out/python/dist
zig build python-check   # the full release gate: lint, tests, wheel, sdist
```

The Python distribution is a self-contained uv project under `python/`
(`pyproject.toml`, lockfile, packaging hook, sources, and tests); the
repository root stays a pure Zig project and `zig build` remains the
orchestrator. Development uses [uv](https://docs.astral.sh/uv/) for the
environment and lockfile, Hatchling as the build backend, Ruff for
lint/format, and pytest.

Install the library with `pip install zenfmt`. Prebuilt standalone CLI
archives and the complete wheel matrix are available from
[GitHub Releases](https://github.com/insanai/zenfmt/releases).

On macOS, the repository also provides a Homebrew cask that downloads the
matching self-contained archive directly from GitHub Releases:

```sh
brew install --cask \
  https://raw.githubusercontent.com/insanai/zenfmt/main/packaging/homebrew/Casks/zenfmt.rb
```

## Browser and WebAssembly

Release 0.3.6 includes the self-contained `zenfmt serve` service alongside the
first-class `wasm32-freestanding` distribution and the static project site
specified by [ZDS 0015](docs/zds/records/0015-wasm-and-project-site.typ).
The browser module has no host imports: document conversion runs in a dedicated
worker, on the visitor's device, with no upload or network fallback.

The public site and practical book are available in English,
[Simplified Chinese](https://insanai.github.io/zenfmt/zh-hans/),
[Japanese](https://insanai.github.io/zenfmt/ja/), and
[Korean](https://insanai.github.io/zenfmt/ko/). A first visit follows the
browser language when a translation exists. The visible language selector
always lets the reader choose explicitly, and that choice is remembered.

The same browser distribution is available as a dependency-free npm package:

```sh
npm install @insanai/zenfmt
```

It contains the audited module, ES module adapter, worker, TypeScript
declarations, and capability contract. npm is a distribution option for web
applications. The native CLI and server do not require Node or npm.

```sh
zig build wasm          # module, adapter, worker, and declarations
zig build wasm-check    # ABI, import/export, memory, and size audit
zig build site          # GitHub Pages tree in zig-out/site
zig build site-check    # deterministic build, links, policy, and semantics
zig build site-browser-test  # real Chromium conversion and interaction suite
```

The versioned WASM bundle, standalone module, native CLI archives, Python
wheels, npm package, and book PDFs are published together for release 0.3.6.
The release includes English, Simplified Chinese, Japanese, and Korean book
PDFs.
Individual ZDS PDFs remain available from GitHub Pages rather than being
duplicated as release assets. The site keeps the Book and ZDS in the help path
from every conversion state.

## Server

The same native executable includes the REST service and its web interface
([ZDS 0016](docs/zds/records/0016-server.typ)):

```sh
zenfmt serve
curl -s -T report.docx \
  "http://127.0.0.1:8998/api/v1/convert?to=markdown"

# Accounts, API keys, audit, and the administration interface.
zenfmt serve --secure --data-dir ./zenfmt-data
```

Open `http://127.0.0.1:8998/docs` for the integrated API reference or fetch
`/openapi.json` for the OpenAPI 3.1 contract. The reference remains public in
secure mode, while account and administration pages require sign in.

The released executable embeds the converter, server, database migrations,
OpenAPI document, stylesheets, JavaScript bridge, HTML shell, and interface
WebAssembly. It does not need an adjacent bundle or a Java, Python, npm, OCR,
VLM, or model runtime. Open mode is stateless and loopback-only by default.
Secure mode creates only the data directory selected by the operator.

Five properties drive the design, argued in ZDS 0002 and ZDS 0013:

- **A real AST, stored flat.** The node set is structurally compatible with
  pandoc's document model — blocks nest, inlines nest, nodes carry
  identifiers, classes, and key-value attributes. It is stored as a preorder
  struct-of-arrays in one arena, the technique Zig's own compiler uses for
  `std.zig.Ast`: `u32` indices instead of pointers, no allocation per node,
  and a subtree that is a contiguous slice.
- **Filters in Zig, in the manner of `build.zig`.** A filter is a Zig type
  with `visitBlock` and `visitInline` methods, registered into a pipeline by a
  `pub fn filters(p: *Pipeline) void` that you write in your own project and
  compile against the zenfmt module. No embedded scripting language, no
  serialization boundary. Because a transform rebuilds rather than mutates and
  an unchanged subtree is contiguous, a filter that touches nothing costs one
  `memcpy` per array.
- **The engine knows no formats.** No identifier from any file specification
  appears in the engine or the AST. A format is one file in a flat `src/` and
  one row in a comptime registry table; the conversion matrix is generated by
  the compiler.
- **Rich meaning rides in sparse facets.** Styles, tracked revisions, page
  and slide geometry (in EMU), spreadsheet formulas, and provenance attach to
  nodes as typed stand-off annotations that cost nothing when absent. The
  Markdown writer ignores them by construction; a richer writer, or your own
  tool, reads them back through the document API or the manifest.
- **Lossiness is priced, reported, and refusable.** Every writer declares its
  capabilities at compile time; every degradation is a priced rule whose loss
  lands in the manifest, and the graded `--strict={content,structure,exact}`
  refuses a conversion before anything commits. At review time each plugin's
  design record tables the same ledger.

## Repository layout

```
build.zig            build graph: modules, CLI, tests, and the zds-* steps
core/                `zenfmt_core`: the format-blind engine (schema table,
                     AST, facets, resources, lowering planner, filters)
support/             shared machinery: pull XML parser, OOXML container,
                     CFB (legacy Office) container
formats/             one library per format: docx, doc, odt, rtf, xlsx, xls,
                     xlsb, ods, csv, pptx, ppt, odp, epub, pdf, html,
                     markdown, asciidoc, rst, text
src/                 the umbrella `zenfmt` library and its default bundle
cli/                 the command-line tool; imports only the umbrella
server/              HTTP API, secure store, and embedded web interface
bindings/            Python and WebAssembly ABIs
packages/wasm/       npm package metadata and browser entry point
packaging/homebrew/  standalone Homebrew tap layout and cask
examples/filters/    a user project with its own filters compiled in
benchmarks/          the conversion benchmark and its corpus fetcher
tests/               cross-format, round-trip, fuzz, and adversarial suites
tools/zds.zig        the ZDS numbering workflow (ZDS 0001)
docs/                design records, and the skeleton of the book
docs/i18n/           authored Simplified Chinese, Japanese, and Korean books
```

Applications embed the same engine the CLI uses: `zenfmt.convert(gpa, io,
.{ .input = …, .output = … })`, or a smaller `zenfmt_core.Bundle` with only
the formats they need. Filters are declared in your own project, in the
manner of `build.zig` — see `examples/filters/`.

## Design records

Zen Discussions (ZDS) are the RFC/RFD-style design records for this repository.
The process defines itself as record 0001; the architecture is 0002; each
format plugin carries its own record (0003 onward) with its mapping table,
deliberate omissions, and round-trip expectations. See
[`docs/zds/README.md`](docs/zds/README.md) for the workflow.

```sh
zig build zds                    # every record to docs/build/
zig build zds -Dzds=2            # one record, by number or slug
zig build zds-index              # the registry-driven index PDF
zig build zds-site               # the experimental HTML bundle
zig build book                   # the zenfmt book (needs benchmark results)
zig build book-translations      # Chinese, Japanese, and Korean PDF + HTML
zig build docs                   # records, index, site, and the book
zig build zds-list               # records, drafts, and consistency warnings
zig build zds-new -- <slug>      # start a record from the template
zig build zds-promote -- <slug>  # assign it the next number
```

Building the records needs [Typst](https://typst.app/) 0.15.1 on the path —
pinned exactly, because its HTML export is experimental. Everything else needs
only Zig 0.16.

```sh
zig build test        # the test suite
zig build fmt-check   # formatting
```

## Benchmark

The reference benchmark converts 16 real documents and reports three separate
resource measures. Speed is elapsed wall time, CPU use is user plus system
processor time, and memory is peak resident set size. Ratios divide the
comparison tool by zenfmt over files both tools converted successfully.

| Native CLI comparison | Shared files | Speed | CPU use | Peak memory |
|---|---:|---:|---:|---:|
| AnyDoc / zenfmt | 14 | 6.9x | 7.9x | 10.1x |
| Pandoc / zenfmt | 6 | 18.2x | 16.5x | 16.6x |
| Docling parser only / zenfmt | 5 | 190.4x | 205.5x | 47.5x |

These are geometric means from one modest Apple-silicon machine and this
small fixed corpus. They are useful reference values, not quality scores or a
promise about every document. Docling uses model-free parsers only. OCR, VLM,
ASR, layout models, table models, enrichment, and accelerators are disabled.

The long-running server benchmark follows the native CLI benchmark and is
kept separate. It compares warm HTTP conversion, sampled memory, startup, and
short throughput runs with Apache Tika Server on the same host and corpus. In
this run, Tika used 31.1x the warm latency and 34.2x the sampled peak memory by
the same ratio direction. At one client, zenfmt recorded 552.7 documents per
second and Tika recorded 4.4. These server values describe this setup rather
than every deployment.

`zig build benchmark` measures zenfmt, [Docling](https://docling-project.github.io/docling/),
[AnyDoc](https://github.com/firecrawl/anydoc), and
[Pandoc](https://pandoc.org/) with one discarded warm-up and five measured
runs. Results land in `benchmarks/results/results.md`. The
[benchmark dashboard](https://insanai.github.io/zenfmt/benchmark/) explains
the method and links the raw records.

```sh
sh benchmarks/fetch_corpus.sh                          # once: the corpus
npm install --prefix benchmarks/.anydoc @firecrawl/anydoc   # once: anydoc
zig build benchmark -Doptimize=ReleaseSafe             # the comparison
```

## License

MIT. Copyright 2026 Vikrant Rathore and Ronak Rathore.
