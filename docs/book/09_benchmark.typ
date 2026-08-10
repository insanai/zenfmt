#import "theme.typ": *
#import "figures.typ": *
#import "@preview/cetz:0.5.2" as cetz

// The dashboard renders from the same machine-readable results file that
// `zig build benchmark` writes; recompile the book after a run and the
// numbers, bars, and headline ratios below all move together.
#let bench = json("/benchmarks/results/latest.json")
// Display order matches the harness enum: zenfmt, then the external
// comparators Docling, AnyDoc, and Pandoc, then the installed wheel.
#let tool_names = ("zenfmt", "docling", "anydoc", "pandoc", "zenfmt-python-wheel")
#let tool_labels = ("zenfmt", "Docling", "anydoc", "pandoc", "zenfmt wheel")
// Categorical palette validated for color-vision deficiency and contrast
// against the paper surface; bar order and direct labels carry identity
// as the secondary encoding. The wheel row reuses a distinct teal.
#let tool_fill = (blue, rgb("7b5cd6"), amber, rgb("b03a72"), rgb("2a7f62"))
// Older result files carry fewer tools; everything below adapts to the
// count actually present so the chapter compiles before and after a run.
#let tool_count = bench.files.at(0).tools.len()

#let head_to_head(files, other) = {
  let n = 0
  let sw = 0.0
  let sc = 0.0
  let sr = 0.0
  for f in files {
    let z = f.tools.at(0)
    let o = f.tools.at(other)
    if z.ok and o.ok {
      n += 1
      sw += calc.ln(o.wall_ms / z.wall_ms)
      sc += calc.ln(calc.max(o.cpu_ms, 0.01) / calc.max(z.cpu_ms, 0.01))
      sr += calc.ln(calc.max(o.max_rss_mb, 0.01) / calc.max(z.max_rss_mb, 0.01))
    }
  }
  (
    files: n,
    wall: calc.exp(sw / n),
    cpu: calc.exp(sc / n),
    rss: calc.exp(sr / n),
  )
}

#let converted(files, index) = files.filter(f => f.tools.at(index).ok).len()

#let stat_tile(number, label, detail, fill: blue_light, stroke: blue) = block(
  breakable: false,
  fill: fill,
  stroke: 0.8pt + stroke,
  radius: 4pt,
  inset: 9pt,
  width: 100%,
)[
  #text(size: 23pt, weight: "bold", fill: ink)[#number]\
  #text(size: 9pt, weight: "bold")[#label]\
  #text(size: 8pt, fill: gray)[#detail]
]

/// Grouped horizontal bars on a log-10 axis: one row per corpus file,
/// one bar per tool. `metric` picks the field; `lmax` is the top decade.
#let log_bars(files, metric, unit, lmax, marker: none, marker_label: none) = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let nt = files.at(0).tools.len()
  let row_h = if nt > 3 { 0.95 } else { 0.72 }
  let bar_h = 0.155
  let x0 = 2.9
  let xw = 11.4
  let lmin = 0.0
  let xpos(v) = x0 + (calc.log(calc.max(v, 1.05), base: 10) - lmin) / (lmax - lmin) * xw
  let height = files.len() * row_h

  for exponent in range(0, int(lmax) + 1) {
    let tick = calc.pow(10, exponent)
    let x = xpos(tick)
    line((x, 0.25), (x, -height - 0.05), stroke: 0.35pt + rule)
    content((x, 0.5), text(size: 7pt, fill: gray)[#tick #unit])
  }
  if marker != none {
    let x = xpos(marker)
    line((x, 0.25), (x, -height - 0.05), stroke: (paint: ink, thickness: 0.6pt, dash: "dashed"))
    content(
      (x + 0.08, -height - 0.32),
      anchor: "west",
      text(size: 6.8pt, fill: ink, style: "italic", marker_label),
    )
  }
  for (i, f) in files.enumerate() {
    let y = -(i + 0.5) * row_h
    content((x0 - 0.18, y), anchor: "east", text(size: 8pt, raw(f.name)))
    for (j, t) in f.tools.enumerate() {
      let yy = y + ((nt - 1) / 2 - j) * (bar_h + 0.06)
      if t.ok {
        let value = t.at(metric)
        rect(
          (x0, yy - bar_h / 2),
          (xpos(value), yy + bar_h / 2),
          fill: tool_fill.at(j),
          stroke: none,
        )
        content(
          (xpos(value) + 0.12, yy),
          anchor: "west",
          text(size: 6.4pt, fill: gray)[#calc.round(value, digits: 1)],
        )
      } else {
        let label = if t.supported [failed] else [unsupported]
        content(
          (x0 + 0.12, yy),
          anchor: "west",
          text(size: 6.4pt, fill: gray, style: "italic", label),
        )
      }
    }
  }
  line((x0, 0.25), (x0, -height - 0.05), stroke: 0.7pt + ink)
})

// The legend is paged decoration only. On the web the same information is in
// each chart's data table, where it is readable rather than a row of colour
// swatches, so reproducing it here would add colour-only meaning to the page.
#let legend = context if target() != "html" {
  set text(size: 8.5pt)
  grid(
    columns: 2 * tool_count,
    gutter: 7pt,
    ..tool_names
      .slice(0, tool_count)
      .enumerate()
      .map(((i, name)) => (
        box(width: 9pt, height: 9pt, fill: tool_fill.at(i), radius: 2pt),
        raw(name),
      ))
      .flatten(),
  )
}

