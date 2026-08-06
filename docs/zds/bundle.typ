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
  description: [A pandoc-compatible document AST stored flat, Zig filters in the manner of build.zig, a comptime plugin registry, the reader and writer contracts, OOXML ingestion, the Markdown writer, Elm-style diagnostics, and the delivery plan.],
)[
  #include "records/0002-zenfmt-architecture.typ"
]

#document("pdf/zds-0002-zenfmt-architecture.pdf")[
  #include "records/0002-zenfmt-architecture.typ"
]
