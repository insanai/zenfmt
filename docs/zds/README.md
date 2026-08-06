# Zen Discussions

Zen Discussions (ZDS) are the RFC/RFD-style design records for the zenfmt
monorepo: the document-conversion library and the `zenfmt` command-line tool.
Each ZDS is a standalone Typst file under `docs/zds/records`, while
`docs/zds/registry.typ` drives the index and bundle output.

The full process — lifecycle, states, authoring rules, and the numbering
workflow — is defined by ZDS 0001, which is itself a record. This file is the
short operational version.

## Layout

- `records/`: one Typst source file per ZDS.
- `template/rfc-template.typ`: starting point for new ZDS drafts.
- `registry.typ`: metadata used by the index and bundle.
- `index.typ`: registry-driven discussion index.
- `bundle.typ`: experimental Typst bundle entry point that emits `index.html`,
  per-ZDS HTML pages, and per-ZDS PDFs.
- `../shared/zds.typ` and `../shared/theme.typ`: shared document frame,
  styling, and index components.

`build.zig` discovers records by scanning `records/`, so only `registry.typ`
and `bundle.typ` carry per-record metadata; `zig build zds-promote` maintains
both.

## Build

The root `build.zig` owns the ZDS build steps:

```sh
zig build zds                  # per-record PDFs into docs/build/
zig build zds -Dzds=0002       # a single record, by number ...
zig build zds -Dzds=2          # ... unpadded also works
zig build zds -Dzds=zenfmt-architecture  # ... or by slug
zig build zds-index            # registry-driven index PDF
zig build zds-site             # experimental HTML bundle into docs/build/zds-site/
zig build docs                 # all of the above
```

`-Dzds=` also selects placeholder drafts by slug, so a draft can be proofread
as a PDF before promotion.

## Manage

`tools/zds.zig` drives the numbering workflow from ZDS 0001:

```sh
zig build zds-list                 # registry entries, drafts, consistency warnings
zig build zds-new -- <slug>        # create records/XXXXX-<slug>.typ from the template
zig build zds-promote -- <slug>    # assign the next number, rewrite metadata,
                                   # and append registry.typ and bundle.typ entries
```

Promotion renames `XXXXX-<slug>.typ` to the next `NNNN-<slug>.typ`, sets the
state to `discussion`, and stamps today's date. Review the generated registry
summary and area fields before committing — they are derived from the draft's
`zds-discussion` and first `zds-labels` entry, which are rarely the wording you
want in the index.

Direct Typst commands are useful while editing:

```sh
typst compile --root docs docs/zds/records/0001-zds-process.typ \
  docs/build/zds-0001-zds-process.pdf
typst compile --root docs docs/zds/index.typ docs/build/zds-index.pdf
typst compile --features html,bundle --root docs --format bundle \
  docs/zds/bundle.typ docs/build/zds-site
```

Typst 0.15 marks HTML and bundle export as experimental. PDF output is the
stable archival target; the bundle website is the current path for browseable
ZDS pages and the generated index.

## Adding a ZDS

1. Run `zig build zds-new -- <slug>` (or copy `template/rfc-template.typ` to
   `records/XXXXX-<slug>.typ` by hand).
2. Fill in the `#let zds-*` metadata.
3. Write the discussion using the standard sections; preview with
   `zig build zds -Dzds=<slug>`.
4. When ready for discussion, run `zig build zds-promote -- <slug>` to assign
   the next four-digit number and append the `registry.typ` and `bundle.typ`
   entries.
5. Review the generated registry summary and area fields, then run
   `zig build zds` to build everything.

## Two things the template does not remind you about

**A format record needs three extra sections.** A record that adds or changes a
format plugin carries a mapping table (every source construct and the IR node
it produces), a deliberate-omissions table (what the plugin recognizes and
drops, with the reason), and round-trip expectations. ZDS 0001 explains why:
the omissions table is the only thing that distinguishes a decision from a gap.

**Typst labels do not survive the bundle.** `zds-site` compiles each record
twice in one Typst document — once to HTML, once to PDF — so a `<label>` in a
record collides with itself and the bundle fails to build. Cross-reference
sections by name in prose instead.
