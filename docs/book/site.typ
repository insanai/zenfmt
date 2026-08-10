// The zenfmt book, HTML edition (ZDS 0015).
//
// Build it with `zig build book-site`, or by hand:
//   typst compile --features html,bundle --root . --format bundle \
//       docs/book/site.typ docs/build/book-site
//
// This entry point emits HTML only. The archival PDF comes from
// docs/book.typ through its own invocation, because a bundle that emitted
// both would compile every chapter twice in one pass and collide the labels
// the outline, figures, and cross-references rely on.
//
// The routes below must match docs/site/content_map.json exactly; the site
// assembler asserts that the emitted file set equals the map. Typst's
// `include` needs a literal path, so the blocks are written out rather than
// generated.

#import "web.typ": chapter_frame

#let chapter(id, title, description, body) = document(
  id + "/index.html",
  title: title,
  author: ("Zen Contributors",),
  description: description,
)[
  #show: doc => chapter_frame(doc, title: title)
  #body
]

#chapter("preface", [zenfmt: Preface], [
  Why the zenfmt book exists and how to read it.
])[#include "00_front.typ"]

#chapter("tour", [A Conversion, End to End], [
  The shortest safe path from an unfamiliar document to useful Markdown.
])[#include "01_tour.typ"]

#chapter("ir", [One Representation], [
  The layered document IR every reader feeds and every writer lowers.
])[#include "02_ir.typ"]

#chapter("plugins", [Readers, Writers, Bundles], [
  How format knowledge stays out of the zenfmt core.
])[#include "03_plugins.typ"]

#chapter("office", [Every Format Is a Container], [
  Archives, binary streams, and the resource limits that bound them.
])[#include "04_office.typ"]

#chapter("markdown", [The One Writer], [
  What the Markdown writer emits, and what it refuses to guess.
])[#include "05_markdown.typ"]

#chapter("limits", [Hostile by Default], [
  Resource limits, strictness, and the browser profile.
])[#include "06_limits.typ"]

#chapter("library", [Embedding and Filtering], [
  The Zig, Python, and browser APIs, and the filter pipeline.
])[#include "07_library.typ"]

#chapter("reference", [Reference], [
  The zenfmt diagnostic catalogue and the resource limit table.
])[#include "08_reference.typ"]

#chapter("benchmark", [The Measure of the Tool], [
  Benchmark method, corpus provenance, and recorded results.
])[#include "09_benchmark.typ"]

#chapter("server", [The Server], [
  The REST and streaming API, open and secure modes, and deployment.
])[#include "10_server.typ"]
