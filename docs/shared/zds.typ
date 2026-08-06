#import "theme.typ": configure-document, document-frontmatter

#let zds-placeholder-number = "XXXXX"

#let zds-state-fill(state) = {
  if state == "published" {
    rgb("dbeafe")
  } else if state == "discussion" {
    rgb("dcfce7")
  } else if state == "committed" {
    rgb("ede9fe")
  } else if state == "abandoned" {
    rgb("e5e7eb")
  } else {
    rgb("fef3c7")
  }
}

#let zds-chip(label, fill) = box(
  inset: (x: 0.45em, y: 0.25em),
  radius: 999pt,
  fill: fill,
  stroke: none,
)[
  #text(9pt, weight: "semibold")[#label]
]

#let zds-title(number, title) = {
  if number == zds-placeholder-number {
    [ZDS #zds-placeholder-number: #title]
  } else {
    [ZDS #number: #title]
  }
}

#let authors-block(authors) = {
  if authors.len() == 0 {
    [Zen Contributors]
  } else {
    authors.join("\n")
  }
}

#let zds-label(label) = text(8.7pt, weight: "bold", tracking: 0.04em, fill: rgb("475569"))[#label]

#let zds-value(body) = text(10.2pt, fill: rgb("111827"))[#body]

#let html-style = "
:root {
  --font-sans: 'Inter', system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
  --font-mono: 'JetBrains Mono', 'Fira Code', 'Menlo', 'Courier New', monospace;
  
  --bg-primary: #ffffff;
  --bg-secondary: #f8fafc;
  --bg-accent: #f1f5f9;
  
  --text-primary: #0f172a;
  --text-secondary: #334155;
  --text-muted: #64748b;
  
  --border-color: #e2e8f0;
  
  --color-primary: #4f46e5;
  --color-primary-hover: #4338ca;
  
  --state-published-bg: #dcfce7;
  --state-published-text: #166534;
  --state-discussion-bg: #dbeafe;
  --state-discussion-text: #1e40af;
  --state-accepted-bg: #fef9c3;
  --state-accepted-text: #854d0e;
  --state-committed-bg: #f3e8ff;
  --state-committed-text: #6b21a8;
  --state-abandoned-bg: #f1f5f9;
  --state-abandoned-text: #475569;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg-primary: #0f172a;
    --bg-secondary: #1e293b;
    --bg-accent: #334155;
    
    --text-primary: #f8fafc;
    --text-secondary: #cbd5e1;
    --text-muted: #94a3b8;
    
    --border-color: #334155;
    
    --color-primary: #818cf8;
    --color-primary-hover: #a5b4fc;
    
    --state-published-bg: rgba(22, 101, 52, 0.3);
    --state-published-text: #86efac;
    --state-discussion-bg: rgba(30, 64, 175, 0.3);
    --state-discussion-text: #93c5fd;
    --state-accepted-bg: rgba(133, 77, 14, 0.3);
    --state-accepted-text: #fde047;
    --state-committed-bg: rgba(107, 33, 168, 0.3);
    --state-committed-text: #e9d5ff;
    --state-abandoned-bg: rgba(71, 85, 105, 0.3);
    --state-abandoned-text: #cbd5e1;
  }
}

body {
  font-family: var(--font-sans);
  background-color: var(--bg-primary);
  color: var(--text-primary);
  line-height: 1.75;
  margin: 0;
  padding: 0;
  -webkit-font-smoothing: antialiased;
}

.zds-container {
  max-width: 860px;
  margin: 4rem auto;
  padding: 0 2rem;
}

.zds-back-link {
  margin-bottom: 2rem;
  font-size: 0.95rem;
  font-weight: 600;
}

.zds-back-link a {
  color: var(--text-muted) !important;
  border-bottom: none !important;
  text-decoration: none;
  transition: color 0.15s ease;
}

.zds-back-link a:hover {
  color: var(--color-primary) !important;
}

.zds-header {
  border-bottom: 1px solid var(--border-color);
  padding-bottom: 2.5rem;
  margin-bottom: 3rem;
}

.zds-badge {
  display: inline-block;
  font-size: 0.75rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  padding: 0.35rem 0.85rem;
  border-radius: 9999px;
  margin-bottom: 1.25rem;
}

