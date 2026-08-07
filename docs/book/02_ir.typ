#import "theme.typ": *
#import "figures.typ": *

#part_page("II", [One representation], [
  There are 19 readers, 1 writer, and between them a single document
  tree. This part builds that tree twice: first as the idea a filter
  author holds in their head, then as the flat arrays the machine
  actually walks.
])

= One Representation

#objectives([
  By the end of this chapter you should be able to name the block and
  inline node sets, lay out a small document as flat preorder columns,
  and hop between siblings using `subtree_len`. You should be able to
  explain the schema table that every rule about a tag derives from, say
  what an entity is and why most nodes never get one, name the five
  facet kinds and the erasure rule that keeps them optional, and state
  the invariants the validator proves after reading and after every
  filter stage.
])

#checkpoint([prior knowledge], [
  You should have converted at least one document (Chapter 1). Zig
  familiarity helps from here on: `enum(u32)`, tagged unions, and slices
  appear on every page. If `std.MultiArrayList` is new to you, this
  chapter is also a worked introduction to it.
])

== A tree you already believe in

Ask anyone to sketch a document and they draw the same thing: a heading,
then a list, one item holding a paragraph, another holding two. A tree.
The question a converter must answer is not whether the middle
representation is a tree. The question is which tree, and how it is
stored.

The answer to "which tree" is a Zig-native node set. It is structurally
compatible with pandoc's document model but owned by this project.
Blocks nest. Inlines nest. Nodes carry identifiers, classes, and
key-value attributes. The full roster, from `core/src/ast.zig`:

#table(
  columns: (3fr, 2fr),
  table.header([*Block tags*], [*Role*]),
  [`plain`, `paragraph`, `line_block`, `heading`, `code_block`,
    `raw_block`, `quote`, `list`, `definition_list`, `thematic_break`,
    `table`, `figure`, `container`],
  [Public content: what `Document.block` returns for body positions.],
  [`extension`],
  [A namespaced plugin construct. Its children are a mandatory
    source-neutral fallback, so a writer that does not understand the
    extension still has something honest to emit.],
  [`line`, `list_item`, `definition_entry`, `definition_term`,
    `definition_body`, `caption`, `table_head`, `table_body`,
    `table_foot`, `table_row`, `table_cell`],
  [Normalized structure. Each appears only under its governing parent.
    A `table_row` exists only inside a table section. A `list_item`
    exists only inside a `list`.],
)

#table(
  columns: (3fr, 2fr),
  table.header([*Inline tags*], [*Role*]),
  [`text`, `space`, `soft_break`, `hard_break`],
  [The prose layer. Text nodes never contain whitespace. Whitespace is
    always one of the three break or space nodes, so writers control
    wrapping exactly.],
  [`emphasis`, `strong`, `strikethrough`, `superscript`, `subscript`,
    `small_caps`, `underline`, `quote`, `span`],
  [Styling containers, nested in one canonical order (Chapter 3).],
  [`code`, `math`, `raw`],
  [Verbatim leaves with payloads.],
  [`link`, `image`, `note`, `citation`],
  [Containers with side-table payloads: a target, a resource reference,
    a deferred note body, a citation record.],
  [`extension`],
  [The inline spelling of the namespaced construct, with fallback
    children.],
)

Two tags keep this set closed for ordinary structure: `container` (a
block with attributes) and `span` (an inline with attributes). An
AsciiDoc sidebar, an HTML `<section>`, a DOCX content control, an ODP
speaker-notes page: each becomes a `container` with a class, not a new
node type. If a format ever truly cannot be expressed this way, the node
set is wrong. That is a design alarm, not an extension point.

The `extension` tags are the one sanctioned escape hatch, and they pay
for the privilege (ZDS 0013). An extension names its owner in
reverse-DNS form, names itself, and carries a version. Its children are
not optional decoration; they are the fallback every other writer
renders. The validator refuses an extension with no fallback, and it
refuses an extension nested inside another extension of the same owner.
The first producer is the HTML reader, which maps `<details>` to an
extension whose fallback is the summary line and the disclosed content.

#definition([Preorder], [
  Parent first, then each child subtree in order, recursively. Writing a
  tree down in preorder produces exactly the order your eye reads a
  document in. That is why a preorder array can be the document, with no
  pointers at all.
])

