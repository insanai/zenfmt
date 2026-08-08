#import "theme.typ": *
#import "figures.typ": *

= Readers, Writers, Bundles

#objectives([
  By the end of this chapter you should be able to write a working
  reader for a format of your own invention. You should be able to
  explain every field of its descriptor and every obligation the engine
  holds it to. You should be able to compose readers and writers into a
  `Bundle`, and describe how a plugin's preservation data survives a
  round trip through Markdown.
])

#checkpoint([prior knowledge], [
  Chapter 2's tree and Chapter 1's reports. You will write real Zig
  here. Have `zig build test` working in a checkout, because this
  chapter's toy reader is meant to be typed in, not admired.
])

== The engine knows no formats

Grep `core/` for `docx`. You will find nothing: no format name, no
element name, no magic number from any file specification. The absence
is enforced by construction. The engine learns formats only as
descriptor tables handed to it at compile time, and each descriptor is
one comptime-validated value exported by a format library.

```zig
pub const reader = core.Reader(.{
    .id = "ai.insan.zenfmt.docx",
    .format = "docx",
    .extensions = &.{ "docx", "docm" },
    .input = .seekable,
    .data_version = 1,
    .read = @import("package.zig").read,
});
```

#table(
  columns: (auto, 1fr),
  table.header([*Field*], [*Contract*]),
  [`id`], [Reverse-DNS, lowercase ASCII, at least one dot. It names the
    plugin in manifests and reports, and it keys the plugin's
    preservation-data namespace.],
  [`format`], [The name users type after `--from`. Lowercase letters,
    digits, hyphens.],
  [`extensions`], [Detection hints and derived output names. Primary
    first, no dots.],
  [`input`], [`.bytes`, the default, delivers the whole input as one
    slice. `.seekable` marks container formats: they receive a
    file-backed input, the ZIP layer reads it through bounded windows,
    and piped input spills to a temporary file first.],
  [`data_version`], [Versions the plugin's preservation-data namespace.
    Bump it, and old carried data is dropped rather than misread.],
  [`read`], [The one function the engine will call.],
)

Get a field wrong and the compiler files the report, in the same
four-question voice the runtime uses. From `core/src/plugin.zig`,
lightly abridged:

```
plugin id `Minutes` is not valid. A plugin id is reverse-DNS ASCII:
lowercase letters, digits, hyphens, and at least one dot, as in
`ai.insan.zenfmt.docx`. Change the `.id` field of this descriptor.
```

A descriptor mistake is a compile error. A malformed document is a
runtime report. Nothing is a crash.

== Inventing a format

To see the whole reader contract in one sitting, we invent a format
small enough to fit on a page. Minutes is a line-based meeting-notes
format:

```
!! Sprint 41 review
@ 2026-08-07
- decided: ship the media pipeline
- open: PDF table thresholds
Ana: the validator caught the pool bug immediately.
```

`!!` opens a heading. `@` is metadata. `-` items form a list. A `Name:`
prefix marks a speaker paragraph. Here is the complete reader, and it
compiles against the real API:

```zig
const std = @import("std");
const core = @import("zenfmt_core");

pub const reader = core.Reader(.{
    .id = "com.example.minutes",
    .format = "minutes",
    .extensions = &.{"minutes"},
    .data_version = 1,
    .read = read,
});

fn read(ctx: *core.ReadContext) core.ReadError!void {
    var lines = std.mem.splitScalar(u8, try ctx.inputBytes(), '\n');
    var list: ?core.builder.BlockToken = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "!! ")) {
            try closeList(ctx, &list);
            const heading = try ctx.out.beginHeading(1);
            try ctx.out.text(line["!! ".len..]);
            ctx.out.endBlock(heading);
        } else if (std.mem.startsWith(u8, line, "@ ")) {
            try ctx.out.metaString("date", line["@ ".len..]);
        } else if (std.mem.startsWith(u8, line, "- ")) {
            if (list == null) list = try ctx.out.beginList(.unordered);
            const item = try ctx.out.beginBlock(.list_item);
            const body = try ctx.out.beginPlain();
            try ctx.out.text(line["- ".len..]);
            ctx.out.endBlock(body);
            ctx.out.endBlock(item);
        } else {
            try closeList(ctx, &list);
            const paragraph = try ctx.out.beginParagraph();
            if (std.mem.indexOf(u8, line, ": ")) |colon| {
                const strong = try ctx.out.beginInline(.strong);
                try ctx.out.text(line[0..colon]);
                ctx.out.endInline(strong);
                try ctx.out.text(line[colon + 1 ..]);
            } else {
                try ctx.out.text(line);
            }
            ctx.out.endBlock(paragraph);
        }
    }
    try closeList(ctx, &list);
}

fn closeList(ctx: *core.ReadContext, list: *?core.builder.BlockToken) !void {
    if (list.*) |token| {
        ctx.out.endBlock(token);
        list.* = null;
    }
    return;
}
```

Four properties of the API are doing quiet work here.