.zds-badge.published { background: var(--state-published-bg); color: var(--state-published-text); }
.zds-badge.discussion { background: var(--state-discussion-bg); color: var(--state-discussion-text); }
.zds-badge.accepted { background: var(--state-accepted-bg); color: var(--state-accepted-text); }
.zds-badge.committed { background: var(--state-committed-bg); color: var(--state-committed-text); }
.zds-badge.abandoned { background: var(--state-abandoned-bg); color: var(--state-abandoned-text); }

.zds-title {
  font-size: 2.5rem;
  font-weight: 800;
  line-height: 1.2;
  letter-spacing: -0.03em;
  margin: 0 0 2rem 0;
}

.zds-meta-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 1.25rem;
  background-color: var(--bg-secondary);
  border: 1px solid var(--border-color);
  border-radius: 12px;
  padding: 1.5rem;
}

.zds-meta-item {
  display: flex;
  flex-direction: column;
}

.zds-meta-label {
  font-size: 0.75rem;
  font-weight: 700;
  text-transform: uppercase;
  color: var(--text-muted);
  letter-spacing: 0.05em;
  margin-bottom: 0.35rem;
}

.zds-meta-val {
  font-size: 0.95rem;
  color: var(--text-secondary);
  font-weight: 600;
}

/* Document Content Styling */
h1, h2, h3, h4 {
  color: var(--text-primary);
  font-weight: 700;
  letter-spacing: -0.02em;
  line-height: 1.3;
}

h2 {
  font-size: 1.8rem;
  margin-top: 3.5rem;
  margin-bottom: 1.25rem;
  padding-bottom: 0.5rem;
  border-bottom: 1px solid var(--border-color);
}

h3 {
  font-size: 1.4rem;
  margin-top: 2.5rem;
  margin-bottom: 1rem;
}

p {
  margin-top: 0;
  margin-bottom: 1.6rem;
  font-size: 1.075rem;
  color: var(--text-secondary);
}

ul, ol {
  margin-top: 0;
  margin-bottom: 1.6rem;
  padding-left: 1.75rem;
}

li {
  margin-bottom: 0.5rem;
  font-size: 1.05rem;
  color: var(--text-secondary);
}

code {
  font-family: var(--font-mono);
  font-size: 0.9rem;
  background-color: var(--bg-secondary);
  padding: 0.2rem 0.45rem;
  border-radius: 6px;
  border: 1px solid var(--border-color);
}

pre {
  background-color: var(--bg-secondary);
  border: 1px solid var(--border-color);
  border-radius: 12px;
  padding: 1.5rem;
  overflow-x: auto;
  margin-bottom: 1.8rem;
}

pre code {
  background-color: transparent;
  padding: 0;
  border: none;
  font-size: 0.9rem;
}

a {
  color: var(--color-primary);
  text-decoration: none;
  border-bottom: 1px dashed var(--color-primary);
  transition: all 0.2s ease;
}

a:hover {
  color: var(--color-primary-hover);
  border-bottom-style: solid;
}

/* Index Page Specifics */
.zds-index-header {
  border-bottom: 1px solid var(--border-color);
  padding-bottom: 2rem;
  margin-bottom: 3rem;
}

.zds-index-header h1 {
  font-size: 3rem;
  font-weight: 800;
  letter-spacing: -0.03em;
  margin: 0 0 1rem 0;
}

.zds-index-header p {
  font-size: 1.2rem;
  color: var(--text-secondary);
  margin: 0;
}

.zds-index-card {
  background-color: var(--bg-secondary);
  border: 1px solid var(--border-color);
  border-radius: 16px;
  padding: 2rem;
  margin-bottom: 2rem;
  transition: transform 0.2s ease, box-shadow 0.2s ease, border-color 0.2s ease;
}

.zds-index-card:hover {
  transform: translateY(-2px);
  border-color: var(--color-primary);
  box-shadow: 0 12px 24px -10px rgba(0, 0, 0, 0.08);
}

.zds-card-title {
  font-size: 1.5rem;
  font-weight: 700;
  margin: 0 0 0.75rem 0;
}

.zds-card-desc {
  font-size: 1.05rem;
  color: var(--text-secondary);
  margin-bottom: 1.5rem;
  line-height: 1.6;
}

.zds-card-links {
  display: flex;
  gap: 1.5rem;
  font-size: 0.95rem;
  font-weight: 700;
  margin-bottom: 1.5rem;
}

.zds-card-links a {
  border-bottom: 2px solid transparent;
}

.zds-card-links a:hover {
  border-bottom: 2px solid var(--color-primary-hover);
}

