// The zenfmt book.
//
// Build it with `zig build book`, or by hand:
//   typst compile --root . docs/book.typ docs/build/zenfmt-book.pdf
//
// The root is the repository, not docs/: the benchmark chapter renders its
// dashboard from /benchmarks/results/latest.json, which `zig build
// benchmark` writes.

#import "book/theme.typ": *
#import "book/figures.typ": *

#show: doc => book(
  doc,
  title: "zenfmt",
  authors: ("Zen Contributors",),
  keywords: ("document conversion", "Zig", "Markdown", "OOXML"),
  running_head: "zenfmt",
)

#include "book/00_front.typ"
#include "book/01_tour.typ"
#include "book/02_ir.typ"
#include "book/03_plugins.typ"
#include "book/04_office.typ"
#include "book/05_markdown.typ"
#include "book/06_limits.typ"
#include "book/07_library.typ"
#include "book/08_reference.typ"
#include "book/09_benchmark.typ"
#include "book/10_server.typ"
