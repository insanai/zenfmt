#import "theme.typ": *
#import "figures.typ": *

#part_page("IV", [Engineering], [
  The converter becomes a library you embed and a pipeline you extend. The
  contract is one function that never fails out, one arena you own, and one
  filter system checked by the compiler.
])

= Embedding and Filtering

#objectives([
  By the end of this chapter you should be able to call `zenfmt.convert` from
  Zig or Python and dispose of its result correctly, choose the authority and
  isolation boundary for untrusted input, assemble a smaller bundle than the
  CLI ships, write a filter in your own project and compile it into a working
  binary, predict which parts of a document a sparse edit copies, and read
  another tool's `.zenfmt.json` manifest with confidence.
])

#checkpoint([prior knowledge], [
  You need the representation from Part II: flat preorder storage, typed
  indices, side tables. Nothing else. If `subtree_len` does not immediately
  mean "where my next sibling starts", reread that chapter first. Every
  promise this chapter makes about filter cost rests on it.
])

== One call, one result

The whole library is reachable from one function:

```zig
const zenfmt = @import("zenfmt");

var conversion = zenfmt.convert(gpa, io, .{
    .input = .{ .path = "report.docx" },
    .output = .{ .path = "report.md" },
});
defer conversion.deinit(gpa);
```

Look at what `convert` returns. It is not `!Conversion`. It is `Conversion`,
unconditionally:

```zig
pub const Conversion = struct {
    status: Status,               // .success or .failed
    reports: []const Report,      // every diagnostic, structured
    manifest_json: ?[]const u8,   // canonical JSON; null on failure
    exit_class: report.ExitClass, // .conversion, .usage, or .limit
    stream: StreamState,          // what a .writer output received
    arena_state: std.heap.ArenaAllocator.State,
};
```

`stream` answers a question only streamed output can raise: did the
caller's writer receive nothing, a partial prefix, or the complete
artifact? A failed streamed conversion is thereby distinguishable from
a successful conversion of an empty document. Path output reports
`.none`; its transactional commit makes the question moot.

#definition([The never-fails-out contract], [
  `convert` returns a value in every case: success, malformed input, limit
  refusal, even allocation failure. An expected failure is data. You get
  `.status == .failed` plus structured reports. The reason is simple: the
  moment a conversion fails is exactly the moment an embedding application
  needs the explanation, and a Zig error code would throw the explanation
  away.
])

One failure cannot allocate a report: running out of memory while building
reports. For that case the library keeps one reserved, statically allocated
report, with code `core.out-of-memory`. It is returned without touching the
allocator. Your error path can rely on `conversion.reports` being non-empty
and renderable even then.

=== The arena you are handed

Everything inside the result lives in one arena: the report strings, the
manifest bytes, the document that briefly existed. `convert` created the
arena, and its state travels inside the result. `deinit` promotes it back
and frees everything at once:

```zig
pub fn deinit(c: *Conversion, gpa: std.mem.Allocator) void {
    var arena = c.arena_state.promote(gpa);
    arena.deinit();
    c.* = undefined;
}
```

Two consequences are worth internalizing. First, the slices in `reports` and
`manifest_json` are valid until `deinit` and not one instruction longer. Copy
them out if they must outlive the result. Second, one conversion is one
arena. There is no per-node allocation to leak and no destructor order to
get wrong. The whole memory story of a conversion is this pair of calls.

#api_anchor([`zenfmt.convert(gpa, io, options) Conversion`], [
  One conversion, start to finish: resolve the input, detect the format,
  read, validate, filter, write, commit. Never an error union. The result
  owns its arena.
], source: [`core/src/root.zig`])

=== Rendering what happened

`Conversion.renderReports` writes the same Elm-style text the CLI prints. An
embedding application does not reimplement the diagnostic format:

```zig
if (conversion.status == .failed) {
    var buffer: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    try conversion.renderReports(&stderr.interface, .{});
    try stderr.interface.flush();
}
```

For machines rather than people, iterate `conversion.reports` directly. Each
report carries a stable `code`, a severity, a loss tier, and concrete
directions. `exit_class` classifies the worst failure: `.usage` for mistakes
a flag fixes, `.limit` for resource refusals, `.conversion` for everything
else. The CLI maps the classes to exit codes 2, 3, and 1. Your service can
map the same classes to HTTP statuses or retry policies.