First, tokens balance the tree. `beginHeading` returns a `BlockToken`
that `endBlock` must receive. Close tokens out of order and an assertion
names the exact mismatch during development. The builder maintains
`subtree_len`; your reader never touches it.

Second, `text()` canonicalizes. We passed whole lines, whitespace
included. The builder splits on whitespace into `text` and `space` nodes
and coalesces adjacent text. This is the feature Exercise 2.3 was
fishing for. A reader cannot produce the adjacent-`text` trees the
validator forbids, even if it appends one byte at a time.

Third, metadata is one call. `metaString` lands in the document's
metadata map, which lands in the manifest, sorted and canonical.

Fourth, everything allocates from `ctx.gpa`, the conversion's arena.
Note what is absent: no `free`, no ownership transfer, no lifetime
puzzle. The conversion ends, the arena goes, and the reader never
cleans up.

Beyond this toy, five more Emitter families matter in real readers.
Staged attributes: `ctx.out.attrs(.{ .classes = &.{"notes"} })` applies
to the next opened node. This is how ODP marks its speaker-notes
container. Deferred notes: `declareNote` mid-flow, then `beginNoteBody`
and `endNoteBody` after the main flow. This is the shape footnotes take
in DOCX, RTF, and ODT. Resources:
`ctx.out.resource(source, bytes, mime)` registers extracted image bytes
under a `ResourceId`, and the engine commits them beside the artifact.
Facets: every token can carry typed stand-off annotation, which is how
rich-document meaning survives a Markdown-shaped kernel. One real call
from the XLSX reader:

```zig
try ctx.out.attachGrid(cell, .{
    .sheet = sheet_name,
    .row = row_index,
    .col = column,
    .value_type = .number,
    .formula = formula_text,
    .cached = cached_text,
});
```

The facet rule is ZDS 0013's erasure axiom: a facet refines, it never
carries primary content. The kernel must render meaningfully with every
facet table empty, and the validator enforces the checkable half of
that promise. Extensions, finally, are the escape hatch for constructs
the kernel does not model: `beginExtension(owner, name, version)` opens
a namespaced node whose children are a mandatory source-neutral
fallback. A writer that understands the namespace uses the extension; a
writer that does not renders the fallback and reports the loss. The
validator rejects an empty fallback and a same-owner extension nested
inside another.

#api_anchor([`core.ReadContext`], [
  Everything a reader receives: `gpa` (the arena), `input` (bytes, or a
  file handle for `.seekable` readers, with `inputBytes()` as the
  whole-slice shim), `input_name`, `out` (the Emitter), `reports`,
  `limits`, and `preservation()` for its version-compatible carried
  namespace. A reader windows what it needs; it never opens paths of its own.
], source: [`core/src/plugin.zig`])

== The obligations

The engine holds every reader, shipped or third-party, to the same four
rules. They are worth stating plainly, because Part III is largely the
story of applying them to hostile real-world formats.

+ Every loss is a report. Drop a construct silently and the format
  record review will find it. The merged-cells note from Chapter 1 is
  the pattern. Reports carry stable codes, and the codes appear in
  tests.
+ Facets refine; they never carry content. Anything a writer must see to
  render correctly belongs in the kernel. Anything that enriches it, a
  style name, a cell formula, a page position, belongs in a facet, where
  it costs nothing to the conversions that ignore it.
+ Limits are honored, not interpreted. `ctx.limits` caps input size,
  nesting depth, archive expansion, node and facet counts, and resource
  bytes. Hitting a limit is a refusal with exit class 3. It is never an
  invitation to be clever.
+ No recursion. Every walker is a loop over an explicit, bounded stack.
  A document's nesting depth must not become your call depth, because
  the attacker chooses the document.
+ The validator has the last word. Whatever your reader emits is proven
  against Chapter 2's invariants before the pipeline continues. You
  cannot opt out. After a while you will not want to: it is the best
  free test harness a reader author gets.

#predict([
  Two readers both claim the extension `md`. When does the mistake
  surface: when the second library is written, when both are imported,
  when a bundle lists both, or at runtime on the first `.md` file?
])

== Bundles: composition at compile time

A format library exports descriptors. A bundle composes them into an
engine:

```zig
pub const Default = core.Bundle(.{
    .readers = .{
        text.reader,     markdown.reader, csv.reader,  docx.reader,
        rtf.reader,      xlsx.reader,     odt.reader,  pptx.reader,
        html.reader,     asciidoc.reader, rst.reader,  ods.reader,
        odp.reader,      epub.reader,     pdf.reader,  doc.reader,
        xls.reader,      ppt.reader,      xlsb.reader,
    },
    .writers = .{markdown.writer},
});
```

`Bundle` validates the table at compile time. Duplicate format names,
two readers claiming one extension, a reader and writer of the same
format with different ids: each is a named `@compileError`. That answers
the prediction above. The mistake surfaces when a bundle lists both, and
never later. From the validated table the compiler generates the
routing (an `inline for` that turns a runtime format string into a
comptime-dispatched call), the `--list-formats` output, the did-you-mean
suggestions, and the detection tables. The compiler writes the registry,
so no runtime registration code can drift from it.

