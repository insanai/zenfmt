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
  [`input`], [`.seekable` for container formats that need the whole
    file. Streaming text formats can relax this.],
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
    .input = .seekable,
    .data_version = 1,
    .read = read,
});

fn read(ctx: *core.ReadContext) core.ReadError!void {
    var lines = std.mem.splitScalar(u8, ctx.input.bytes, '\n');
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
            if (list == null) list = try ctx.out.beginList(.{
                .kind = .unordered,
                .tight = true,
            });
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

Beyond this toy, three more Emitter families matter in real readers.
Staged attributes: `ctx.out.attrs(.{ .classes = &.{"notes"} })` applies
to the next opened node. This is how ODP marks its speaker-notes
container. Deferred notes: `declareNote` mid-flow, then `beginNoteBody`
and `endNoteBody` after the main flow. This is the shape footnotes take
in DOCX, RTF, and ODT. Media: `ctx.out.media(source, bytes, mime)`
registers extracted image bytes, and the engine commits them beside the
artifact. The PDF chapter shows it end to end.

#api_anchor([`core.ReadContext`], [
  Everything a reader receives: `gpa` (the arena), `input.bytes`,
  `input_name`, `out` (the Emitter), `reports`, `limits`, and
  `manifest_in` for carried data. There is no I/O handle. A reader that
  cannot reach the filesystem cannot leak paths into the tree.
], source: [`core/src/plugin.zig`])

== The obligations

The engine holds every reader, shipped or third-party, to the same four
rules. They are worth stating plainly, because Part III is largely the
story of applying them to hostile real-world formats.

+ Every loss is a report. Drop a construct silently and the format
  record review will find it. The merged-cells note from Chapter 1 is
  the pattern. Reports carry stable codes, and the codes appear in
  tests.
+ Limits are honored, not interpreted. `ctx.limits` caps input size,
  nesting depth, archive expansion, and media bytes. Hitting a limit is
  a refusal with exit class 3. It is never an invitation to be clever.
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

One writer ships: Markdown. Its descriptor mirrors the reader's, and its
context hands over the finished document and a stream:

```zig
pub const writer = core.Writer(.{
    .id = "ai.insan.zenfmt.markdown",
    .format = "markdown",
    .extensions = &.{ "md", "markdown" },
    .write = write,
});

fn write(ctx: *core.WriteContext) core.WriteError!void {
    // ctx.doc: *const Document. Views only; storage is private.
    // ctx.out: *std.Io.Writer. Bytes stream through a hashing writer,
    // so the manifest digest covers exactly what was written.
}
```

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
    .json = "{\"paragraph_style_ids\":[\"Quote\",\"Intense\"]}",
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
reader only its own namespace, matched by `id` and gated by
`data_version`, and re-encodes all of them canonically on the way out.
A future DOCX writer could use those style ids to reconstruct what
Markdown could not hold. The manifest is how it will remember.

#warning([Version your data like a wire format], [
  `data_version` is compared before your data is returned to you. Bump
  it whenever the JSON shape changes. Stale versions are dropped, which
  is disappointing but safe. Guessing at old shapes is neither.
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
