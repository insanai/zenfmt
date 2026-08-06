#import "theme.typ": title_page, book_quote

#title_page(
  title: "zenfmt",
  subtitle: "One representation, every document",
  eyebrow: "A guide to writing a document converter",
  edition: "First edition",
  authors: ("Zen Contributors",),
  epigraph_label: "The premise",
  epigraph: [
    Every format a converter reads is a lossy projection onto one shared
    representation, and every format it writes is a lossy projection back out.
    The engineering is in those two projections, and so is the honesty.
  ],
)

#outline(indent: 1.2em)

= Preface

// Why this book exists, who it is for, and how to read it. The companion
// design records under docs/zds/ carry the decisions; this book describes the
// system those decisions produced.

= How to read this book

// Reading paths for the three audiences: someone converting documents,
// someone embedding the library, and someone writing a format plugin.