.zds-card-meta {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 0.75rem;
  margin-top: 1.5rem;
  font-size: 0.85rem;
  color: var(--text-muted);
  border-top: 1px solid var(--border-color);
  padding-top: 1.25rem;
}

.zds-card-meta span {
  display: inline-block;
}
"

#let zds-document(
  number,
  title,
  body,
  authors: (),
  state: "prediscussion",
  created: "",
  discussion: "",
  labels: (),
  category: "Engineering Discussion",
  status: "Internal Draft",
  last-updated: "None",
) = context {
  if target() == "html" {
    [
      #set document(
        title: [ZDS #number: #title],
        author: authors,
        description: [#discussion],
        date: none,
      )

      #html.elem("style")[#html-style]

      #html.elem("div", attrs: (class: "zds-container"))[
        #html.elem("div", attrs: (class: "zds-back-link"))[
          #html.elem("a", attrs: (href: "../index.html"))[← Back to Zen Discussions]
        ]
        
        #html.elem("div", attrs: (class: "zds-header"))[
          #html.elem("span", attrs: (class: "zds-badge " + state))[#state]
          #html.elem("h1", attrs: (class: "zds-title"))[ZDS #number: #title]
          
          #html.elem("div", attrs: (class: "zds-meta-grid"))[
            #html.elem("div", attrs: (class: "zds-meta-item"))[
              #html.elem("span", attrs: (class: "zds-meta-label"))[Category]
              #html.elem("span", attrs: (class: "zds-meta-val"))[#category]
            ]
            #html.elem("div", attrs: (class: "zds-meta-item"))[
              #html.elem("span", attrs: (class: "zds-meta-label"))[Intended Status]
              #html.elem("span", attrs: (class: "zds-meta-val"))[#status]
            ]
            #html.elem("div", attrs: (class: "zds-meta-item"))[
              #html.elem("span", attrs: (class: "zds-meta-label"))[Created]
              #html.elem("span", attrs: (class: "zds-meta-val"))[#created]
            ]
            #html.elem("div", attrs: (class: "zds-meta-item"))[
              #html.elem("span", attrs: (class: "zds-meta-label"))[Last Updated]
              #html.elem("span", attrs: (class: "zds-meta-val"))[#last-updated]
            ]
            #html.elem("div", attrs: (class: "zds-meta-item"))[
              #html.elem("span", attrs: (class: "zds-meta-label"))[Authors]
              #html.elem("span", attrs: (class: "zds-meta-val"))[#authors-block(authors)]
            ]
            #html.elem("div", attrs: (class: "zds-meta-item"))[
              #html.elem("span", attrs: (class: "zds-meta-label"))[Discussion]
              #html.elem("span", attrs: (class: "zds-meta-val"))[#discussion]
            ]
          ]
        ]

        #body
      ]
    ]
  } else {
    [
  #set document(
    title: [ZDS #number: #title],
    author: authors,
    description: [#discussion],
    date: none,
  )
  #configure-document()
  #set page(margin: (x: 1.15in, y: 1in), numbering: "1")
  #set par(justify: true)
  #set heading(numbering: "1.")

  #block(inset: (x: 1.05em, y: 0.95em), stroke: 0.65pt + rgb("d7dee8"), fill: luma(99%))[
    #set par(justify: false)
    #grid(
      columns: (1fr, auto),
      column-gutter: 1.4em,
      align: (left, top),
      [
        #text(12.4pt, weight: "bold")[Zen Working Group]
        #linebreak()
        #text(9.3pt, fill: rgb("64748b"))[Request for Discussion and Implementation Record]
      ],
      [
        #align(right)[
          #text(13.5pt, weight: "bold")[ZDS #if number == zds-placeholder-number { [#zds-placeholder-number] } else { [#number] }]
          #linebreak()
          #text(9.3pt, weight: "semibold", fill: rgb("64748b"))[#category]
        ]
      ],
    )

    #v(0.95em)
    #text(21pt, weight: "bold")[#title]

    #v(0.55em)
    #line(length: 100%, stroke: 0.7pt + rgb("e2e8f0"))

    #v(0.8em)
    #grid(
      columns: (1fr, 1fr),
      column-gutter: 1.9em,
      row-gutter: 0.5em,
      align: (left, top),
      [#zds-label[STATE]],
      [#zds-label[INTENDED STATUS]],
      [#zds-chip(state, zds-state-fill(state))],
      [#zds-value[#status]],
      [#zds-label[CREATED]],
      [#zds-label[AUTHORS]],
      [#zds-value[#created]],
      [#block(width: 100%)[#zds-value[#authors-block(authors)]]],
      [#zds-label[LAST UPDATED]],
      [],
      [#zds-value[#last-updated]],
      [],
    )

    #v(0.65em)
    #zds-label[DISCUSSION]
    #linebreak()
    #block(width: 100%)[#zds-value[#discussion]]

    #if labels.len() > 0 [
      #v(0.65em)
      #zds-label[LABELS]
      #linebreak()
      #text(10pt, fill: rgb("334155"))[#labels.join(", ")]
    ]
  ]

  #v(1em)

  #block(inset: 0.9em, stroke: 0.7pt + rgb("9ca3af"), fill: luma(98%))[
    *Status of This Memo*

    This document is an internal Zen discussion record authored in Typst and tracked in git. It intentionally follows RFC-style structure so the design scope, rationale, trade-offs, and operational constraints remain explicit. Documents that still use the placeholder number #text(font: "Libertinus Mono", size: 10pt)[#zds-placeholder-number] are provisional drafts. Numbered ZDS documents are part of the project record.
  ]

  #v(1em)
  #outline(indent: 1.4em)
  #v(1em)

  #body
    ]
  }
}

#let zds-index-entry(doc) = [
  #block(inset: 0.8em, stroke: 0.65pt + rgb("d7dee8"), fill: luma(99%), radius: 4pt)[
    #grid(
      columns: (1fr, auto),
      column-gutter: 1.2em,
      align: (left, top),
      [
        #text(12.5pt, weight: "bold")[ZDS #doc.number: #doc.title]
        #linebreak()
        #text(9.3pt, fill: rgb("64748b"))[#doc.summary]
      ],
      [
        #align(right)[
          #zds-chip(doc.state, zds-state-fill(doc.state))
          #linebreak()
          #text(8.7pt, fill: rgb("64748b"))[#doc.area]
        ]
      ],
    )

    #v(0.55em)
    #grid(
      columns: (auto, 1fr, auto, 1fr),
      column-gutter: 0.8em,
      row-gutter: 0.25em,
      [#zds-label[STATUS]], [#zds-value[#doc.status]],
      [#zds-label[CREATED]], [#zds-value[#doc.created]],
      [#zds-label[CATEGORY]], [#zds-value[#doc.category]],
      [#zds-label[UPDATED]], [#zds-value[#doc.updated]],
    )

    #v(0.55em)
    #text(9.2pt, fill: rgb("334155"))[
      Source: #raw(doc.source)
    ]
  ]
]

#let zds-index-page(documents) = [
  = Index

  Zen Discussions are RFC/RFD-style design records for the zenfmt monorepo: the zenfmt document-conversion library and the zenfmt command-line tool. Each ZDS is a standalone Typst source file with metadata, lifecycle state, area, and summary data surfaced in this index.

  Placeholder drafts use the number #raw(zds-placeholder-number) until maintainers assign the next permanent four-digit ZDS number.

  #for doc in documents [
    #zds-index-entry(doc)
    #v(0.65em)
  ]
]

