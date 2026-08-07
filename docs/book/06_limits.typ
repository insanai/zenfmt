#import "theme.typ": *
#import "figures.typ": *
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge

= Hostile by Default

#objectives([
  By the end of this chapter you should be able to state the threat model
  in one sentence and name the limit that stops each classic attack: the
  zip bomb, the billion laughs, the cyclic FAT, the reference loop. You
  should be able to compute a decompression budget, explain what
  `--strict` changes, and say why a failed conversion leaves no file
  behind.
])

The threat model is one sentence: every input document is untrusted
bytes. A converter is a parser farm, and parser farms are where memory
bugs, hangs, and resource exhaustion live. zenfmt's answer is not
cleverness. It is arithmetic: every allocation bounded, every loop
bounded, every expansion budgeted, and every refusal explained to the
person holding the file.

#definition([The refusal philosophy], [
  When input crosses a limit, zenfmt refuses loudly, names the limit,
  and says what to do next. It never silently degrades security, never
  retries with the check disabled, and never writes partial output.
])

#checkpoint([reports], [
  Recall from chapter 1 that every diagnostic answers four questions:
  what happened, where, what zenfmt did about it, and what you can do.
  Every refusal in this chapter is such a report, with a stable code you
  can match in scripts.
])

== The limits table

Every named bound lives in one struct, `core/src/limits.zig`. Nothing
else in the tree hard-codes a resource number. Each field is overridable
from the command line, with one exception explained below.

#book_figure(
  [Every limit, its default, and what it bounds. Overrides use
  `--limit NAME=VALUE`.],
  table(
    columns: (auto, auto, 1fr),
    table.header([*Limit*], [*Default*], [*What it bounds*]),
    [`max_input_bytes`], [512 MiB], [bytes read from one input document],
    [`max_depth`], [256], [nesting of either node tree, and the size of
      every explicit walker stack],
    [`max_archive_entries`], [4,096], [entries admitted from one archive
      central directory],
    [`max_entry_uncompressed`], [256 MiB], [expansion of one archive
      entry],
    [`max_total_uncompressed`], [1 GiB], [expansion of all read entries
      together],
    [`max_compression_ratio`], [200], [expansion ratio, checked during
      streaming decompression],
    [`max_entry_name_bytes`], [1,024], [length of one archive entry
      name],
    [`max_xml_depth`], [256], [XML element nesting],
    [`max_scan_chunk_bytes`], [1 MiB], [scanner scratch per chunk],
    [`max_manifest_bytes`], [16 MiB], [size of an adjacent manifest
      accepted on input],
    [`max_plugin_data_bytes`], [4 MiB], [one plugin-data namespace
      value],
    [`max_manifest_depth`], [64], [JSON nesting in an accepted
      manifest],
    [`max_report_samples`], [4], [locations one aggregated report lists
      before counting the rest],
    [`max_resources`], [256], [resources a reader may extract],
    [`max_resource_bytes`], [128 MiB], [total extracted resource bytes],
    [`max_nodes`], [16 Mi], [kernel nodes per document],
    [`max_facet_rows`], [1 Mi], [facet rows across all tables],
    [`max_decoded_text_bytes`], [256 MiB], [decoded text pool bytes],
    [`max_lowering_alternatives`], [8], [lowering alternatives per construct],
    [`max_lowering_work`], [64 Mi], [rule applications per conversion],
  ),
)

The exception: `max_depth` and `max_xml_depth` may be raised only to
4,096, the hard cap that sizes every fixed walker stack in the binary.
An override above the cap is refused as an invalid value. There is no
flag that turns a bounded stack into an unbounded one.

The last five rows are IR v2's additions (ZDS 0013). `max_nodes` and
`max_decoded_text_bytes` bound the kernel itself, so a small compressed
input cannot decode into an unbounded tree or text pool. A facet bomb,
one paragraph carrying a million annotations, dies at `max_facet_rows`
as a refusal rather than an allocation storm; the erasure axiom makes
this safe, because no facet can change what renders. The two lowering
limits cap the writer's planning work under hostile rule interactions.