== The shape of the storage

The obvious implementation allocates a node object per element and links
the objects with pointers. zenfmt instead does what Zig's own compiler
does for `std.zig.Ast`. Every block lives in one `std.MultiArrayList`,
a struct-of-arrays, as parallel columns. The tree structure is encoded
in a single integer per node.

```zig
// core/src/ast.zig (storage row, private)
pub const Block = struct {
    tag: BlockTag,          // 1 byte
    payload: u32,           // meaning depends on tag
    attrs: OptionalAttrsIndex,
    inlines: InlineRange,   // for leaf blocks: its prose
    subtree_len: u32,       // this node plus all descendants
};
```

A test asserts that the columns of one block row sum to 21 bytes. A
million-block document costs 21 MB of block storage. It is contiguous,
and it is allocated out of one arena that is freed in one call when the
conversion ends. Note what the row does not contain: no entity field,
no facet pointer, no style handle. Rich-document identity lives outside
the row, in side tables that cost nothing when unused. That design is
this chapter's second half.

#definition([Arena], [
  One allocator per conversion. Every node, string, and side-table row
  is allocated from it, and none is individually freed.
  `Conversion.deinit` releases the whole document at once. There is no
  per-node `free`, because there are no per-node allocations.
])

== The worked example

ZDS 0002 fixes the layout with a small document. It is reproduced here
because every walker in the codebase is a loop over these columns.

```md
## The *quick* [brown](http://x) fox

- one
- two

  still two
```

#table(
  columns: (auto, 1fr, auto, auto, auto),
  align: (right, left, right, right, right),
  table.header([*i*], [*block*], [*payload*], [*subtree len*],
    [*inlines*]),
  [0], [`heading`], [level 2], [1], [0..9],
  [1], [`list`], [unordered], [6], [none],
  [2], [`  list_item`], [none], [2], [none],
  [3], [`    plain`], [none], [1], [9..10],
  [4], [`  list_item`], [none], [3], [none],
  [5], [`    paragraph`], [none], [1], [10..11],
  [6], [`    paragraph`], [none], [1], [11..12],
)

The indentation in the table is commentary. It is not stored. The
structure lives entirely in `subtree_len`. Node 1's subtree is 6 rows
long, so the document's next top-level block, if there were one, would
sit at index $1 + 6 = 7$. Node 2's subtree is 2, so its sibling item
sits at $2 + 2 = 4$. Walking children is a short loop. There is no
recursion and no call stack:

```zig
var child = parent + 1;
const end = parent + subtree_len[parent];
while (child < end) : (child += subtree_len[child]) {
    // visit `child`
}
```

#api_anchor([`Document.blockChildren(index)`], [
  Returns the child iterator that packages this hop. The same arithmetic
  drives inline children, the validator, the Markdown writer's frame
  stack, and the filter rebuild pass.
], source: [`core/src/ast.zig`])

The heading's prose is the inline range 0..9 in the parallel inline
table. The encoding is the same, with 13-byte rows:

#table(
  columns: (auto, 1fr, auto, auto),
  align: (right, left, left, right),
  table.header([*j*], [*inline*], [*payload*], [*subtree len*]),
  [0], [`text`], [`"The"`], [1],
  [1], [`space`], [none], [1],
  [2], [`emphasis`], [none], [2],
  [3], [`  text`], [`"quick"`], [1],
  [4], [`space`], [none], [1],
  [5], [`link`], [`targets[0]`], [2],
  [6], [`  text`], [`"brown"`], [1],
  [7], [`space`], [none], [1],
  [8], [`text`], [`"fox"`], [1],
)

Hop from 0 and you visit exactly the heading's 7 top-level children. The
hop skips the insides of `emphasis` and `link` without ever testing what
they are.

#book_figure(
  [The tag column of the block table for the worked example. The
  document is this array. There is nothing else to point to.],
  array_picture((
    [heading], [list], [list #linebreak() item], [plain],
    [list #linebreak() item], [para], [para],
  ), label: [tag], cell_width: 1.7),
)

#predict([
  A filter deletes block 3, the `plain` inside the first item. Which
  `subtree_len` values must change, and which must not? Write the
  affected indices down before reading Chapter 7's answer.
])

