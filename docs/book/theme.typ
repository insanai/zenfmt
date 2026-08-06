// Book theme for the zenfmt manual: the page frame, the cover, the
// callouts, and the exercise and figure helpers. Everything here is
// parameterized; nothing names a specific book.

#import "@preview/cetz:0.5.2" as cetz

#let ink = rgb("172033")
#let blue = rgb("2855a6")
#let blue_light = rgb("eaf0fb")
#let green = rgb("27734d")
#let green_light = rgb("eaf7f0")
#let amber = rgb("9a6200")
#let amber_light = rgb("fff5dc")
#let red = rgb("9f3030")
#let red_light = rgb("fcecec")
#let gray = rgb("667085")
#let rule = rgb("d4d9e2")

/// The document frame: page geometry, running head, type, and heading styles.
///
/// `running_head` is the short title printed on the left of every page after
/// the first; the chapter title is printed on the right.
#let book(
  body,
  title: "Untitled",
  authors: (),
  keywords: (),
  running_head: none,
) = {
  let head = if running_head == none { title } else { running_head }
  set document(
    title: title,
    author: authors,
    keywords: keywords,
  )
  set page(
    paper: "a4",
    margin: (inside: 25mm, outside: 20mm, top: 22mm, bottom: 24mm),
    numbering: "1",
    number-align: center,
    header: context {
      if counter(page).get().first() > 1 {
        set text(size: 8pt, fill: gray)
        let headings = query(heading.where(level: 1).before(here()))
        let chapter = if headings.len() > 0 { headings.last().body } else { [] }
        grid(
          columns: (1fr, 1fr),
          box(width: 100%, clip: true)[#head],
          box(width: 100%, clip: true, align(right, emph(chapter))),
        )
        line(length: 100%, stroke: 0.4pt + rule)
      }
    },
  )
  set text(font: "New Computer Modern", size: 10.3pt, fill: ink, lang: "en")
  set smartquote(enabled: false)
  set par(justify: true, leading: 0.74em, spacing: 0.72em)
  set heading(numbering: "1.1")
  set raw(tab-size: 4)
  show raw: set text(size: 8.3pt)
  show raw.where(block: false): it => box(
    fill: rgb("eef1f6"),
    inset: (x: 2.5pt, y: 0pt),
    outset: (y: 2.5pt),
    radius: 2pt,
    it,
  )
  show raw.where(block: true): it => block(
    width: 100%,
    fill: rgb("f7f9fc"),
    stroke: (left: 2pt + rule),
    inset: 9pt,
    radius: 3pt,
    it,
  )
  set table(
    stroke: 0.45pt + rule,
    inset: 6pt,
    fill: (x, y) => if y == 0 { rgb("eef1f6") } else if calc.even(y) { rgb("fafbfd") },
  )
  show figure.caption: set text(size: 9pt, fill: gray)
  show link: set text(fill: blue)
  show heading.where(level: 1): heading => {
    pagebreak(weak: true)
    block(above: 4mm, below: 6mm)[
      #text(size: 22pt, weight: "bold", fill: ink)[#heading]
      #line(length: 38mm, stroke: 1.5pt + blue)
    ]
  }
  show heading.where(level: 2): set text(size: 15pt, fill: ink)
  show heading.where(level: 3): set text(size: 12pt, fill: blue)
  body
}

/// A restrained cover. `mark` is optional cover art, drawn between the
/// subtitle and the epigraph block; pass a `cetz.canvas` or any content.
#let title_page(
  title: "Untitled",
  subtitle: none,
  eyebrow: none,
  edition: none,
  authors: (),
  mark: none,
  epigraph: none,
  epigraph_label: none,
) = {
  let cover_ink = rgb("233149")
  let cover_muted = rgb("626b77")
  let cover_gold = rgb("a98337")
  let cover_rule = rgb("d8d3c9")
  let cover_paper = rgb("fdfcf9")

  set page(
    margin: (x: 23mm, top: 18mm, bottom: 19mm),
    header: none,
    numbering: none,
    background: rect(width: 100%, height: 100%, fill: cover_paper),
  )

  if eyebrow != none {
    grid(
      columns: (1fr, auto),
      text(size: 7.5pt, weight: "bold", tracking: 1.25pt, fill: cover_gold)[
        #upper(eyebrow)
      ],
      if edition == none { [] } else {
        text(size: 7.5pt, tracking: 0.8pt, fill: cover_muted)[#upper(edition)]
      },
    )
  }

  v(15mm)
  text(size: 40pt, weight: "bold", fill: cover_ink)[#title]
  if subtitle != none {
    v(5mm)
    text(size: 12pt, fill: cover_muted)[#subtitle]
  }
  v(7mm)
  line(length: 28mm, stroke: 1.4pt + cover_gold)

  if mark != none {
    v(12mm)
    align(center)[#mark]
  }

  if epigraph != none {
    v(12mm)
    box(
      width: 100%,
      inset: (x: 14pt, y: 11pt),
      radius: 7pt,
      fill: rgb("f4f2ec"),
      stroke: 0.6pt + cover_rule,
    )[
      #if epigraph_label != none [
        #text(size: 7pt, weight: "bold", tracking: 1pt, fill: cover_gold)[
          #upper(epigraph_label)
        ]
        #v(3pt)
      ]
      #text(size: 10.5pt, fill: cover_ink)[#epigraph]
    ]
  }

  v(1fr)
  grid(
    columns: (1fr, auto),
    align: (left, right),
    text(size: 10pt, weight: "bold", fill: cover_ink)[#authors.join(", ")],
    if edition == none { [] } else {
      text(size: 7.8pt, fill: cover_muted)[#edition]
    },
  )
  pagebreak()
}

#let part_page(number, title, summary) = {
  set page(header: none)
  pagebreak(weak: true)
  align(center + horizon)[
    #text(size: 11pt, tracking: 1.6pt, fill: blue)[PART #number]
    #v(5mm)
    #text(size: 28pt, weight: "bold")[#title]
    #v(7mm)
    #line(length: 34mm, stroke: 1.5pt + blue)
    #v(7mm)
    #box(width: 72%, text(size: 10.5pt, fill: gray)[#summary])
  ]
  pagebreak()
}

#let callout(title, body, kind: "note") = {
  let colors = if kind == "warning" {
    (red, red_light)
  } else if kind == "idea" {
    (green, green_light)
  } else {
    (blue, blue_light)
  }
  block(
    width: 100%,
    inset: 10pt,
    outset: (y: 3pt),
    radius: 3pt,
    fill: colors.at(1),
    stroke: (left: 2pt + colors.at(0)),
  )[
    #box(
      width: 6.5pt,
      height: 6.5pt,
      fill: colors.at(0),
      radius: 1.5pt,
      baseline: 0.2pt,
    )
    #h(1pt)
    #text(weight: "bold", fill: colors.at(0))[#title]
    #h(5pt)
    #body
  ]
}

#let definition(term, body) = callout(term, body, kind: "idea")

#let warning(title, body) = callout(title, body, kind: "warning")

#let book_quote(body, attribution) = block(
  width: 88%,
  inset: (left: 12pt, right: 8pt, y: 7pt),
  outset: (y: 4pt),
  stroke: (left: 1.2pt + blue),
)[
  #grid(
    columns: (auto, 1fr),
    column-gutter: 7pt,
    text(size: 24pt, fill: rule, font: "New Computer Modern", baseline: 6pt)["],
    emph(body),
  )
  #align(right, text(size: 9pt, fill: gray)[#text("- ")#attribution])
]

