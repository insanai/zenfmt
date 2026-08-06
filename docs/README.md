# zenfmt docs

The design records and the book for [zenfmt](../README.md).

## Why the words are versioned with the code

There is a saying attributed to Feynman: if you cannot explain something
simply, you do not understand it. We take that as an engineering rule, not a
slogan. Every serious design decision is written down before it is built, and
the record keeps the alternatives that lost.

For a document converter this is not optional. Every format zenfmt reads is a
lossy projection onto one shared representation, and every format it writes is
a lossy projection back out. Almost all of the engineering lives in those two
projections, and almost none of it is legible from the code: a reader that
skips a construct and a reader that has not yet implemented it look identical
in a diff. Only a record tells them apart.

## What is in here

**Design records (ZDS).** `zds/` holds the Zen Discussions, one Typst file each
under `zds/records/`. The structure follows IETF RFCs and Oxide's RFD process,
because those formats force explicit scope, status, rationale, and alternatives
instead of relying on implicit context. A record starts as a placeholder draft
(`XXXXX-slug.typ`), gets a permanent four-digit number when a maintainer
promotes it (`zig build zds-promote`), and then moves through the lifecycle:
`prediscussion`, `discussion`, `accepted`, `published`, `committed`, or
`abandoned`. A number is never reused.

The process defines itself: it is record 0001. The architecture and
implementation plan is 0002. If you want to know why something is the way it
is, the answer is in a record.

**The book.** `book.typ` and `book/` hold the skeleton of the zenfmt manual:
the page frame, the cover, the callout and figure helpers, and the planned
chapter list. No chapter is written yet and no build step compiles it. The
records describe the decisions; the book will describe the system those
decisions produced.

## Read them

The CI workflow compiles every record to PDF and to a page of the browseable
HTML bundle on each change, and publishes both:

- [All design records](https://insanai.github.io/zenfmt/)

## Build them yourself

You need [Typst](https://typst.app/) 0.15 or later on the path. The build steps
are wired into `zig build` from the repository root:

```sh
zig build zds                    # every record, to docs/build/
zig build zds -Dzds=0002         # one record, by number ...
zig build zds -Dzds=2            # ... unpadded also works
zig build zds -Dzds=zenfmt-architecture   # ... or by slug
zig build zds-index              # the registry-driven index PDF
zig build zds-site               # the experimental HTML bundle
zig build docs                   # all three
```

`-Dzds=` also selects placeholder drafts by slug, so a draft can be proofread
as a PDF before promotion.

Or call Typst directly, from the repository root:

```sh
typst compile --root docs docs/zds/records/0001-zds-process.typ out.pdf
typst compile --root docs docs/book.typ docs/build/zenfmt.pdf
```

## Rules of this tree

- A ZDS number is never reused. A superseded record moves to the `abandoned`
  state; its replacement is a new record with a new number.
- Lifecycle state changes are ordinary reviewed file edits: the `zds-*`
  metadata in the record and its `registry.typ` entry move together.
- A record that adds or changes a format plugin carries its mapping table, its
  deliberate omissions, and its round-trip expectations. The omissions section
  is what distinguishes a decision from a gap.
- A change to the IR — `Block`, `Inline`, or their tags — gets its own record,
  because it affects every plugin at once.
- Every number in a table comes from a recorded result file, not from a
  keyboard. If a table disagrees with a result file, the table is wrong.
- PDF is the archival target. The HTML bundle export is experimental.

## License

MIT. Copyright 2026 Vikrant Rathore and Ronak Rathore.