== The options, one field at a time

```zig
pub const ConvertOptions = struct {
    input: InputSpec,           // .path, or .bytes with a display name
    output: OutputSpec,         // .path, or .writer (*std.Io.Writer)
    from: ?[]const u8 = null,   // explicit input format
    to: ?[]const u8 = null,     // explicit output format
    limits: Limits = .{},       // every resource bound, overridable
    overwrite: bool = false,    // replace existing artifact + manifest
    strict: Strictness = .off,  // graded refusal of declared loss
    preserve_facets: bool = false, // full facet rows in the manifest
    pipeline: ?*const Pipeline = null,
};
```

`input` as `.bytes` is how a server converts uploads without touching the
filesystem. The `name` field exists only for reports and format detection.
`output` as `.writer` streams the artifact anywhere and skips every file
side effect. No adjacent manifest is written, but `manifest_json` still
carries it. Path output stages complete temporary files, then publishes the
artifact, extracted media, and finally the manifest. Each file is individually
atomic, and the last manifest certifies the ensemble. A crash between renames
can leave a complete artifact or media file without a manifest; that state is
deliberately uncertified and a rerun with `--overwrite` repairs it.

#warning([Strict is graded, and strict before commit], [
  `Strictness` has four values. `.off` converts and reports. `.content`
  refuses when the priced plan would drop semantic content.
  `.structure` also refuses structural degradation, and `.exact`
  refuses any declared loss at all, styling included. Every grade is
  checked against the writer's lowering plan before the artifact is
  committed, so a pipeline that must never publish lossy output gets a
  hard guarantee, not a log line after the fact.
])

== Python: the same conversion as a value

The `zenfmt` Python distribution packages the default bundle behind a typed,
dependency-free API. Its common path is deliberately one call:

```python
import zenfmt

conversion = zenfmt.convert("report.docx")
print(conversion.text)
for report in conversion.reports:
    print(report.code, report.problem)
```

With no `output`, the returned `Conversion` owns the artifact bytes, canonical
manifest, reports, and every embedded resource. Supplying an output path asks
the same native publisher used by the CLI to commit the complete ensemble:

```python
conversion = zenfmt.convert(
    uploaded_bytes,
    name="upload.docx",
    output="build/report.md",
    strict="structure",
    limits=zenfmt.Limits(max_input_bytes=64 * 1024 * 1024),
)
```

A Python string is always a path, never inline document text. That explicit
path grants read authority for the file and for one adjacent, digest-bound
manifest probe. Bytes and binary readers grant no filesystem authority:
their `name` is display-only and is never opened. External resource references
are returned as metadata and never fetched. The library has no environment
configuration, runtime download, plugin discovery, or network access.

Every Python failure follows the same Elm-style diagnostic shape as the CLI.
Applications branch on `error.code`, retain structured reports, and show
`str(error)` or `error.hint` to a person. Argument mistakes remain ordinary
`TypeError` or `ValueError`, but their messages still state the problem,
consequence, and a concrete next action under `What you can do:`.

#warning([A wheel is not a sandbox], [
  The bundled native engine executes inside the Python process with that
  process's authority. Limits bound input, expansion, structure, resources,
  and output, but they do not create a process boundary. Convert higher-risk
  workloads in a restricted worker process or container, publish into a
  per-job quota-controlled directory, and create worker processes before
  starting conversion threads (or use multiprocessing `spawn`).
])

== Bundles: bring only the formats you need

The CLI's 19 readers are a choice, not a floor. `core.Bundle` builds a
conversion engine from any descriptor tuple, at compile time:

```zig
const core = @import("zenfmt_core");
const markdown = @import("zenfmt_markdown");
const docx = @import("zenfmt_docx");

const Slim = core.Bundle(.{
    .readers = .{ docx.reader, markdown.reader },
    .writers = .{markdown.writer},
});

// Slim.convert has the same signature and contract as zenfmt.convert.
```

Duplicate format names, colliding extensions, and a reader and writer
sharing one plugin id are compile errors. The messages follow the same
four-question structure as runtime reports. The engine inside the bundle
knows no format names. Its tables are generated from exactly the descriptors
you passed. A slim bundle is not a configuration of the big one. It is the
engine, smaller.