#let exercise(number, body, hint: none) = block(
  width: 100%,
  inset: 9pt,
  outset: (y: 3pt),
  radius: 3pt,
  fill: amber_light,
  stroke: 0.6pt + amber,
)[
  #text(weight: "bold", fill: amber)[Exercise #number.]
  #h(4pt)
  #body
  #if hint != none [
    #linebreak()
    #text(size: 9pt, fill: gray)[Hint: #hint]
  ]
]

#let transcript(rows) = table(
  columns: (auto, auto, 1fr),
  align: (right, left, left),
  table.header(
    [*Step*], [*Actor*], [*Event and reason*],
  ),
  ..rows,
)

#let objectives(body) = callout([Learning contract], body, kind: "idea")

#let checkpoint(title, body) = callout([Checkpoint: #title], body)

#let predict(body) = callout([Predict before reading on], body, kind: "warning")

#let teach_back(body) = block(
  width: 100%,
  inset: 9pt,
  outset: (y: 3pt),
  radius: 3pt,
  fill: blue_light,
  stroke: 0.6pt + blue,
)[
  #text(weight: "bold", fill: blue)[Teach it back.]
  #h(4pt)
  #body
]

#let api_anchor(symbol, purpose, source: none) = {
  let location = if source == none { [] } else { [ in #source] }
  callout([API anchor: #symbol], [#purpose#location])
}

#let code_file(path, body) = block(
  width: 100%,
  inset: 0pt,
  outset: (y: 4pt),
  stroke: 0.6pt + rule,
  radius: 3pt,
)[
  #block(width: 100%, inset: 6pt, fill: blue_light)[
    #text(size: 8pt, weight: "bold", fill: blue)[#path]
  ]
  #block(width: 100%, inset: 8pt)[#body]
]

#let book_figure(caption, body) = figure(
  placement: auto,
  body,
  caption: text(size: 9pt, fill: gray)[#caption],
)
