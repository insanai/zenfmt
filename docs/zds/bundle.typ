#import "../shared/zds.typ": zds-site-index
#import "registry.typ": zds-documents

#document(
  "index.html",
  title: [Zen Discussions],
  author: ("Zen Contributors",),
  description: [Index of Zen Discussion records.],
)[
  #zds-site-index(zds-documents)
]

#document(
  "zds/0001-zds-process.html",
  title: [ZDS 0001: The Zen Discussion Process],
  author: ("Zen Contributors",),
  description: [ZDS process and Typst project workflow.],
)[
  #include "records/0001-zds-process.typ"
]

#document("pdf/zds-0001-zds-process.pdf")[
  #include "records/0001-zds-process.typ"
]

#document(
  "zds/0002-zenfmt-architecture.html",
  title: [ZDS 0002: zenfmt: Architecture and Implementation],
  author: ("Zen Contributors",),
  description: [A Zig-native document AST stored flat behind tagged-union views, Zig filters in the manner of build.zig, comptime plugin bundles, adjacent artifact manifests, OOXML ingestion, the Markdown writer, Elm-style diagnostics, and the delivery plan.],
)[
  #include "records/0002-zenfmt-architecture.typ"
]

#document("pdf/zds-0002-zenfmt-architecture.pdf")[
  #include "records/0002-zenfmt-architecture.typ"
]

#document(
  "zds/0003-docx-reader.html",
  title: [ZDS 0003: The DOCX Reader],
  author: ("Zen Contributors",),
  description: [Mapping, omissions, and round-trip expectations for the DOCX reader],
)[
  #include "records/0003-docx-reader.typ"
]

#document("pdf/zds-0003-docx-reader.pdf")[
  #include "records/0003-docx-reader.typ"
]

#document(
  "zds/0004-rtf-reader.html",
  title: [ZDS 0004: The RTF Reader],
  author: ("Zen Contributors",),
  description: [Mapping, omissions, and round-trip expectations for the RTF reader],
)[
  #include "records/0004-rtf-reader.typ"
]

#document("pdf/zds-0004-rtf-reader.pdf")[
  #include "records/0004-rtf-reader.typ"
]

#document(
  "zds/0005-xlsx-reader.html",
  title: [ZDS 0005: The XLSX Reader],
  author: ("Zen Contributors",),
  description: [Mapping, omissions, and round-trip expectations for the XLSX reader],
)[
  #include "records/0005-xlsx-reader.typ"
]

#document("pdf/zds-0005-xlsx-reader.pdf")[
  #include "records/0005-xlsx-reader.typ"
]

#document(
  "zds/0006-odt-reader.html",
  title: [ZDS 0006: The ODT Reader],
  author: ("Zen Contributors",),
  description: [Mapping, omissions, and round-trip expectations for the ODT reader],
)[
  #include "records/0006-odt-reader.typ"
]

#document("pdf/zds-0006-odt-reader.pdf")[
  #include "records/0006-odt-reader.typ"
]

#document(
  "zds/0007-pptx-reader.html",
  title: [ZDS 0007: The PPTX Reader],
  author: ("Zen Contributors",),
  description: [Mapping, omissions, and round-trip expectations for the PPTX reader],
)[
  #include "records/0007-pptx-reader.typ"
]

#document("pdf/zds-0007-pptx-reader.pdf")[
  #include "records/0007-pptx-reader.typ"
]

#document(
  "zds/0008-ods-reader.html",
  title: [ZDS 0008: The ODS Reader],
  author: ("Zen Contributors",),
  description: [Mapping, omissions, and round-trip expectations for the ODS reader],
)[
  #include "records/0008-ods-reader.typ"
]

#document("pdf/zds-0008-ods-reader.pdf")[
  #include "records/0008-ods-reader.typ"
]

#document(
  "zds/0009-odp-reader.html",
  title: [ZDS 0009: The ODP Reader],
  author: ("Zen Contributors",),
  description: [Mapping, omissions, and round-trip expectations for the ODP reader],
)[
  #include "records/0009-odp-reader.typ"
]

#document("pdf/zds-0009-odp-reader.pdf")[
  #include "records/0009-odp-reader.typ"
]

#document(
  "zds/0010-epub-reader.html",
  title: [ZDS 0010: The EPUB Reader],
  author: ("Zen Contributors",),
  description: [Mapping, omissions, and round-trip expectations for the EPUB reader],
)[
  #include "records/0010-epub-reader.typ"
]

#document("pdf/zds-0010-epub-reader.pdf")[
  #include "records/0010-epub-reader.typ"
]

#document(
  "zds/0011-pdf-reader.html",
  title: [ZDS 0011: The PDF Reader],
  author: ("Zen Contributors",),
  description: [Mapping, omissions, and round-trip expectations for the native PDF reader],
)[
  #include "records/0011-pdf-reader.typ"
]

#document("pdf/zds-0011-pdf-reader.pdf")[
  #include "records/0011-pdf-reader.typ"
]

#document(
  "zds/0012-legacy-office-readers.html",
  title: [ZDS 0012: The Legacy Binary Office Readers],
  author: ("Zen Contributors",),
  description: [Mapping, omissions, and round-trip expectations for the DOC, XLS, PPT, and XLSB readers],
)[
  #include "records/0012-legacy-office-readers.typ"
]

#document("pdf/zds-0012-legacy-office-readers.pdf")[
  #include "records/0012-legacy-office-readers.typ"
]

#document(
  "zds/0013-layered-document-ir.html",
  title: [ZDS 0013: Layered Document IR and Writer Lowering],
  author: ("Zen Contributors",),
  description: [A layered semantic IR with sparse facets and provably deterministic writer lowering, superseding the AST and writer sections of ZDS 0002],
)[
  #include "records/0013-layered-document-ir.typ"
]

#document("pdf/zds-0013-layered-document-ir.pdf")[
  #include "records/0013-layered-document-ir.typ"
]

#document(
  "zds/0014-python-library.html",
  title: [ZDS 0014: The zenfmt Python Library: API and Implementation],
  author: ("Vikrant Rathore", "Ronak Rathore"),
  description: [The implemented Python API, native boundary, uv workflow, packaging, benchmark, and release contract],
)[
  #include "records/0014-python-library.typ"
]

#document("pdf/zds-0014-python-library.pdf")[
  #include "records/0014-python-library.typ"
]

#document(
  "zds/0015-wasm-and-project-site.html",
  title: [ZDS 0015: Browser WebAssembly and the zenfmt Project Site],
  author: ("Vikrant Rathore", "Ronak Rathore"),
  description: [The implementation blueprint for the 0.1.2 Zig WebAssembly browser release, local conversion playground, project website, HTML/PDF book and ZDS help system, and reproducible benchmark dashboard],
)[
  #include "records/0015-wasm-and-project-site.typ"
]

#document("pdf/zds-0015-wasm-and-project-site.pdf")[
  #include "records/0015-wasm-and-project-site.typ"
]