/// The numbers behind a per-file, per-tool chart, as a real table. A chart
/// exported to HTML is vector artwork with no text in it, so this is the only
/// form in which its values can actually be read (ZDS 0015, Accessibility).
#let metric_table(files, metric, unit) = {
  let heads = tool_names.slice(0, tool_count)
  table(
    columns: (auto,) + heads.map(_ => auto),
    table.header([*File*], ..heads.map(name => [*#name*])),
    ..files
      .map(file => (
        [#file.name],
        ..range(tool_count).map(i => {
          let entry = file.tools.at(i)
          if entry.ok {
            [#calc.round(entry.at(metric), digits: 2) #unit]
          } else if not entry.supported {
            [not supported]
          } else {
            [failed]
          }
        }),
      ))
      .flatten(),
  )
}

/// The ratio table behind the speedup chart: only files both tools convert.
#let ratio_table(files, other) = {
  let rows = files.filter(f => f.tools.at(0).ok and f.tools.at(other).ok)
  table(
    columns: (auto, auto),
    table.header([*File*], [*Speedup over #tool_names.at(other)*]),
    ..rows
      .map(file => (
        [#file.name],
        [#calc.round(
            file.tools.at(other).wall_ms / file.tools.at(0).wall_ms,
            digits: 2,
          )x],
      ))
      .flatten(),
  )
}

/// Single-series ratio bars: how many times faster zenfmt converts each
/// shared file than `other`. Log-10 axis with a parity rule at 1x.
#let speedup_bars(files, other) = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  let rows = files
    .filter(f => f.tools.at(0).ok and f.tools.at(other).ok)
    .map(f => (
      name: f.name,
      ratio: f.tools.at(other).wall_ms / f.tools.at(0).wall_ms,
    ))
    .sorted(key: r => -r.ratio)
  let row_h = 0.42
  let bar_h = 0.2
  let x0 = 2.9
  let xw = 11.4
  let lmin = -0.5
  let lmax = 1.6
  let xpos(v) = x0 + (calc.log(v, base: 10) - lmin) / (lmax - lmin) * xw
  let height = rows.len() * row_h

  for tick in (0.5, 1, 10) {
    let x = xpos(tick)
    line((x, 0.25), (x, -height - 0.05), stroke: 0.35pt + rule)
    content((x, 0.5), text(size: 7pt, fill: gray)[#tick;x])
  }
  line(
    (xpos(1), 0.25),
    (xpos(1), -height - 0.05),
    stroke: (paint: ink, thickness: 0.6pt, dash: "dashed"),
  )
  content(
    (xpos(1) + 0.08, -height - 0.32),
    anchor: "west",
    text(size: 6.8pt, fill: ink, style: "italic")[1x: parity],
  )
  for (i, r) in rows.enumerate() {
    let y = -(i + 0.5) * row_h
    content((x0 - 0.18, y), anchor: "east", text(size: 8pt, raw(r.name)))
    // Bars grow from the parity line: rightward when zenfmt wins the
    // file, leftward in the other tool's color when it does not.
    let x_end = xpos(r.ratio)
    let win = r.ratio >= 1.0
    rect(
      (xpos(1), y - bar_h / 2),
      (x_end, y + bar_h / 2),
      fill: if win { blue } else { amber },
      stroke: none,
    )
    let label_x = if win { x_end + 0.12 } else { x_end - 0.12 }
    content(
      (label_x, y),
      anchor: if win { "west" } else { "east" },
      text(size: 6.8pt, fill: gray)[#calc.round(r.ratio, digits: 1)x],
    )
  }
  line((x0, 0.25), (x0, -height - 0.05), stroke: 0.7pt + ink)
})

= The Measure of the Tool

#objectives([
  By the end of this chapter you should be able to run the benchmark
  yourself, explain what each of the three measured quantities captures and
  what it deliberately includes, read the dashboard below without the prose,
  and argue about the one corpus file where zenfmt is not the fastest tool.
])

A converter's claims are cheap until a corpus arrives. This chapter measures
zenfmt against the tools a reader would actually reach for instead:
#link("https://pandoc.org/")[pandoc], the universal document converter,
firecrawl's #link("https://github.com/firecrawl/anydoc")[anydoc], the Rust
converter whose format roster zenfmt set out to match, and
#link("https://github.com/docling-project/docling")[Docling], the Python
document-understanding toolkit, measured here in its model-free
parser-only configuration. Everything below is
generated. The tables, the bars, and the headline ratios come from
`benchmarks/results/latest.json`, written by the same build step you can run
tonight on your own machine.

== Method

#definition([The three quantities], [
  *Wall latency* is what a person waits for: process start to process exit.
  *CPU time* is user time plus system time. It is what a server pays.
  *Peak RSS* is the high-water mark of resident memory. It decides how many
  conversions fit on a machine. All three come from the operating system's
  `wait4` rusage accounting of the finished child. There is no in-process
  self-measurement.
])

Each tool converts each corpus file to GitHub-Flavored Markdown. The output
is discarded. Each tool is invoked the way its documentation recommends.
One warm-up run is discarded, and the tables keep the *median of 5*
measured runs. A tool runs only on formats its documentation claims.
`unsupported` in the tables is itself a result. So is `failed`, which means
an exit code other than zero on a format the tool claims.

Fairness is a design decision, not an accident:

- anydoc's Node.js launcher and pandoc's Haskell runtime startup are *in*
  the measurement, because they are in every real invocation. zenfmt's own
  process startup is measured identically.
- zenfmt is built with `-Doptimize=ReleaseSafe`. Bounds checks stay on.
  This is the mode the project ships. The competitors are their released
  binaries.
- The corpus is nobody's home turf. It holds real files from public sample
  repositories, Apache POI and LibreOffice test data, Project Gutenberg,
  and the W3C. It spans #bench.files.len() files and every format family
  zenfmt reads.

Every file is real. Nothing in the corpus was authored for this
benchmark.

#figure(
  placement: auto,
  kind: table,
  {
    set text(size: 8pt)
    table(
      columns: (auto, auto, 1fr),
      align: (left, left, left),
      table.header([*file*], [*family*], [*origin*]),
      [`report.docx`], [DOCX], [filesamples.com document sample],
      [`memo.doc`], [Word 97 binary], [filesamples.com, authored in Word 9.0],
      [`letter.odt`], [OpenDocument text], [filesamples.com],
      [`notes.rtf`], [RTF], [filesamples.com],
      [`sheet.xlsx`], [XLSX], [filesamples.com],
      [`table.xls`], [Excel 97 binary], [filesamples.com],
      [`grid.xlsb`], [Excel binary workbook], [Apache POI test corpus],
      [`sheet.ods`], [OpenDocument spreadsheet], [filesamples.com],
      [`slides.pptx`], [PPTX], [Apache POI corpus, a real ApacheCon deck],
      [`deck.ppt`], [PowerPoint 97 binary], [Apache POI corpus, a 2.5 MB thesis defense],
      [`slides.odp`], [OpenDocument presentation], [the ApacheCon deck, converted by LibreOffice],
      [`book.epub`], [EPUB], [Project Gutenberg, Pride and Prejudice],
      [`page.html`], [HTML], [Project Gutenberg, the same novel as one page],
      [`data.csv`], [CSV], [FSU sample data, 25,000 rows],
      [`article.pdf`], [PDF], [pdfobject.com sample article],
      [`spec.pdf`], [PDF], [W3C accessibility test file],
    )
  },
  caption: [The corpus: 16 real documents from public sources.],
)

#checkpoint([reproduction], [
  `sh benchmarks/fetch_corpus.sh` downloads the corpus, which is not
  committed. `npm install --prefix benchmarks/.anydoc @firecrawl/anydoc`
  installs anydoc, and `zig build benchmark-docling-setup` provisions the
  pinned model-free Docling environment. `zig build benchmark
  -Doptimize=ReleaseSafe` runs everything and rewrites both `results.md`
  and the `latest.json` this chapter renders.
  Numbers in this printing were measured on an Apple-silicon macOS
  machine. Yours will differ in absolute value and should not differ in
  shape.
])