== Payloads live in side tables

The `payload` column is a bare `u32`. Its meaning depends on the tag.
For `heading` it is a level. For `list` it is an index into a table of
list properties. For `link` and `image` it is an index into `targets`.
For `code` it is a range in the text pool. For `extension` it is an
index into the extensions table holding the owner, the name, and the
version. These side tables (targets, headings, lists, table properties,
extensions, citations, metadata) are append-only arrays in the same
`Store`.

Append-only is a load-bearing property. Side-table indices are never
invalidated, so a filter that rebuilds the node arrays can leave every
payload index untouched and share the tables wholesale. An identity
filter costs one `memcpy` per column and zero side-table work. The test
suite measures this claim rather than asserting it.

Strings follow the same discipline. All prose lives in one UTF-8 text
pool. A `text` node's payload is a range into that pool. Extracted
binary content, such as image data a reader pulled out of a PDF or a
DOCX, lives in a separate resource pool, described below.

== One schema, one row per tag

Every fact stated so far raises the same maintenance question: where do
the rules about a tag live? What children may a `table` hold? Which side
table does a `citation` payload index? Before ZDS 0013 the answers
lived in a set of coordinated switch statements. The compiler enforced
that every switch covered every tag, but nothing enforced that the
switches agreed with one another.

The rules now live in one comptime table in `core/src/schema.zig`, one
row per tag:

```zig
pub const BlockRow = struct {
    tag: BlockTag,
    payload: PayloadKind,   // which side table, or none
    children: ChildRule,    // flow, only: {...}, inline_content, none
};
pub const block_schema = [_]BlockRow{
    .{ .tag = .paragraph, .payload = .none, .children = .inline_content },
    .{ .tag = .list, .payload = .list, .children = .{ .only = &.{.list_item} } },
    // ... one row per tag, checked complete at compile time
};
```

Content kind, placement rules, payload validation, debug names, and the
writer capability checks of Chapter 5 are all derived from this table by
comptime iteration. A property that used to be five agreeing switches is
now one row read five ways. Drift between the rules is no longer
expressible, and a new tag fails compilation everywhere at once until
its row exists.

#callout([Why a table beats discipline], [
  The old switches could not drift in coverage, because Zig demands
  exhaustive switches. They could drift in content: the placement switch
  and the validator could assert different child kinds for one tag, and
  only a test would notice. The table makes that disagreement a type
  error. This is the same trade the whole chapter makes: move a promise
  from review time to compile time.
])

== Storage is private; views are typed

No format library reads those columns directly. The public face of a
node is a tagged union built in `core/src/payload.zig` from the schema
table's payload kinds:

```zig
switch (doc.block(index).content) {
    .heading => |h| // h.level, h.inlines: InlineRange
    .list => |l|    // l.kind, l.start, l.items: BlockRange
    .extension => |x| // x.owner, x.name, x.version, x.fallback
    else => {},
}
```

#api_anchor([`BlockView` / `InlineView`], [
  Tagged-union views over the flat storage, driven by the schema table
  in `core/src/schema.zig`. A new tag cannot be half-added: the compiler
  demands every switch arm, everywhere, at once,
], source: [`core/src/payload.zig`])

This split is the chapter's central trade. Storage is chosen for the
machine: cache-friendly columns, one arena, integer links. Views are
chosen for the person: exhaustive switches, named fields, no way to read
a payload as the wrong type. Neither leaks into the other.

Attributes follow the pattern. A node's `attrs` is an optional index
into an attrs table holding an identifier, classes, and key-value pairs,
with interned keys. Metadata is a small value model: null, bool, int,
float, string, inlines, blocks, list, map. Its maps keep bytewise-sorted
keys, so the manifest encoding is canonical without a sort at write
time. Footnotes are the one deliberate indirection. A `note` inline
carries only a reference. Note bodies are collected separately by the
builder (`declareNote`, then `beginNoteBody` after the main flow),
because every target format renders note bodies out of line.

== Entities and facets

Markdown consumes none of what this section describes, and that is the
point. A DOCX paragraph has a named style. A PDF line has a page and a
position. A spreadsheet cell has coordinates and a formula. Future
writers want that information; the flow representation must not pay for
it. ZDS 0013's answer is stand-off annotation: typed facet rows stored
beside the tree, joined to nodes by identity, ignored freely.