Memory has one more bound worth knowing. Since the InputMode repair, a
ZIP-backed format read from a file is never held in memory whole: the
reader windows the central directory and each entry separately, so peak
memory is the directory plus one expanding entry, not the archive
beside its expansion. Piped input for those formats spills to a
temporary file first for the same reason.

== Bombs are a budget problem

A zip bomb is a small file that expands enormously. The defense is not
detecting bombs. It is refusing to pay for them. Each archive entry gets
a budget:

$ "allowance" = max("compressed size", 64) times "max_compression_ratio" $

With the default ratio of 200, a 1 KiB entry may expand to 200 KiB, and
a 486 KiB entry to about 95 MiB. The check runs inside the inflate loop,
as output is produced. The moment the stream exceeds its allowance, the
conversion stops with an archive-limit report and the remaining
gigabytes are never decompressed. The per-entry and total caps back the
ratio up, so many medium entries cannot add up to a surprise either.

The same budget discipline guards PDF streams: FlateDecode output is
capped by the same ratio and size rules before predictors run.

== The attacks with names

*Billion laughs.* The XML entity-expansion attack needs a DTD, and a DTD
needs a `DOCTYPE`. zenfmt refuses the `DOCTYPE` itself. This is the real
banner, produced by a crafted `.docx`:

```
-- XML WITH A DOCTYPE REFUSED ---------------------------------- zenfmt

A part in this document carries a DOCTYPE declaration. No office
application writes one, and DTD processing is how XML entity-expansion
attacks work, so zenfmt never processes them.

The conversion stopped and no output file was created.

What you can do:

    Treat the file as suspect; a legitimate document re-exported from
    its native application will not carry a DOCTYPE.
```

Note the last line of the middle paragraph. No output file was created.
We verify that claim below.

*Cyclic chains.* A CFB file whose FAT points sector 3 at sector 5 and
sector 5 back at sector 3 would hang a naive reader forever. Every chain
walk in `zenfmt_cfb` is bounded by the sector count, so the cycle is
detected within one pass and refused as malformed.

*Reference loops.* A PDF object that resolves to itself, directly or
through friends, would recurse a naive resolver to death. The resolver
bounds indirection at 32 hops and carries an in-progress set, so a loop
is `pdf.malformed`, not a hang. The xref chain is bounded at 64
sections; the page tree walk carries a visited set and a page cap.

*Traversal names.* An archive entry named `../../etc/passwd` rejects the
entire archive before any entry is read. There is no per-entry
forgiveness, because a name like that means the archive was built by an
attacker, and nothing else in it deserves trust.

== Encryption is always a refusal

zenfmt does not decrypt documents, not even with well-known default
passwords. An encrypted input is refused with a format-specific code and
no override flag:

#table(
  columns: (auto, 1fr),
  table.header([*Code*], [*Trigger*]),
  [`docx.encrypted`], [an OOXML package with encryption],
  [`doc.encryption-refused`], [the FIB encryption flag in a `.doc`],
  [`xls.encryption-refused`], [a `FILEPASS` record in the workbook],
  [`ppt.encryption-refused`], [a crypt-session container in the deck],
  [`pdf.encryption-refused`], [an `/Encrypt` dictionary in the trailer,
    including the empty-password case],
  [`epub.drm-refused`], [a `META-INF/encryption.xml` entry],
)

The include directives of the lightweight formats get the same
treatment. AsciiDoc `include::` and reStructuredText `.. include::`
would let a document read arbitrary files from the machine converting
it. Both are refused, with `asciidoc.include-refused` and
`rst.include-refused`.

#predict([
  You run a batch of ten thousand documents overnight and three refuse
  with `docx.encrypted`. Is that a bug in the batch, a bug in zenfmt, or
  exactly the designed behavior? What exit class do those three return,
  and how does your script tell them apart from crashes?
])