#diagram_figure(
  alt: "One conversion as the bundle runs it, drawn as a chain: input, "
    + "reader, validated tree, filter pipeline, validated tree again, "
    + "writer, artifact. Filters sit strictly between the validated tree and "
    + "the writer, and the tree is revalidated after they run, so a filter "
    + "cannot hand the writer a structure the engine would reject.",
  [A conversion, as the bundle runs it. Filters sit between the validated
    tree and the writer. Each stage revalidates.],
  pipeline((
    [reader],
    [validate],
    [filter stages],
    [writer + digest],
    [atomic commit],
  ), spacing: 24mm),
)

== Filters, in the manner of `build.zig`

zenfmt has no embedded scripting language. A filter is a Zig type. A
pipeline is a value you build in your own program. The compiler checks the
whole thing. This is the same trade `build.zig` makes: the extension
language is the implementation language. There is no serialization boundary,
no interpreter to sandbox, and no API surface that exists only in
documentation.

=== The five that ship

#table(
  columns: (auto, auto, 1fr),
  table.header([*Filter*], [*Options*], [*What it does*]),
  [`filters.shift_headings`], [`.{ .by = i8 }`], [Adds a constant to every
    heading level, clamped to 1..6.],
  [`filters.promote_first_heading`], [`.{}`], [Moves a leading level-1
    heading into document metadata as the title.],
  [`filters.drop_empty_containers`], [`.{}`], [Unwraps `container` and
    `span` nodes carrying no attributes. Genuinely useful after HTML and
    DOCX.],
  [`filters.flatten_nested_tables`], [`.{ .placeholder = "..." }`],
    [Replaces a table nested in a table cell with a placeholder paragraph
    and files a warning report.],
  [`filters.strip_classes`], [`.{ .pattern = "tmp-*" }`], [Removes classes
    matching an exact name or a `prefix*` wildcard.],
)

Each exists twice over. It is a useful transform, and it is a worked example
of one part of the contract: a typed payload edit, a metadata edit,
`.unwrap`, a subtree replacement with a report, an attribute rewrite.

=== Writing your own

The `examples/filters/` project in the repository is a complete, compiling
answer, and it is short enough to read whole. Its build depends on the
zenfmt package. Its `main.zig` is a program:

```zig
pub fn filters(p: *zenfmt.Pipeline) void {
    p.add(zenfmt.filters.shift_headings, .{ .by = 1 });
    p.add(InternalLinks, .{ .base = "https://docs.example.com/" });
    p.add(zenfmt.filters.drop_empty_containers, .{});
}
```

`Pipeline.add` takes the filter type and a value of that filter's own
`Options` type. Pass the wrong shape and the program does not compile. Order
is exactly the order written. The custom stage is a declaration:

```zig
const InternalLinks = zenfmt.Filter(.{
    .id = "example.internal-links",
    .description = "Rewrite fragment links to absolute URLs",
    .options = InternalLinksOptions,
    .inline_tags = &.{.link},
    .idempotent = true,
    .visit_inline = visitLink,
});
```

Two fields deserve attention. `inline_tags` declares the candidate set. This
filter can only ever edit `link` nodes, so the engine scans the tag column
(one contiguous `u8` array) and skips the visit machinery entirely for a
document containing no links. `idempotent` is a promise the test suite can
check: running the stage twice equals running it once.

The visit function is ordinary Zig with a typed context:

```zig
fn visitLink(
    options: *const InternalLinksOptions,
    ctx: *zenfmt.FilterContext,
    node: zenfmt.ast.InlineIndex,
) zenfmt.FilterError!zenfmt.FilterAction {
    const link = switch (ctx.inlineView(node).content) {
        .link => |value| value,
        else => unreachable,
    };
    const target = ctx.text(link.url);
    if (!std.mem.startsWith(u8, target, "#")) return .keep;

    const absolute = try ctx.fmt("{s}{s}", .{ options.base, target[1..] });
    try ctx.replaceLinkTarget(node, absolute);
    return .replace;
}
```

Build it and the binary carries the pipeline:

```text
$ zig build
$ ./zig-out/bin/zenfmt-filtered --list-filters
Filters, in pipeline order:
  core.shift-headings  Shift every heading level by a constant
  example.internal-links  Rewrite fragment links to absolute URLs
  core.drop-empty-containers  Unwrap containers and spans with no attributes
$ ./zig-out/bin/zenfmt-filtered --filters manual.md --stdout
## Guide

See [the intro](https://docs.example.com/intro) and [other](https://ziglang.org).
```

The fragment link became absolute. The `#` heading became `##`. Both
transforms ran inside one binary that is also a complete zenfmt. The last
line of the example's `main` hands the pipeline to `zenfmt.cli.main`.

#predict([
  A filter returns one of `keep`, `drop`, `unwrap`, and `replace`. Before
  reading on: which of the four can change the number of children the
  node's parent has, and which can leave the tree byte-for-byte identical
  to its input?
])

=== What a visit may do

`FilterContext` is the entire authority a stage has. For inspection it
offers `block` and `inlineView` (typed views), `text` (byte ranges to
slices), `hasClass`, `attribute`, and `parents`, the ancestor tag stack.
The ancestor stack is how `flatten_nested_tables` knows it is inside a
cell. For editing it offers the typed replacements (`replaceHeadingLevel`,
`replaceLinkTarget`, `replaceBlockAttrs`, `replaceInlineAttrs`,
`makeAttrs`), whole-subtree rebuilding (`beginReplaceBlock` hands you the
same `Emitter` readers use; `commitReplaceBlock` seals it), and one
document-level edit (`setMetaInlines`). Two utilities round it out: `fmt`
allocates into the conversion's arena, and `report` files a diagnostic
that lands in the manifest like any reader's.

What a visit cannot do is mutate the tree in place. Every action is
recorded as an edit. The engine applies them all at once.

=== Discovery, then rebuild

A pipeline stage runs in two passes. The discovery pass visits candidate
nodes in source order and collects edits. If the list is empty, the stage
returns the input document: the same value, no copy of any kind. The
identity case is not merely fast. It is measured. The test "an identity
pipeline appends no AST storage" in `tests/filters.zig` asserts that the
block, inline, and text arrays did not grow.

With edits, the rebuild pass copies the spine (the path from the root to
each edit) and bulk-copies every untouched subtree, column by column. A
subtree is a contiguous slice in preorder storage. So "copy this untouched
chapter" is one `memcpy` per column, not a traversal.

#diagram_figure(
  alt: "A sparse edit shown as two rows of node cells, the input above and "
    + "the output below. Both rows read heading, paragraph, paragraph, "
    + "heading, paragraph, table, cell, paragraph. Only the fourth cell "
    + "differs: its payload is edited. The runs of cells before and after it "
    + "are unchanged and move as two column-wise copies rather than being "
    + "walked node by node. The text, attribute, and target side tables are "
    + "not drawn as copied at all, because they are append-only and shared "
    + "between the two trees.",
  [A sparse edit. One heading's payload changes. The runs before and after
    it move as single column-wise copies. Side tables (text, attrs,
    targets) are append-only and shared, never copied.],
  {
    array_picture(
      ([h1], [para], [para], [*h2\*edit*], [para], [table], [cell], [para]),
      label: [in],
    )
    // Paged separation only: HTML export has no vertical spacing primitive
    // and the two pictures become separate images there anyway.
    context if target() != "html" { v(2mm) }
    array_picture(
      ([h1], [para], [para], [*h2'*], [para], [table], [cell], [para]),
      label: [out],
    )
  },
)

Side-table indices survive a rebuild because those tables are append-only.
A rebuilt tree's nodes still point at the same text pool, the same attrs,
the same targets, plus whatever the stage appended. That is why `ctx.fmt`
can hand a filter a new string without invalidating anything.

=== Failure and the validator

Every stage's output is validated before the next stage sees it: all eleven
tree invariants. A stage that fails mid-rebuild rolls the store back by
truncating to marks recorded at the stage boundary. A failed pipeline never
leaks a half-rebuilt document into your error path. You get `.status ==
.failed` and either `core.invalid-document-tree` or the stage's own report.

#checkpoint([the cost model], [
  Say it precisely. An identity stage costs one scan of one `u8` column per
  candidate tag. A sparse edit costs the spine plus one column-wise
  `memcpy` per untouched sibling run. Side tables are never copied. If you
  cannot justify the third clause from append-only indices, reread the
  discovery section.
])