#let zds-site-index(documents) = [
  #html.elem("style")[#html-style]
  
  #html.elem("div", attrs: (class: "zds-container"))[
    #html.elem("div", attrs: (class: "zds-index-header"))[
      #html.elem("h1")[Zen Discussions]
      #html.elem("p")[Index of Zen Discussion (ZDS) records.]
    ]

    #for doc in documents [
      #html.elem("div", attrs: (class: "zds-index-card"))[
        #html.elem("span", attrs: (class: "zds-badge " + doc.state))[#doc.state]
        #html.elem("h2", attrs: (class: "zds-card-title"))[ZDS #doc.number: #doc.title]
        #html.elem("p", attrs: (class: "zds-card-desc"))[#doc.summary]
        
        #html.elem("div", attrs: (class: "zds-card-links"))[
          #html.elem("a", attrs: (href: doc.html))[HTML View]
          #html.elem("a", attrs: (href: doc.pdf))[PDF View]
        ]
        
        #html.elem("div", attrs: (class: "zds-card-meta"))[
          #html.elem("span")[*Area:* #doc.area]
          #html.elem("span")[*Category:* #doc.category]
          #html.elem("span")[*Status:* #doc.status]
          #html.elem("span")[*Created:* #doc.created]
          #html.elem("span")[*Updated:* #doc.updated]
          #html.elem("span")[*Source:* `#doc.source`]
        ]
      ]
    ]
  ]
]
