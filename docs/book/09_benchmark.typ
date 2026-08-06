#import "theme.typ": *
#import "figures.typ": *
#import "@preview/cetz:0.5.2" as cetz

// The dashboard renders from the same machine-readable results file that
// `zig build benchmark` writes; recompile the book after a run and the
// numbers, bars, and headline ratios below all move together.
#let bench = json("/benchmarks/results/latest.json")
#let tool_names = ("zenfmt", "pandoc", "anydoc")
// Categorical palette validated for color-vision deficiency and contrast
// against the paper surface; bar order and direct labels carry identity
// as the secondary encoding.
#let tool_fill = (blue, rgb("b03a72"), amber)

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
  let row_h = 0.72
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
      let yy = y + (1 - j) * (bar_h + 0.06)
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

#let legend = {
  set text(size: 8.5pt)
  grid(
    columns: 6,
    gutter: 7pt,
    ..tool_names
      .enumerate()
      .map(((i, name)) => (
        box(width: 9pt, height: 9pt, fill: tool_fill.at(i), radius: 2pt),
        raw(name),
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
zenfmt against the two tools a reader would actually reach for instead:
#link("https://pandoc.org/")[pandoc], the universal document converter, and
firecrawl's #link("https://github.com/firecrawl/anydoc")[anydoc], the Rust
converter whose format roster zenfmt set out to match. Everything below is
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
  installs the competitor. `zig build benchmark -Doptimize=ReleaseSafe`
  runs everything and rewrites both `results.md` and the `latest.json`
  this chapter renders.
  Numbers in this printing were measured on an Apple-silicon macOS
  machine. Yours will differ in absolute value and should not differ in
  shape.
])

== The headline

#block(breakable: false, grid(
  columns: (1fr, 1fr, 1fr),
  gutter: 4mm,
  {
    let all = converted(bench.files, 0)
    stat_tile(
      [#all / #bench.files.len()],
      [corpus files converted],
      [pandoc #converted(bench.files, 1), anydoc #converted(bench.files, 2)],
      fill: green_light,
      stroke: green,
    )
  },
  {
    let h = head_to_head(bench.files, 1)
    stat_tile(
      [#calc.round(h.wall, digits: 1)x],
      [faster than pandoc],
      [geometric mean over the #h.files files both convert; #calc.round(h.rss, digits: 1)x less peak memory],
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
))

The geometric mean is the honest average for ratios. A 100x win on one
file cannot buy back ten 2x losses. A tool that halves one ratio while
doubling another lands exactly where it started.

== Support is a result

Half of a converter's value is answering at all. Rows are corpus files. A
filled cell means the tool converted the file successfully.

#{
  set text(size: 8.5pt)
  table(
    columns: (auto, auto, 1fr, 1fr, 1fr),
    align: (left, right, center, center, center),
    table.header(
      [*file*],
      [*size*],
      [*zenfmt*],
      [*pandoc*],
      [*anydoc*],
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
              table.cell(fill: rgb("f1f3f7"))[not claimed]
            }
          }),
        )
      })
      .flatten(),
  )
}

Two cells deserve their footnotes. pandoc's column is honest minimalism.
It never claimed the binary Office formats, the OpenDocument spreadsheet
and presentation, or PDF input. anydoc's one `failed` is the real-world
XLSB workbook. Its sheet directory uses a 40-byte `BrtBundleSh` record
where the specification's example shows 36 bytes. Chapter 4 describes how
zenfmt detects this variant by exact-consumption parsing.

== Latency

#predict([
  Before reading the bars, consider this. The corpus has a 2.5 MB legacy
  PowerPoint deck and a 6 KiB OpenDocument spreadsheet. Which will cost
  zenfmt more wall time? Will the ordering be the same for the other
  tools?
])

#figure(
  placement: auto,
  kind: image,
  {
    legend
    log_bars(
      bench.files,
      "wall_ms",
      "ms",
      3.6,
      marker: 60,
      marker_label: [60 ms: the competitors' runtime startup floor],
    )
  },
  caption: [
    Median wall latency per conversion, log-10 axis. Absent bars carry
    their reason in italics. The dashed rule marks the startup floor the
    interpreted runtimes pay before any document work begins.
  ],
)

The log axis is doing real work, because the three tools live on
different decades. zenfmt's bars cluster between 3 and 50 milliseconds.
That time is dominated by actual parsing. This is why the 2.5 MB
`deck.ppt` costs no more than a small spreadsheet: the reader touches the
text atoms it projects and skips the rest. The competitors' bars start
near their runtime startup floor, about 60 ms for anydoc's Node launcher
and a similar amount for pandoc's runtime, before any document work
happens. On large inputs with heavy structure, such as the EPUB book and
the 850 KiB HTML page, pandoc climbs past 2 seconds.

One file remains where anydoc genuinely out-runs zenfmt: `data.csv`, with
25,000 rows. zenfmt spends its extra milliseconds measuring every column
so it can emit width-aligned GFM table pipes. anydoc emits ragged ones.
The scaling is linear in rows for both tools. The alignment is a priced
feature, not an accident, and a flag to skip it was judged not worth
having.

== Memory

#figure(
  placement: auto,
  kind: image,
  {
    legend
    log_bars(bench.files, "max_rss_mb", "MB", 3.0)
  },
  caption: [
    Peak resident set size per conversion, log-10 axis.
  ],
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
Sort. The result is not one lucky file carrying an average. Thirteen of
the 14 shared files land on the winning side of parity. The one that
does not is `data.csv`, the price of column alignment, in its own color
on the losing side. The spread tells you the rest: small files are
dominated by the competitor's startup, and large files are dominated by
parsing.

#figure(
  placement: auto,
  kind: image,
  speedup_bars(bench.files, 2),
  caption: [
    Wall-time speedup of zenfmt over anydoc per shared corpus file,
    sorted, log-10 axis. The dashed rule is parity.
  ],
)

== Reading it honestly

A benchmark this favorable deserves its caveats stated plainly.

- *Startup is part of the story, but not all of it.* Subtract the 60 ms
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