#definition([Entity], [
  A stable logical identity, `EntityId`, shared by a kernel node and its
  facets. Identity is lazy: a node gets an entity the first time a facet
  attaches to it, and never otherwise. The binding lives in a side table
  of (node index, entity) rows, ordered by node, so a document with no
  facets carries no entity storage at all and the 21-byte block row
  never grows.
])

Five facet kinds ship, each an append-only table sorted by entity:

#table(
  columns: (2fr, 5fr),
  table.header([*Facet*], [*Carries*]),
  [`Provenance`],
  [Producing plugin, source member (an archive part, a page label, a
    spine item), byte position, and a confidence grade: DOCX paragraphs
    are facts, PDF paragraphs are projections.],
  [`Style`],
  [Named style, semantic role, language tag, text direction.],
  [`Layout`],
  [Page, slide, or canvas identity plus a box: x, y, width, height, and
    z-order, in EMU with a top-left origin.],
  [`Grid`],
  [Sheet name, row and column, value type, formula source text, the
    cached value as the source spelled it, and merge extents.],
  [`Revision`],
  [Insertions, deletions, comments, and bookmarks, with author and
    timestamp.],
)

#book_figure(
  [Stand-off binding. Two of three nodes carry entities; facet rows
  reference the entities, never the node rows. The first paragraph
  costs nothing.],
  diagram(
    spacing: (11mm, 9mm),
    edge-stroke: 0.8pt + gray,
    node((0, 0), [`paragraph` #linebreak() #figure_note([no entity row])], ..node_style),
    node((1, 0), [`paragraph` #linebreak() #figure_note([entity 17])], ..node_style),
    node((2, 0), [`table_cell` #linebreak() #figure_note([entity 18])], ..node_style),
    node((0.5, 1), [Style #linebreak() #figure_note([17: "Heading 2"])], ..aside_style),
    node((1.5, 1), [Revision #linebreak() #figure_note([17: inserted])], ..aside_style),
    node((2.5, 1), [Grid #linebreak() #figure_note([18: Sheet1 B4])], ..aside_style),
    edge((0.5, 1), (1, 0), "-|>", bend: 10deg),
    edge((1.5, 1), (1, 0), "-|>"),
    edge((2.5, 1), (2, 0), "-|>", bend: -10deg),
  ),
)

One rule keeps the whole arrangement sane, and the validator enforces
its checkable consequences:

#definition([Facet erasure], [
  Erasing every facet table leaves a document that renders meaningfully.
  Facets refine kernel semantics; they never carry primary content. Text
  lives in the text pool, never in a facet. A link target or a list
  structure is never facet-only. This is why the Markdown writer is
  provably untouched by any facet any future reader invents: the kernel
  it reads means the same thing with the facet tables ignored.
])

Layout coordinates deserve their own sentence, because the unit was
chosen by arithmetic rather than taste. Every `Layout` box is stored in
EMU, English Metric Units, 1/914400 of an inch, with a top-left origin.
One point is exactly 12700 EMU. One CSS pixel is exactly 9525. One
millimeter is exactly 36000. DOCX and PPTX geometry is EMU natively, so
office coordinates transfer without rounding, and PDF points round at a
scale of nanometers. A reader normalizes once, at read time, in the one
place that knows its source geometry.

Facets survive filtering. The rebuild transform of Chapter 7 records
which node ranges it copied, rebases the entity bindings across those
ranges in one ordered merge, and hands the new snapshot its own slice
of binding rows. A node that a filter drops takes its bindings with it,
and its facets become unreachable, exactly as a dropped paragraph's
prose does. This is Lemma 2 of ZDS 0013, running as code.

== The resource store

Extracted binary content generalizes the same way. When a reader pulls
image bytes out of an archive or a PDF stream, it registers them in the
resource store: source name, MIME type, the bytes in a binary pool, and
a BLAKE3 digest computed once at registration. On path output the engine
writes each resource into a `_media` directory beside the artifact,
rewrites matching image URLs, and lists every file with its digest in
the manifest, reusing the digest it already has. Stream output extracts
nothing and keeps source URLs, so piping stays pure.

== The validator

Everything above is an invariant that something else depends on. The
validator in `core/src/ast.zig` proves all of it, with fixed-size
explicit stacks and no recursion:

#table(
  columns: (auto, 1fr),
  table.header([*No.*], [*Invariant (abridged; the code is the
    record)*]),
  [1], [Every `subtree_len` is at least 1, and subtrees nest exactly:
    children tile their parent's extent with no gap and no overlap.],
  [2], [Structural tags appear only under their governing parent:
    `table_row` under a table section, `list_item` under `list`, and so
    on, exactly as the schema table's placement rules state.],
  [3], [Leaf blocks own disjoint, in-bounds inline ranges. Container
    blocks own none.],
  [4], [Every payload index is in bounds for its tag's side table, and
    payload values are legal: heading levels 1 to 6, sane spans, and so
    on.],
  [5], [Inline containers that must hold children do. `text` nodes are
    non-empty and never adjacent to another `text`.],
  [6], [Whitespace appears only as `space`, `soft_break`, or
    `hard_break` nodes, never inside `text`.],
  [7], [Attribute rows are in bounds, and interned strings resolve.],
  [8], [Note references point at declared notes, and every declared
    note has exactly one body.],
  [9], [Metadata maps keep bytewise-sorted, unique keys.],
  [10], [Ranges into the text pool are in bounds, and the whole pool is
    valid UTF-8.],
  [11], [Nesting depth stays within the configured `max_depth`.],
  [12], [An `extension` has a non-empty fallback, and no extension nests
    inside an open extension of the same owner.],
  [13], [A snapshot's entity rows are in bounds and strictly increasing
    by node index, which makes the binding injective for free.],
  [14], [Facet tables are sorted by entity, single-valued kinds hold one
    row per entity, and every facet string range lands inside the text
    pool.],
)

The validator runs after every reader, and again after every filter
stage. That placement is the architecture's honesty mechanism. A reader
bug cannot smuggle an impossible tree into the writer. A filter bug is
caught at the stage that introduced it, not three stages later. When the
validator rejects, the conversion fails with
`core.invalid-document-tree`, and the report names the plugin at fault.
The tree is evidence, and the report says whose.

#definition([Side table], [
  An append-only array in the `Store` holding one payload family:
  targets, list properties, facets, resources, and so on. Node columns
  index into it. Rebuilds share it. Indices are stable for the life of
  the conversion.
])

#warning([The pool invariant bites], [
  While the media pipeline was built, image bytes were first appended to
  the text pool. Invariant 10 failed the whole conversion, exactly as
  designed. Binary content now has its own resource pool. When the
  validator stops you, the correct response is rarely to weaken the
  invariant.
])

#teach_back([
  Using only the worked-example tables, explain to a colleague how to
  find the second list item without visiting the first item's children,
  and how to find the text of the link. Then explain why a spreadsheet
  cell's formula lives in a facet rather than in the cell's payload, and
  what the Markdown writer has to do about that facet. The correct
  answer to the last part is one word.
])

#exercise([2.1], [
  Write the block table (tags and `subtree_len`) for a block quote
  containing one line, followed by a thematic break, followed by one
  paragraph. Check your `subtree_len` values by verifying the sibling
  hop lands on each top-level block.
], hint: [Does a lone line inside a quote produce `paragraph` or
  `plain`? Convert one and count.])

#exercise([2.2], [
  The inline row is 13 bytes and the block row is 21. Estimate the node
  storage for a 1,000-page report, and compare it with the size of the
  DOCX it came from. What dominates the arena in practice?
], hint: [The text pool holds the prose exactly once.])

#exercise([2.3], [
  Invariant 5 forbids adjacent `text` siblings. Find the builder feature
  (Chapter 3) that makes it impossible for a well-behaved reader to
  violate this, even when the reader appends text one character at a
  time.
])

#exercise([2.4], [
  Convert a spreadsheet with `--preserve-facets` and read the `facets`
  object in the manifest. For one grid row, verify by hand that the
  `entity` it names resolves to a `table_cell` holding the cached value
  as its text.
], hint: [Chapter 7 documents the manifest layout; the rows are sorted
  by entity.])