== Reading facets

A filter or an embedding application that wants more than flow can ask
the document for its facets. The lookup is two steps, both cheap: node
to entity, entity to facet row. A node without facets has no entity and
the first step answers null, which is the whole cost of facets to code
that ignores them.

```zig
if (doc.blockEntity(index)) |entity| {
    if (doc.gridOf(entity)) |cell| {
        // cell.sheet, cell.row, cell.col, cell.formula, cell.cached
    }
    for (doc.revisionsOf(entity)) |revision| {
        // revision.kind, revision.author, revision.timestamp
    }
}
```

Five accessors cover the five kinds: `provenanceOf`, `styleOf`,
`layoutOf`, and `gridOf` return at most one row; `revisionsOf` returns
a slice, because one span can carry an insertion and a comment at once.
Layout coordinates are EMU from a top-left origin regardless of source
format; the reader that attached them already did the arithmetic.
Extracted binary content lives in the resource store,
`doc.store.resources`, each entry carrying its source name, MIME type,
bytes, and a BLAKE3 digest computed at registration.

== The manifest as an integration surface

Every path conversion commits `<output>.zenfmt.json` beside the artifact.
Every streamed conversion returns the same bytes in `manifest_json`. The
encoding is the zenfmt canonical JSON profile: UTF-8, bytewise-sorted
keys, exact integers, no whitespace. It is deliberately not RFC 8785,
which orders keys by UTF-16 code units and forces every number through
a double; the profile is specified in `core/src/json.zig` and pinned by
goldens. Two identical conversions are byte-identical, so a digest of
the manifest is meaningful.

#table(
  columns: (auto, 1fr),
  table.header([*Key*], [*What a consumer may rely on*]),
  [`source`, `artifact`], [Name, format, plugin id, and BLAKE3-256 digest
    of each side. The artifact digest is computed while streaming the
    write. If the file beside the manifest does not hash to it, the pair
    is stale.],
  [`ast`], [The tree schema name and version the conversion used.],
  [`document_metadata`], [The document's own metadata (title, authors, and
    so on) in the canonical metadata encoding.],
  [`facets`], [Present only when the document carries facets: one entry
    per kind with a row count, a digest of the canonical rows, and an
    `unused` marker saying whether the selected writer consumed the
    kind. With `preserve_facets` the full rows ride along, so a later
    same-family writer can recover them without the source.],
  [`media`], [Present only when media was extracted: one entry per
    committed file under `<stem>_media/`, path plus BLAKE3-256 digest.],
  [`reports`], [Every diagnostic, structured: code, severity, loss tier,
    locations, directions.],
  [`plugins`], [Namespaced preservation data, versioned per plugin id. A
    namespace a converter does not understand is carried value for
    value.],
  [`schema`, `schema_version`], [The envelope's own identity. Verify these
    before trusting anything else.],
)

The `plugins` map is the round-trip channel. The DOCX reader records
paragraph style ids under `ai.insan.zenfmt.docx`. A future DOCX writer, or
your own tool, reads them back. The carry rule means a manifest can pass
through tools that know nothing of a namespace without losing it.

#teach_back([
  Explain to a colleague why `convert` returning a value rather than an
  error union is a feature. Use the out-of-memory case as your hardest
  example. Then explain what an identity filter costs, and why the answer
  would be different if the tree were stored as heap nodes with pointers.
])

#exercise([7.1], [
  Write a filter `external-links-nofollow` that appends `?ref=docs` to
  every `http(s)` link target. Which candidate tag set do you declare? Is
  your filter idempotent as specified? If not, what test would catch it?
], hint: [
  `ctx.text(link.url)`, `std.mem.startsWith`, `ctx.fmt`, then
  `replaceLinkTarget`. Idempotence fails if you append unconditionally.
  Check for the suffix first.
])

#exercise([7.2], [
  Your service converts untrusted uploads with `.bytes` input and
  `.writer` output. List every filesystem side effect that configuration
  can produce, and say where the manifest ends up.
], hint: [
  Count the side effects again. The answer is a short list, and
  `manifest_json` is the whole story.
])