The umbrella library's `Default` bundle is what the CLI ships. Your
application can assemble a smaller one, with 3 formats and your own
filter pipeline, and get a proportionally smaller binary. Nothing about
the default is privileged.

#book_figure(
  [A bundle at build time: descriptors in, one engine out. The engine's
  format knowledge is this table and nothing else.],
  pipeline((
    [format #linebreak() libraries],
    [descriptors],
    [`Bundle(...)` #linebreak() comptime checks],
    [`convert()`],
  ), spacing: 21mm),
)

== The writer side

One writer ships: Markdown. Its descriptor mirrors the reader's, plus
one field the reader has no analogue for: the capability declaration of
ZDS 0013.

```zig
pub const writer = core.Writer(.{
    .id = "ai.insan.zenfmt.markdown",
    .format = "markdown",
    .extensions = &.{ "md", "markdown" },
    .write = write,
    .capabilities = &capabilities,
});

pub const capabilities: core.lowering.Capabilities = .{
    .exact_blocks = &.{ .paragraph, .heading, .quote, .list, ... },
    .lowered_blocks = &.{ .definition_list, .table_cell, .extension, ... },
    .exact_inlines = &.{ .text, .emphasis, .strong, .code, ... },
    .lowered_inlines = &.{ .underline, .citation, ... },
    .rules = &rules, // each with a name, a priced LossCost, a note
};
```

The declaration is validated for totality at compile time: every kernel
tag must be exact, lowered, or refused, so a new tag fails this writer's
build until someone decides its disposition. At run time the writer's
emission sites record rule hits on `ctx.plan`; the engine prices the
plan, gates the graded `--strict` predicate before anything is
committed, and flushes one aggregated loss report per fired rule.
A writer can also recover what its own format library preserved:
`ctx.preservation()` returns only that writer descriptor's namespace from
the input's verified manifest, and only when `data_version` matches.
`ctx.preservationAs(T, decode)` is the typed decoding path. The engine never
gives a plugin a runtime namespace selector or another plugin's data.

A writer walks views with the same sibling hop the validator uses, and
it owns its output discipline completely. The Markdown writer's escaping
rules, tight-list handling, and note placement fill Chapter 5. What a
writer cannot do is reach back. The document is `*const`, and the type
system means it.

== Preservation data: the round trip's memory

Markdown cannot represent everything a reader saw. That is what the
reports are for. But some of what Markdown cannot hold is worth carrying
rather than merely mourning. A reader may attach one namespaced,
versioned JSON value to the conversion:

```zig
ctx.own_plugin_data = .{
    .version = 1,
    .data = "{\"paragraph_style_ids\":[\"Quote\",\"Intense\"]}",
};
```

The DOCX reader does exactly this with the paragraph style ids it had to
flatten. In the manifest, the value appears under the plugin's id:

```json
"plugins": {
  "ai.insan.zenfmt.docx": {
    "data": { "paragraph_style_ids": ["Quote", "Intense"] },
    "version": 1
  }
}
```

When a later conversion reads that Markdown file, the adjacent manifest
is loaded and digest-checked, and every namespace is carried forward
value-for-value. That includes namespaces from plugins this binary has
never heard of. Your plugin's data is yours alone: the engine hands a
reader or writer only its own namespace, matched by descriptor `id` and
gated by `data_version`, and re-encodes all namespaces canonically on the
way out. A DOCX writer in the same format library can decode those style
ids through `ctx.preservationAs`; no runtime plugin lookup is involved.

#warning([Version your data like a wire format], [
  `data_version` is compared before your data is returned to a reader or
  writer. Bump it whenever the JSON shape changes. Incompatible versions
  remain opaque and are carried forward, but they are not handed to the
  plugin for decoding. Guessing at old shapes is neither necessary nor safe.
])

#teach_back([
  Without looking at the listing, write the Minutes descriptor from
  memory. For each field, name the failure it prevents, and say whether
  that failure would otherwise appear at compile time or at runtime.
])

#exercise([3.1], [
  Give Minutes a second extension, `mins`, and prove detection works by
  converting `standup.mins` without `--from`.
], hint: [One array literal changes. The bundle regenerates the rest.])

#exercise([3.2], [
  Minutes ignores empty lines, which is fine. But it also accepts a
  `Name:` speaker prefix containing a URL, and mangles it. Add a report:
  code `minutes.ambiguous-speaker`, severity note, one direction. Follow
  a constructor in `formats/csv/src/reader.zig` as your model, and
  assert the code in a test.
])

#exercise([3.3], [
  Build a bundle containing only Minutes and the Markdown writer, and a
  `main` that converts stdin. Measure the binary against the full CLI.
  Where did the difference go?
], hint: [All 19 readers, their parsers, and the entity table are
  comptime-reachable code. Compare with `-Doptimize=ReleaseSmall` to
  make it starker.])
