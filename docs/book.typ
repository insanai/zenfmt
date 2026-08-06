// The zenfmt book.
//
// Not written yet, and not wired into `zig build`. The theme, the cover, and
// the figure helpers are in place so the first chapter starts from a designed
// page. Uncomment each include as its chapter lands, and add the `book` step
// to build.zig at the same time.
//
// Build it by hand meanwhile:
//   typst compile --root docs docs/book.typ docs/build/zenfmt.pdf

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

// Planned chapters. Each maps to the part of ZDS 0002 that specified it.
//
// #include "book/01_tour.typ"          // converting a document, end to end
// #include "book/02_ir.typ"            // the document representation
// #include "book/03_plugins.typ"       // writing a reader and a writer
// #include "book/04_office.typ"        // the OOXML container formats
// #include "book/05_markdown.typ"      // the Markdown writer's output rules
// #include "book/06_limits.typ"        // untrusted input and resource limits
// #include "book/07_library.typ"       // the API contract
// #include "book/08_reference.typ"     // CLI and format reference
