#import "theme.typ": *
#import "figures.typ": *

= The One Writer

#objectives([
  By the end of this chapter you should be able to state the writer's
  determinism rules from memory and predict which characters get escaped
  at a given position. You should be able to explain how a trailing space
  escapes a bold span without breaking CommonMark, read the writer's
  capability declaration and price a document's losses from the rule
  table, choose the right `--strict` grade for a job, and prove, with
  two commands, that Markdown round-trips to a fixed point.
])

zenfmt ships nineteen readers and exactly one writer. The asymmetry is
deliberate. An intermediate representation is easiest to judge when many
producers feed a single consumer. Every reader bug, every mapping
decision, every canonicalization rule surfaces as a diff in the same
Markdown. The day a second writer lands, it inherits an AST that nineteen
formats have already argued into shape.

#checkpoint([the contract], [
  The writer receives a validated tree. The invariants of chapter 2 hold
  before `write` is called. The writer never defends against an
  impossible tree. It renders the possible ones deterministically.
])

== Determinism first

Two conversions of the same input must be byte-identical, on every
machine, forever. The manifest digests of chapter 7 depend on it. The
rules are few and absolute:

- Line endings are `\n`, only.
- Exactly one blank line between blocks. Exactly one `\n` at end of file.
- No trailing whitespace on any line.
- Equal formatting renders equally. The canonical inline order of
  chapter 4 means the writer never chooses between `**_x_**` and
  `_**x**_`. The tree already decided.

#definition([Determinism], [
  The output is a pure function of the document tree. No timestamps, no
  locale, no hash-map iteration order, no "usually the same". This is
  what makes output diffable and the round-trip test meaningful.
])

== Escaping by position

A naive writer escapes every Markdown metacharacter and produces
backslash soup. This writer asks where the character sits, because most
metacharacters are only meta somewhere.

#book_figure(
  [The position-aware escaping rules. A character is escaped only where
  CommonMark would actually reinterpret it.],
  table(
    columns: (auto, 1fr),
    table.header([*Character*], [*Escaped when*]),
    [`# > - + =`], [it is the first non-space character of a line],
    [digits], [a digit run at line start would open an ordered list; the
      writer looks ahead for the `.` or `)` before deciding],
    [`* _`], [a delimiter run here could open or close emphasis],
    [#raw("`")], [always; code spans are too cheap to trigger],
    [`[ ]`], [always; brackets are link syntax anywhere],
    [`&`], [only when the following text looks like an entity, such as
      `&name;` or `&#10;`. Plain `AT&T` passes clean.],
    [`\ < |`], [backslash always; `<` where HTML could start; `|` inside
      table cells],
  ),
)

The `&` rule is the one that pays for itself. Escaping every ampersand
turns ordinary prose ugly. So the writer scans forward for the shape of a
character reference and escapes only genuine look-alikes.

== The edge-space problem

Word processors love styled runs with edge spaces. A DOCX or RTF run
often holds bold text with a trailing space inside the bold. Rendered
naively, that is `**bold **`. CommonMark rejects it: a closing `**`
cannot follow whitespace. The whole span would silently stop being bold.

The writer relocates edge spaces outside the delimiters as it closes each
styled span. It also drops span pairs that end up empty. Here is a real
transcript. The RTF run has a trailing space inside `\b`:

```
$ printf '{\\rtf1\\ansi Plain {\\b bold }after.\\par}' > edge.rtf
$ zenfmt edge.rtf --stdout --quiet
Plain **bold** after.
```

The space moved from inside the bold to between the words. The output is
valid CommonMark and reads identically.

#predict([
  A DOCX run is bold and contains only spaces. What should the writer
  emit? Decide, then check: the empty-pair rule drops the delimiters and
  keeps the spaces. The sequence `** **` appears in no zenfmt output.
])

== Lists: tight, loose, and the prefix machine

A Markdown list is tight when no blank lines separate its items. The
distinction changes rendering in every downstream tool: compact items
versus a paragraph per item. The writer computes tightness from the tree
and holds it per list frame. A nested list inside a tight list therefore
does not force blank lines into its parent.

Continuation lines take a prefix as wide as their marker. This is real
output. Note the three-space continuation under the ordered marker, and
the absence of blank lines in the tight structure:

```
1. one
   - deep bullet
2. two
```

The mechanics are one machine. Every open container contributes to a
prefix stack. Markers are pending: written once, on the first line of
their item. Blank lines between blocks print the prefix with no marker.
Getting `2.` to line up under `1.` is exactly this machine and nothing
else.

== Tables, aligned

GFM tables render with padded columns:

