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
