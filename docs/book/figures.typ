// Reusable figure helpers for the zenfmt book.
//
// The book's own figures are written here as the chapters need them. What is
// kept is the shared vocabulary: a node style, a pipeline builder, and a
// stacked-array picture, all of which the converter's chapters will want more
// than once.

#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "@preview/cetz:0.5.2" as cetz
#import "theme.typ": blue, blue_light, green, green_light, amber, amber_light, red, gray, rule

#let node_style = (
  fill: blue_light,
  stroke: 0.8pt + blue,
  corner-radius: 3pt,
  inset: 7pt,
)

#let accent_style = (
  fill: green_light,
  stroke: 0.8pt + green,
  corner-radius: 3pt,
  inset: 7pt,
)

#let aside_style = (
  fill: amber_light,
  stroke: 0.8pt + amber,
  corner-radius: 3pt,
  inset: 7pt,
)

/// A left-to-right pipeline. `stages` is an array of content; the last stage
/// is drawn in the accent style.
#let pipeline(stages, spacing: 26mm) = diagram(
  spacing: (spacing, 14mm),
  edge-stroke: 0.8pt + gray,
  ..stages
    .enumerate()
    .map(((i, stage)) => node(
      (i, 0),
      stage,
      ..(if i == stages.len() - 1 { accent_style } else { node_style }),
    )),
  ..range(stages.len() - 1).map(i => edge((i, 0), (i + 1, 0), "-|>")),
)

/// A row of cells with an index ruler underneath: the picture of a flat array,
/// which is the shape most of this book's data structures have.
#let array_picture(cells, label: none, cell_width: 1.5, cell_height: 0.72) = cetz.canvas(
  length: 1cm,
  {
    import cetz.draw: *
    for (i, cell) in cells.enumerate() {
      let x = i * cell_width
      rect(
        (x, 0),
        (x + cell_width, cell_height),
        fill: blue_light,
        stroke: 0.7pt + blue,
      )
      content((x + cell_width / 2, cell_height / 2), text(size: 8pt)[#cell])
      content(
        (x + cell_width / 2, -0.32),
        text(size: 7pt, fill: gray)[#i],
      )
    }
    if label != none {
      content(
        (-0.25, cell_height / 2),
        anchor: "east",
        text(size: 8pt, weight: "bold", fill: gray)[#label],
      )
    }
  },
)

/// A caption line for a figure that is a table rather than a picture.
#let figure_note(body) = text(size: 8.5pt, fill: gray)[#body]