```
| ID  | Months   |
| --- | -------- |
| 1   | January  |
| 2   | February |
```

Padding means measuring every cell before writing the first row. That
extra pass has a price, and the benchmark chapter states it honestly. The
25,000-row CSV corpus file is zenfmt's slowest conversion. It is also the
one file where anydoc, which emits ragged unpadded pipes, is faster. The
scaling is linear: twice the rows costs twice the time. The padded table
is a deliberate quality purchase. It is diffable, readable in a
terminal, and stable under regeneration.

Cell content that Markdown cannot hold degrades with a name. Block
content flattens (`markdown.table-cell-flattened`). Row and column spans
degrade (`markdown.cell-span-degraded`). A nested table is dropped with
`markdown.nested-table-dropped`.

== Code and raw content

Code blocks fence with backticks and carry their language string
unchanged, so syntax highlighting survives the trip. A code block whose
content contains a backtick run gets a longer fence. Inline code picks
its span delimiters the same way, and pads with spaces when the content
starts or ends with a backtick. This is the CommonMark dance, done once,
in the writer, so no reader thinks about it.

Raw content is stricter. The AST can carry raw fragments tagged with
their format, an HTML island from the HTML reader, for example. The
writer emits raw content only when its tag says `markdown` or `html`,
the two formats a Markdown file can host. Every other raw fragment is
dropped with `markdown.raw-dropped`, because emitting LaTeX into a
Markdown file does not become correct by hoping.

== Footnotes, deferred

Note references render as `[^1]` in reading order. Bodies collect and
render at the end of the document as `[^1]:` definitions. The AST made
this cheap. Readers declare notes and supply bodies whenever their format
happens to store them: inline for ODT and RTF, in a separate part for
DOCX. The tree always carries them deferred. What Markdown cannot express
at all, `underline` and `small_caps`, renders as its plain content with
one aggregated `markdown.style-dropped` note.

== What the writer declares

Until ZDS 0013 the writer's losses were correct but implicit: the
underline rule lived in one function, the nested-table rule in another,
and only the code said which constructs degrade. The writer now states
its position once, at compile time, in
`formats/markdown/src/capabilities.zig`:

```zig
pub const capabilities: lowering.Capabilities = .{
    .exact_blocks = &.{ .plain, .paragraph, .heading, .quote, ... },
    .lowered_blocks = &.{ .raw_block, .table, .definition_list, ... },
    .exact_inlines = &.{ .text, .emphasis, .strong, .link, ... },
    .lowered_inlines = &.{ .underline, .small_caps, .raw, ... },
    .rules = &rules,   // the priced degradations below
};
```

The declaration is total, and totality is checked where lies are
cheapest to catch. Every kernel tag must appear in exactly one of
exact, lowered, or refused, or the bundle does not compile. When a new
tag joins the schema table of Chapter 2, this file refuses to build
until the writer decides what it will do about it. The mapping-table
obligation that ZDS 0001 places on readers now has its mirror on the
writer side.

== Pricing the losses

Each degradation is a rule with a stable name, a diagnostic, and a cost
on the loss vector of ZDS 0013: component one counts dropped content,
component two structural degradation, component three style and
metadata loss. The ten rules:

#table(
  columns: (2fr, 1.4fr, 2.6fr),
  table.header([*Rule*], [*Costs*], [*Report code*]),
  [`raw-dropped`], [content], [`markdown.raw-dropped`],
  [`nested-table`], [content], [`markdown.nested-table-dropped`],
  [`cell-flattened`], [structure], [`markdown.table-cell-flattened`],
  [`cell-span`], [structure], [`markdown.cell-span-degraded`],
  [`definition-list`], [structure], [`markdown.definition-list-degraded`],
  [`style-dropped`], [style], [`markdown.style-dropped`],
  [`extension-fallback`], [style], [`markdown.extension-fallback`],
  [`citation-dropped`], [style], [`markdown.citation-dropped`],
  [`number-style`], [style], [`markdown.list-number-style-degraded`],
  [`container-attrs`], [style], [`markdown.container-attributes-dropped`],
)

The rendering code did not move. Where the writer used to report a loss
directly, it now records a hit against the rule, and the engine's plan
accumulator prices the hits and flushes one aggregated report per fired
rule, in first-hit order, with the count. The refactor was verified
byte-for-byte: same artifacts, same reports, same manifests, across the
whole benchmark corpus. What changed is that the losses now have prices
the engine can act on before writing anything.

