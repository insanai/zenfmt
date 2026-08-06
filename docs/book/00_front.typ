#import "theme.typ": title_page, book_quote, callout

#title_page(
  title: "zenfmt",
  subtitle: "One representation, every document",
  eyebrow: "A guide to writing a document converter",
  edition: "First edition",
  authors: ("Zen Contributors",),
  epigraph_label: "The premise",
  epigraph: [
    Every format a converter reads is a lossy projection onto one shared
    representation. Every format it writes is a lossy projection back out.
    The engineering is in those two projections, and so is the honesty.
  ],
)

#outline(indent: 1.2em)

#set heading(numbering: none)

= Preface

A document is a promise. Someone wrote something down, and someone else will
read it. Between the writing and the reading sits an accident of history:
the file format. The promise survives only as well as the software that
carries it across.

zenfmt is a document converter written in Zig. It reads 19 input formats
and writes GitHub-Flavored Markdown. The readers cover Word documents old
and new, spreadsheets in four encodings, presentations in three, EPUB
books, PDF files, and the lightweight markup family. The converter is also
a worked answer to a harder question. What does it take to build a
converter you can trust with a file you did not create? One whose losses
you can enumerate, and whose output you can reproduce byte for byte?

This book describes the system that answers that question. The design
decisions themselves live in the Zen Discussion records under `docs/zds/`.
Those are 12 numbered documents that argued each choice before code
existed. The book is the narrative companion. It walks the same territory
in the order a reader learns it, not the order it was decided.

Three commitments shape every chapter that follows.

- *Lossiness is reported, not hidden.* Every conversion discards
  something. zenfmt names what it dropped, in diagnostics designed after
  Elm's error messages, and records them in a manifest beside every
  artifact.
- *The engine knows no formats.* No identifier from any file specification
  appears in the core. A format is a library. The conversion matrix is
  assembled by the compiler from declarative descriptors.
- *Documents are untrusted input.* Every limit is named. Every loop is
  bounded. Every archive is treated as a potential bomb. A refusal is a
  diagnostic a person can act on, never a crash and never silence.

#book_quote(
  [Simplicity is a great virtue but it requires hard work to achieve it and
    education to appreciate it. And to make matters worse: complexity sells
    better.],
  [Edsger W. Dijkstra, "On the nature of Computing Science" (1984)],
)

= How to read this book

The chapters are ordered for a reader who has never seen zenfmt. They are
written to be entered wherever your problem starts.

*If you have a document to convert*, start with Chapter 1. It follows one
DOCX file from the command line to its Markdown artifact and manifest. Keep
Chapter 8, the reference, under your thumb.

*If you are embedding the library or writing filters*, read Chapters 1
and 2 for the shared vocabulary, then go straight to Chapter 7. The filter
system is the library's proudest surface. The worked example there compiles
a project of your own against the zenfmt package.

*If you are writing a format plugin*, Chapters 2 and 3 are your contract.
They give the document representation you must build and the reader
obligations the engine will hold you to: tokens, reports, and limits.
Chapters 4 through 6 then show every trick the shipped readers use, from
CFB sector chains to PDF width metrics, and what they refuse to do.

*If you are here to judge the claims*, Chapter 9 is the benchmark. It
states the method, the corpus, and the measurements against pandoc and
anydoc. Its dashboard renders from the same machine-readable results file
the build step writes.

#callout([Conventions], [
  Code and element names are set in `monospace`. Transcripts show real
  command output, captured from the build this book compiled against.
  Boxed asides like this one carry definitions, predictions, and
  checkpoints. The book expects you to argue with it before it reveals an
  answer. Every chapter closes with a teach-back. If you cannot explain
  the chapter to a colleague in five sentences, the chapter has not
  finished with you.
])

// Chapters resume numbered headings; the front matter alone is unnumbered.
#set heading(numbering: "1.1")
#counter(heading).update(0)