The answer to the last part: refusals carry an exit class. The CLI exits
0 on success, and maps conversion failures, usage errors, and limit
refusals to 1, 2, and 3. A bulk script can count zip bombs without
reading a single banner.

== Strict mode

`--strict` turns warnings into failure. The check runs after the writer
has produced bytes but before anything is committed, so a strict failure
leaves no artifact, no manifest, and no media files. Pipelines that must
not accept lossy conversions get a hard gate; interactive users keep the
default, which converts and explains.

== Running out of memory is not a crash

`convert` never returns an error union. Its result always carries
reports. One failure mode deserves special care: what if the failure is
that there is no memory left to build a report? zenfmt reserves a static
report, `core.out-of-memory`, compiled into the binary, requiring zero
allocation to return. The allocation-failure suite proves it: the test
harness injects failure at every single allocation site in a conversion,
one site at a time, and asserts that every run returns the reserved
report and never a crash or a partial artifact.

The fuzzers complete the picture. Every text reader has a fuzz target
that feeds it arbitrary bytes, with the tree validator of chapter 2 as
the oracle. A reader may refuse garbage. It may convert garbage into a
strange but valid document. It may not produce an invalid tree, and it
may not hang, because every loop it runs is bounded by the limits table
above.

== Nothing partial ever lands

The last defense is the commit protocol. A conversion that fails
must leave the filesystem exactly as it found it, and a conversion that
succeeds must never be observable half-done.

#book_figure(
  [The commit order. Every write goes to an unpredictable temporary name
  first. The artifact becomes visible before its manifest, so a manifest
  never describes a file that does not exist.],
  diagram(
    spacing: (20mm, 9mm),
    edge-stroke: 0.8pt + gray,
    node((0, 0), [write artifact \ to temp file], ..node_style),
    node((1, 0), [strict gate \ checks reports], ..node_style),
    node((2, 0), [write manifest \ to temp file], ..node_style),
    node((0, 1), [publish artifact \ (link or replace)], ..node_style),
    node((1, 1), [write media \ `<stem>_media/`], ..node_style),
    node((2, 1), [publish manifest], ..accent_style),
    edge((0, 0), (1, 0), "-|>"),
    edge((1, 0), (2, 0), "-|>"),
    edge((2, 0), (0, 1), "-|>"),
    edge((0, 1), (1, 1), "-|>"),
    edge((1, 1), (2, 1), "-|>"),
  ),
)

The mechanics are ordinary and boring, which is the point. Temporary
files are created next to their targets with unpredictable names. The
artifact is published by link, which fails if the destination exists and
`--overwrite` was not given (`core.destination-exists`), or by replace
when it was. Media files follow, under the artifact's own
`<stem>_media` directory. The manifest publishes last. A crash at any
step leaves either the previous state or the complete new state, plus
temp files the next run ignores.

We promised the DOCTYPE banner told the truth. Here is the check:

```
$ zenfmt doctype.docx -o out.md; echo "exit=$?"
exit=3
$ ls out.md
ls: out.md: No such file or directory
```

Refused, explained, exit class 3, and no partial `out.md` anywhere.

#teach_back([
  Explain the decompression budget to someone who has never seen a zip
  bomb: what number is fixed, what number the attacker controls, and why
  checking during the stream rather than after changes everything. Then
  explain why `--limit max_depth=100000` is refused when every other
  limit can be raised.
])

#exercise([6.1], [
  Compute the maximum bytes zenfmt will decompress for an archive with
  three entries of compressed sizes 100 bytes, 10 KiB, and 400 KiB,
  under the default limits. Which limit binds first for each entry?
], hint: [Remember the floor of 64 bytes, and check the per-entry cap
  against the ratio result.])

#exercise([6.2], [
  Build the DOCTYPE refusal yourself: any stored ZIP with a
  `word/document.xml` whose first bytes declare a DOCTYPE will do. Run
  it with `--reports=json` and find the stable code your script would
  match on.
])