#definition([Loss taxonomy], [
  ZDS 0013 names five outcomes for any construct: equality,
  normalization (equal meaning, canonical spelling), degradation (some
  meaning lost, priced and reported), omission (a subtree dropped), and
  refusal (no output at all). Every rule above is a priced degradation
  or omission. Nothing is lost silently, and nothing lost is called
  equal.
])

== Strict, in three grades

The prices exist so refusal can be a policy instead of a feeling.
`--strict` gates the conversion on the aggregated cost, in three
grades:

#table(
  columns: (2fr, 3fr),
  table.header([*Flag*], [*Refuses when*]),
  [`--strict` or `--strict=content`],
  [Any semantic content would drop: raw fragments, nested tables, or a
    reader-side dropped construct.],
  [`--strict=structure`],
  [Content loss, or structural degradation: flattened cells, degraded
    spans, definition lists.],
  [`--strict=exact`],
  [Any degradation at all. The plan must be pure exact emission.],
)

The gate runs before emission. The engine performs a dry run into a
discarding writer, prices the plan it would select, adds the losses the
reader already reported, and tests the grade. A refused conversion
emits `core.strict-refused` and commits nothing: no artifact, no
manifest, not a byte on a stream. A writer may also refuse a construct
in every mode by listing it in its capabilities; the engine then fails
the conversion with `core.construct-refused` before planning at all.
Markdown refuses nothing, degrades much, and prices everything, which
is the honest posture for a plain-text target.

== The reader: the writer's sparring partner

The Markdown reader exists first of all to close the loop. It was the
phase-2 proof that a second reader needs no engine changes. It is also
the instrument that makes round-trip testing possible. It is a full
CommonMark plus GFM implementation in two passes. No recursion. No
regex.

*Block pass.* A line-at-a-time machine matches each line against the open
container stack: quotes, lists, footnote definitions. Then it opens what
the remainder starts: headings, fences, tables, paragraphs. Two rules do
the heavy lifting.

- Lazy continuation. A paragraph line may omit its containers' markers,
  unless the line would instead start a new construct. The interruption
  rule has one subtlety worth naming. The line `2. four` after
  `1. three` continues the open list. It does not lazily join the
  paragraph, because a matching open list claims its own continuation.
- Structural closes. Eight block starts close an open list rather than
  nest inside its last item: quotes, fences, headings, thematic breaks,
  tables, HTML, and reference definitions. Lists end where a human says
  they end.

*Inline pass.* Emphasis is the delimiter-stack algorithm from the
CommonMark spec. Text becomes a doubly-linked list of nodes. Delimiter
runs of `*`, `_`, or `~~` join a chain marked can-open and can-close.
The processor repeatedly matches the closest closer to its nearest
opener.

#definition([The rule of three], [
  Suppose a delimiter run can both open and close. It may match a run
  only if the combined length of the two runs is not a multiple of
  three, or both runs are themselves multiples of three. This single
  rule is why `a**"foo"**` bolds and `**foo*` does not. It is also why
  implementing emphasis by counting asterisks always fails.
])

Code spans resolve before emphasis and hide their contents from it.
Brackets resolve after, against inline targets or the reference
definitions the block pass collected. Labels are case-folded and
whitespace-normalized before lookup.

== The fixed point

Everything above compounds into one testable property. Converting
Markdown to Markdown reaches a fixed point after at most one pass. The
first pass may canonicalize: setext headings become ATX, `*em*` becomes
`_em_`, spacing normalizes. The second pass must be byte-identical to the
first, forever after.

```
$ zenfmt rt.md --stdout --quiet --from markdown > rt1.md
$ zenfmt rt1.md --stdout --quiet --from markdown > rt2.md
$ cmp rt1.md rt2.md && echo FIXED-POINT
FIXED-POINT
```

The round-trip suite pins this for headings, emphasis, lists, tables,
code, links, and footnotes. The fuzzer feeds the reader garbage with the
validator as oracle. When a future change breaks either canonicalization
or parsing, this is the test that names it.

#teach_back([
  Explain why `**bold **text` is not valid CommonMark emphasis, what the
  writer does about it, and why the fix belongs in the writer rather
  than in every reader that produces edge spaces.
])

#exercise([5.1], [
  Predict the output of converting this Markdown to Markdown, then run
  it: `Heading\n=======\n\nA *b* c** d.` Which characters changed, and
  which escaping rule fired on `**`?
], hint: [Setext becomes ATX. An unmatched delimiter run is plain text,
  but only until something could match it.])

#exercise([5.2], [
  Find `appendClose` in `formats/markdown/src/writer.zig` and list the
  transformations it applies when closing a styled span. Match each to a
  sentence in this chapter.
])
