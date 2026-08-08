// The book's HTML forms (ZDS 0015).
//
// Typst emits content only; the site assembler supplies the shared shell,
// stylesheet, navigation, and document head. So this file's job is narrow:
// give every book construct a semantic element with a class, and never an
// inline colour or a paged-media primitive.
//
// Two rules govern everything here.
//
// Presentation is carried by class names, never by a `style` attribute. The
// published site sets a strict content policy that forbids inline style, so
// an inline colour here would either break the page or force the policy to be
// weakened for the whole site.
//
// Meaning is never carried by colour alone. A callout that is only red is a
// callout that says nothing to a reader who cannot see red, so each one
// states its kind in words.

#let kind_label(kind) = if kind == "warning" {
  "Warning"
} else if kind == "idea" {
  "Idea"
} else {
  "Note"
}

/// The HTML chapter frame. `title` becomes the article's only `h1`: Typst
/// reserves `h1` for a document title it never emits, which would otherwise
/// leave every chapter starting at `h2` with no top-level heading at all.
#let chapter_frame(body, title: "Untitled") = {
  set heading(numbering: none)
  html.elem("article", attrs: (class: "chapter"))[
    #html.elem("h1", attrs: (class: "chapter-title"))[#title]
    #body
  ]
}

#let part_banner(number, title, summary) = html.elem(
  "aside",
  attrs: (class: "part-banner", "aria-label": "Part " + number),
)[
  #html.elem("p", attrs: (class: "part-number"))[Part #number]
  #html.elem("p", attrs: (class: "part-title"))[#title]
  #html.elem("p", attrs: (class: "part-summary"))[#summary]
]

#let callout(title, body, kind: "note") = html.elem(
  "aside",
  attrs: (class: "callout callout-" + kind),
)[
  #html.elem("p", attrs: (class: "callout-head"))[
    #html.elem("span", attrs: (class: "callout-kind"))[#kind_label(kind):]
    #html.elem("span", attrs: (class: "callout-title"))[#title]
  ]
  #body
]

#let book_quote(body, attribution) = html.elem("figure", attrs: (class: "quote"))[
  #html.elem("blockquote")[#body]
  #html.elem("figcaption")[#attribution]
]

#let exercise(number, body, hint: none) = html.elem(
  "section",
  attrs: (class: "exercise"),
)[
  #html.elem("p", attrs: (class: "exercise-head"))[Exercise #number.]
  #body
  #if hint != none {
    html.elem("p", attrs: (class: "exercise-hint"))[Hint: #hint]
  }
]

#let teach_back(body) = html.elem("aside", attrs: (class: "teach-back"))[
  #html.elem("p", attrs: (class: "teach-back-head"))[Teach it back.]
  #body
]

#let code_file(path, body) = html.elem("figure", attrs: (class: "code-file"))[
  #html.elem("figcaption")[#path]
  #body
]

/// A figure whose body is prose, a table, or code: it survives HTML export
/// intact and needs no alternative text beyond its caption.
#let book_figure(caption, body) = html.elem("figure", attrs: (class: "figure"))[
  #body
  #html.elem("figcaption")[#caption]
]

/// A row of summary tiles. Paged output arranges them in a grid; the web
/// lets the stylesheet decide, so the row reflows instead of overflowing on
/// a narrow screen.
#let tile_row(tiles) = html.elem("div", attrs: (class: "tiles"))[
  #for tile in tiles { tile }
]

/// A chart. The drawing carries no text once exported, so a chart without
/// its numbers in a readable form is a chart that says nothing to anyone
/// using a screen reader — `data` is the same figures as a real table, and
/// it is required, not decorative.
#let chart_figure(caption, body, alt: none, data: none) = {
  assert(
    alt != none and alt != "",
    message: "a chart must declare alt text: " + repr(caption),
  )
  assert(
    data != none,
    message: "a chart must carry its data as a table: " + repr(caption),
  )
  html.elem("figure", attrs: (class: "figure chart", "data-alt": alt))[
    #html.frame(body)
    #html.elem("figcaption")[#caption]
    #html.elem("details", attrs: (class: "figure-data"))[
      #html.elem("summary")[The numbers behind this chart]
      #data
    ]
  ]
}

/// A figure whose body is drawn artwork.
///
/// Typst renders such a figure to vector graphics in which every character of
/// text has become a glyph outline: there is no text in the output at all. So
/// the drawing is unreadable to a screen reader, unsearchable, and
/// unselectable however good it looks. `alt` is therefore not optional, and
/// `description` carries the prose long form for diagrams whose content a
/// single sentence cannot honestly convey.
///
/// The site assembler lifts the artwork into its own file and references it
/// with this alternative text; `data-alt` is how it is carried across.
#let diagram_figure(caption, body, alt: none, description: none) = {
  assert(
    alt != none and alt != "",
    message: "a diagram figure must declare alt text: " + repr(caption),
  )
  html.elem(
    "figure",
    attrs: (class: "figure diagram", "data-alt": alt),
  )[
    #html.frame(body)
    #html.elem("figcaption")[#caption]
    #if description != none {
      html.elem("details", attrs: (class: "figure-longdesc"))[
        #html.elem("summary")[Description of this diagram]
        #description
      ]
    }
  ]
}