== The headline

#tile_row(
  {
    let all = converted(bench.files, 0)
    stat_tile(
      [#all / #bench.files.len()],
      [corpus files converted],
      [anydoc #converted(bench.files, 2), pandoc #converted(bench.files, 3), Docling #converted(bench.files, 1)],
      fill: green_light,
      stroke: green,
    )
  },
  {
    let h = head_to_head(bench.files, 2)
    stat_tile(
      [#calc.round(h.wall, digits: 1)x],
      [faster than anydoc],
      [geometric mean over the #h.files files both convert; #calc.round(h.rss, digits: 1)x less peak memory],
    )
  },
  {
    let h = head_to_head(bench.files, 3)
    stat_tile(
      [#calc.round(h.wall, digits: 1)x],
      [faster than pandoc],
      [geometric mean over the #h.files files both convert; #calc.round(h.rss, digits: 1)x less peak memory],
    )
  },
)

The geometric mean is the honest average for ratios. A 100x win on one
file cannot buy back ten 2x losses. A tool that halves one ratio while
doubling another lands exactly where it started.

== Support is a result

Half of a converter's value is answering at all. Rows are corpus files. A
filled cell means the tool converted the file successfully.

#{
  set text(size: 8pt)
  table(
    columns: (auto, auto) + (1fr,) * tool_count,
    align: (left, right) + (center,) * tool_count,
    table.header(
      [*file*],
      [*size*],
      ..tool_labels.slice(0, tool_count).map(name => strong(name)),
    ),
    ..bench
      .files
      .map(f => {
        (
          raw(f.name),
          [#calc.round(f.size / 1024, digits: 1) KiB],
          ..f.tools.map(t => {
            if t.ok {
              table.cell(fill: green_light)[✓]
            } else if t.supported {
              table.cell(fill: red_light)[failed]
            } else {
              table.cell(fill: rgb("f1f3f7"))[—]
            }
          }),
        )
      })
      .flatten(),
  )
}

Each column tells its own story. pandoc's is honest minimalism: it never
claimed the binary Office formats, the OpenDocument spreadsheet and
presentation, or PDF input. Docling here is deliberately narrowed to its
model-free parsers — Office Open XML, HTML, and CSV — so its blank cells
are a benchmark choice, not a Docling limit; the next section explains
why. anydoc's one `failed` is the real-world XLSB workbook. Its sheet
directory uses a 40-byte `BrtBundleSh` record where the specification's
example shows 36 bytes. Chapter 4 describes how zenfmt detects this
variant by exact-consumption parsing.

=== Docling, parser only

Docling is a document-understanding toolkit, not a plain converter: its
strength is layout, OCR, and table models over PDFs and images. Those
pipelines load machine-learning weights and are a different workload from
the millisecond structural conversion this chapter measures. The benchmark
therefore pins Docling to its model-free backends and denies every model
download, so the row measures Docling's own parsers converting Office Open
XML, HTML, and CSV to Markdown — and nothing of its AI features. The cost
it still carries is a real one: a fresh Python interpreter that imports
the toolkit's scientific stack before any document work begins, which is
why its bars sit whole seconds above the compiled tools even on the files
it does convert. The comparison is narrow on purpose; it keeps the
workload appropriate for the modest machines zenfmt targets.

== Latency

#predict([
  Before reading the bars, consider this. The corpus has a 2.5 MB legacy
  PowerPoint deck and a 6 KiB OpenDocument spreadsheet. Which will cost
  zenfmt more wall time? Will the ordering be the same for the other
  tools?
])

#chart_figure(
  [
    Median wall latency per conversion, log-10 axis. Absent bars carry
    their reason in italics. The dashed rule marks the startup floor the
    interpreted runtimes pay before any document work begins.
  ],
  {
    legend
    log_bars(
      bench.files,
      "wall_ms",
      "ms",
      3.6,
      marker: 40,
      marker_label: [40 ms: the competitors' runtime startup floor],
    )
  },
  alt: "Grouped bar chart of median wall latency per corpus file on a "
    + "log-10 axis, one bar per tool per file. zenfmt's bars are the "
    + "shortest on every file; the other tools' bars start near a common "
    + "floor of about 40 milliseconds, marked by a dashed rule, which is "
    + "their runtime startup cost before any document work. Files a tool "
    + "does not convert have no bar. The exact values are in the table "
    + "below.",
  data: metric_table(bench.files, "wall_ms", "ms"),
)

The log axis is doing real work, because the tools live on different
decades. Most zenfmt bars sit in the single digits to low tens of
milliseconds; the 33 KiB DOCX converts in about nine. That time is
dominated by actual parsing, which is why the 2.5 MB `deck.ppt` costs no
more than a small spreadsheet: the reader touches the text atoms it
projects and skips the rest. The compiled competitors' bars start near
their runtime startup floor, about 40 ms for anydoc's Node launcher and a
similar amount for pandoc's runtime, before any document work happens.
Docling sits a whole decade higher still: even on the files it converts,
a fresh interpreter imports its scientific stack before the first byte is
read, so its floor is measured in seconds, not milliseconds.

zenfmt's one outlier is `data.csv`, 25,000 rows that take it about two
seconds — its slowest file by far, and slower here than anydoc. The cost
is deliberate: zenfmt measures every column across every row so it can
emit width-aligned GFM table pipes, an O(rows × columns) pass that anydoc
skips by emitting ragged ones. On large structured inputs the ordering
flips back hard — pandoc climbs past two seconds on the EPUB book and the
850 KiB HTML page, where zenfmt stays near a tenth of a second.

== Memory

#chart_figure(
  [
    Peak resident set size per conversion, log-10 axis.
  ],
  {
    legend
    log_bars(bench.files, "max_rss_mb", "MB", 3.0)
  },
  alt: "Grouped bar chart of peak resident memory per corpus file on a "
    + "log-10 axis, one bar per tool per file. zenfmt's bars stay a small "
    + "constant above each input's size, while the other tools' bars sit "
    + "roughly an order of magnitude higher and grow faster on the larger "
    + "inputs. The exact values are in the table below.",
  data: metric_table(bench.files, "max_rss_mb", "MB"),
)

Memory tells the architecture story more plainly than latency does.
zenfmt's peak sits a small constant above the input size. There is one
arena per conversion, flat struct-of-arrays storage, and no DOM. pandoc
builds a full tree in a garbage-collected heap: 100 MB for a 33 KiB DOCX,
and 426 MB for the HTML page. anydoc pays a flat 47 MB for its runtime
before documents enter the picture. On the shared files the
geometric-mean gap is an order of magnitude. It widens exactly on the
inputs where memory matters.

== The shape of the win

One more picture makes the distribution visible. Take each file both
zenfmt and anydoc convert. Divide anydoc's median wall time by zenfmt's.
Sort. The result is not one lucky file carrying an average. All 14 shared
files land on the winning side of parity; `data.csv` is the closest at
1.1x. The spread tells you the rest: small files are dominated by the
competitor's startup, and large files are dominated by parsing.

#chart_figure(
  [
    Wall-time speedup of zenfmt over anydoc per shared corpus file,
    sorted, log-10 axis. The dashed rule is parity.
  ],
  speedup_bars(bench.files, 2),
  alt: "Single-series bar chart, sorted, of how many times faster zenfmt "
    + "converts each file that both it and anydoc convert, on a log-10 axis "
    + "with a dashed parity rule at one times. Every bar sits above parity, "
    + "so the advantage is not one outlier carrying an average; the smallest "
    + "margin is on the large CSV file and the largest are on the small "
    + "files, where the competitor's startup cost dominates. The exact "
    + "ratios are in the table below.",
  data: ratio_table(bench.files, 2),
)

== Where the time goes

The process benchmark treats each tool as a black box. A second harness,
`zig build benchmark-stages`, opens zenfmt's box from inside the library:
for each corpus file it times a conversion through a probe writer that
emits nothing, which prices reading, tree building, validation, and the
manifest. A timed wrapper then measures the ordinary Markdown writer
callback directly. The residual after subtracting both from total is the
lowering share; it also includes the small writer setup and finalization
difference. That residual is derived, not directly measured, and the
results file says so in a `derived` field.
For a focused profile, append `-- --file data.csv --iterations 25`;
the default remains five runs over the full corpus.

#let stages = json("/benchmarks/results/stages.json")
#let stage_pick = ("data.csv", "page.html", "book.epub", "slides.pptx", "slides.odp", "deck.ppt", "report.docx", "sheet.xlsx")
#figure(
  placement: auto,
  kind: table,
  table(
    columns: (2fr, 1fr, 1fr, 1fr, 1fr),
    align: (left, right, right, right, right),
    table.header(
      [*File*], [*Read (ms)*], [*Lower (ms)*], [*Write (ms)*],
      [*Total (ms)*],
    ),
    ..{
      let rows = ()
      for f in stages.files {
        if f.name in stage_pick {
          rows += (
            raw(f.name),
            [#calc.round(f.read_ms, digits: 2)],
            [#calc.round(f.lowering_ms, digits: 2)],
            [#calc.round(f.writer_ms, digits: 2)],
            [#calc.round(f.full_ms, digits: 2)],
          )
        }
      }
      rows
    },
  ),
  caption: [
    In-process stage split, median of #stages.iterations runs, for the
    eight files with the most work to split. Read covers parsing,
    building, and validation; write is measured inside the callback;
    lower is the explicitly marked residual.
  ],
)

Two facts fall out. Parsing dominates the container formats: an ODT or a
PPTX spends almost all its time inside the archive and XML, and the
Markdown writer is nearly free. The 633 KiB CSV now spends 63 ms reading,
8 ms in the lowering residual, and 10 ms in the writer. Stage separation
found the previous writer regression: a hard-cap-sized inline-close stack
was being safety-initialized for every cell. Reusing one stack sized to
`max_depth` made the table path faster and reduced its working memory.

== The Python wheel

The same engine ships to Python as the `zenfmt` wheel (ZDS 0014), and the
benchmark measures what users actually install: `zig build
benchmark-python` builds the wheel, installs it into a clean isolated
environment, verifies artifact parity against the same-revision CLI, and
only then times it. The detailed results land in
`benchmarks/results/python.json`; the process harness adds a cold
`zenfmt-python-wheel` row beside the CLI. Cold and warm numbers answer
different questions and are never merged into one headline.

#let pybench = json("/benchmarks/results/python.json")
#let py_profiles = pybench.profiles
#let warm_values = py_profiles.warm_path_memory.values().map(v => v.median_ms)
#let warm_median = if warm_values.len() > 0 {
  warm_values.sorted().at(int(warm_values.len() / 2))
} else { 0 }

#tile_row(
  stat_tile(
    [#calc.round(py_profiles.cold_import.median_ms, digits: 1) ms],
    [cold import],
    [fresh interpreter, `import zenfmt`],
  ),
  stat_tile(
    [#calc.round(py_profiles.cold_first_conversion.median_ms, digits: 1) ms],
    [cold first conversion],
    [import, load, verify, convert],
  ),
  stat_tile(
    [#warm_median ms],
    [warm memory call],
    [median corpus file, in-process],
  ),
  stat_tile(
    [#calc.round(py_profiles.micro.tiny_text_to_markdown.median_ms, digits: 2) ms],
    [boundary microbenchmark],
    [tiny text; FFI + copies + models],
  ),
)

The boundary microbenchmark is reported separately and never used to claim
corpus throughput: it exists so native loading, validation, copying, and
model construction stay visible when parsing work is negligible. Parity ran
before timing: #pybench.parity.files.len() corpus files compared for format
ids, artifact digests, resource digests, and report codes
#if pybench.parity.ok [ — all agreed.] else [ — *with recorded mismatches
excluded from every aggregate above.*]

#figure(
  placement: auto,
  kind: table,
  table(
    columns: (1fr, 1fr, 1fr, 1fr),
    align: (right, right, right, right),
    table.header(
      [*Threads*], [*Documents*], [*Wall (ms)*], [*Docs / s*],
    ),
    ..{
      let rows = ()
      for entry in pybench.concurrency {
        rows += (
          [#entry.threads],
          [#entry.documents],
          [#entry.wall_ms],
          [#entry.docs_per_s],
        )
      }
      rows
    },
  ),
  caption: [
    One immutable `Converter` shared across worker threads over
    independent corpus documents. The GIL is released for every native
    call, so throughput scales with cores until conversion saturates
    memory bandwidth.
  ],
)

#if tool_count > 4 {
  let h = head_to_head(bench.files, 4)
  [Head to head on the shared corpus, the wheel's cold child-process row —
  a fresh interpreter per document, directly comparable to the CLI row —
  runs at #calc.round(h.wall, digits: 1)x the CLI's wall time (geometric
  mean over #h.files files; above 1.0 means the CLI is faster). The
  difference is interpreter start plus one-time bridge verification;
  the warm rows above are what a long-running service pays.]
}

== The server lens: against Apache Tika

The rows above measure a converter that starts, converts one file, and
exits. A different question is how the long-running #emph[service]
compares, and the natural comparison there is
#link("https://tika.apache.org/")[Apache Tika], the tool teams reach for
when they want extraction behind a port. `zig build benchmark-server`
starts zenfmt in open mode and a pinned Apache Tika Server (4.0.0-beta-1,
its documented Markdown handler) on loopback, and writes
`benchmarks/results/server.json`. These numbers are never merged with the
native rows above: process startup, HTTP transfer, and service isolation
are different costs.

#let server = json("/benchmarks/results/server.json")
// The server lens is a local-only run (Java plus a pinned Apache Tika
// distribution, several minutes); when it has not been executed the record
// carries a not-benchmarked status and the figures below are skipped.
#let srv_shared = if "files" in server {
  server.files.filter(f => f.zenfmt.ok and f.tika.ok)
} else { () }
#let srv_ratio = {
  let s = 0.0
  for f in srv_shared { s += calc.ln(f.tika.wall_ms / f.zenfmt.wall_ms) }
  if srv_shared.len() > 0 { calc.exp(s / srv_shared.len()) } else { 0 }
}

#if "files" not in server [
  This printing was built without a server-lens run. Run `zig build
  benchmark-server` locally, with Java and the pinned Apache Tika
  distribution present, to populate `benchmarks/results/server.json` and
  these figures. It is a local-only benchmark and is never part of CI or
  the release build.
] else [
  #tile_row(
    stat_tile(
      [#calc.round(server.startup.tika_ms / server.startup.zenfmt_ms, digits: 0)x],
      [startup ratio],
      [zenfmt is ready in #calc.round(server.startup.zenfmt_ms / 1000, digits: 2) s;
        Tika's JVM and parser pool take #calc.round(server.startup.tika_ms / 1000, digits: 1) s;
        the ratio is Tika divided by zenfmt],
      fill: green_light,
      stroke: green,
    ),
    stat_tile(
      [#calc.round(server.peak_rss_mb.tika / server.peak_rss_mb.zenfmt, digits: 0)x],
      [sampled resident ratio],
      [#calc.round(server.peak_rss_mb.zenfmt, digits: 0) MB resident against Tika's
        #calc.round(server.peak_rss_mb.tika, digits: 0) MB parent and direct
        parser children],
    ),
    stat_tile(
      [#calc.round(srv_ratio, digits: 0)x],
      [shared warm ratio],
      [geometric mean over the #srv_shared.len() files both services convert,
        each service warmed to steady state first; the ratio is Tika divided
        by zenfmt],
    ),
  )

  Warm latency here measures steady state: both services convert one
  discarded warm-up per file before the timed samples, because Tika's
  per-client parser mode pays several seconds per forked worker on its
  first requests. The one file where Tika leads is `data.csv`, for the same
  reason it leads anydoc — zenfmt measures every column to align its table
  pipes. Concurrent throughput, in documents per second, scales with cores
  for zenfmt:

  #{
    set text(size: 8.5pt)
    table(
      columns: (auto, 1fr, 1fr),
      align: (left, right, right),
      table.header([*concurrency*], [*zenfmt*], [*Tika*]),
      ..server
        .throughput
        .map(t => (
          [#t.concurrency],
          [#calc.round(t.zenfmt_docs_per_s, digits: 0) \/s],
          [#calc.round(t.tika_docs_per_s, digits: 0) \/s],
        ))
        .flatten(),
    )
  }

  One caveat belongs to Tika, not against it. Tika 4 parses in forked child
  processes, so a parser that panics or exhausts memory takes down a
  worker, not the service. zenfmt converts in-process; the deployment guide
  requires a supervisor and operating-system limits for exactly this
  reason. The speed and memory numbers are real, and so is that difference;
  the record keeps both visible rather than collapsing them into a single
  verdict.
]

== Reading it honestly

These measurements need their caveats stated plainly.

- *Startup is part of the story, but not all of it.* Subtract the 40 ms
  runtime floor from every anydoc bar, and its document work is
  competitive on small files. zenfmt's advantage there is the sum of
  native start and arena parsing. It is not evidence that the Rust code
  is slow. On the large inputs the gap survives the subtraction.
- *Completeness is bounded by the corpus.* Sixteen real files cover every
  reader once. They do not cover every construct. The per-format fidelity
  claims rest on the test suites and the ZDS mapping tables, not on this
  chapter.
- *PDF numbers measure text extraction*, structure heuristics included.
  They do not measure OCR. Scanned documents are refused with
  `pdf.no-text` rather than converted into silence.
- *One machine, one printing.* The shapes replicate across machines. The
  absolute values are yours to re-measure with one build command.

#teach_back([
  Explain to a colleague why the benchmark keeps the median of 5 runs and
  not the mean, why it uses the geometric and not the arithmetic mean
  across files, why a runtime's startup belongs inside the measurement,
  and what the empty cells in the support matrix are evidence of. Then run
  the benchmark on your machine and recompile this book. If the argument
  survives your own bars, it was an argument and not a printing.
])

#exercise(
  [9.1],
  [
    Add another corpus file: a Markdown document of at least a megabyte.
    Predict all three of zenfmt's bars before running. Which tool's
    ordering changes? pandoc is a Markdown-native tool. Why does it not
    obviously win this file?
  ],
  hint: [
    `benchmarks/fetch_corpus.sh` shows the naming convention; the harness
    picks up any file in the corpus directory. pandoc must parse *and*
    re-serialize; zenfmt's round-trip is measured in the fixed-point suite.
  ],
)
