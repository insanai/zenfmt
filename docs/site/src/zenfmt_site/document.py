"""Transforming Typst's HTML output into publishable pages (ZDS 0015).

Typst emits a whole document with its own head, an inline stylesheet, inline
style attributes on nearly every highlighted token, positional heading
identifiers, and — for a diagram — a large inline `<svg>` whose text is glyph
outlines. None of that can be published as-is:

* a strict content policy is only credible if there is no inline style left to
  allow, and style *attributes* cannot be covered by a hash;
* positional identifiers renumber on any earlier edit, so they are not
  anchors;
* an inline diagram is most of a page's bytes and carries no text at all.

So this module takes the document apart and puts the parts where they belong.
It is deliberately strict: an element, attribute, or style value it does not
recognise is a build failure with the offending fragment quoted, because the
alternative is a generator that silently repairs breakage in an experimental
exporter's output and calls the result semantic HTML.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from html.parser import HTMLParser

from .routes import unique_slug

VOID_ELEMENTS = frozenset(
    {
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr",
    }
)

# The closed map from Typst's inline style values to semantic classes. It is
# closed on purpose: an unmapped value fails the build rather than being
# passed through, because passing one through is what would force the content
# policy to allow inline style for the whole site.
STYLE_CLASSES = {
    "color: #d73948": "tok-string",
    "color: #4b69c6": "tok-keyword",
    "color: #198810": "tok-function",
    "color: #74747c": "tok-comment",
    "color: #b60157": "tok-number",
    "color: #1d6c76": "tok-type",
    "color: #8b41b1": "tok-macro",
    "white-space: pre-wrap": "pre-wrap",
    "display: inline-block": "inline-block",
    "list-style-type: none": "list-plain",
    "text-decoration: underline": "underline",
}


class ContractError(Exception):
    """The exporter produced something this generator will not publish."""


@dataclass
class Figure:
    """A diagram lifted out of the page into its own file."""

    name: str
    svg: str
    alt: str


@dataclass
class Document:
    """One parsed Typst page, ready to be wrapped in the site shell."""

    title: str = ""
    description: str = ""
    body: str = ""
    stylesheets: list[str] = field(default_factory=list)
    figures: list[Figure] = field(default_factory=list)
    headings: list[tuple[int, str, str]] = field(default_factory=list)


class _Parser(HTMLParser):
    """Reads a Typst document and rebuilds its body with the transforms
    applied. `html.parser` is enough here because the input is one
    generator's output rather than the open web, and anything it surprises us
    with is meant to fail rather than be recovered."""

    def __init__(self, *, page_id: str, strict: bool) -> None:
        super().__init__(convert_charrefs=False)
        self.page_id = page_id
        self.strict = strict
        self.doc = Document()
        self._out: list[str] = []
        self._in_head = False
        self._in_style = False
        self._in_title = False
        self._style_buffer: list[str] = []
        self._title_buffer: list[str] = []
        self._svg_depth = 0
        self._svg_buffer: list[str] = []
        self._svg_alt: str | None = None
        self._heading: list[str] | None = None
        self._heading_level = 0
        self._taken: set[str] = set()
        self._pending_heading_id: str | None = None

    # -- structure ------------------------------------------------------

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        mapping = dict(attrs)

        if tag == "head":
            self._in_head = True
            return
        if tag == "body":
            return
        if tag == "style":
            self._in_style = True
            return
        if tag == "title":
            self._in_title = True
            return
        if tag in {"meta", "link"} and self._in_head:
            if mapping.get("name") == "description":
                self.doc.description = mapping.get("content") or ""
            return

        if tag == "svg":
            self._svg_depth += 1
            if self._svg_depth == 1:
                self._svg_buffer = []
        if self._svg_depth:
            self._svg_buffer.append(self._render(tag, mapping, close=False))
            return

        if tag == "figure":
            self._svg_alt = mapping.get("data-alt")

        if tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
            self._heading = []
            self._heading_level = int(tag[1])

        self._out.append(self._render(tag, mapping, close=tag in VOID_ELEMENTS))

    def handle_endtag(self, tag: str) -> None:
        if tag == "head":
            self._in_head = False
            return
        if tag == "body":
            return
        if tag == "style":
            self._in_style = False
            self.doc.stylesheets.append("".join(self._style_buffer))
            self._style_buffer = []
            return
        if tag == "title":
            self._in_title = False
            self.doc.title = "".join(self._title_buffer).strip()
            self._title_buffer = []
            return
        if tag in {"meta", "link"}:
            return

        if self._svg_depth:
            self._svg_buffer.append(f"</{tag}>")
            self._svg_depth -= 1
            if self._svg_depth == 0:
                self._emit_figure()
            return

        if tag in {"h1", "h2", "h3", "h4", "h5", "h6"} and self._heading is not None:
            self._close_heading(tag)
            return

        if tag in VOID_ELEMENTS:
            return
        self._out.append(f"</{tag}>")

    def handle_data(self, data: str) -> None:
        if self._in_style:
            self._style_buffer.append(data)
            return
        if self._in_title:
            self._title_buffer.append(data)
            return
        if self._svg_depth:
            self._svg_buffer.append(data)
            return
        if self._heading is not None:
            self._heading.append(data)
        self._out.append(data)

    def handle_entityref(self, name: str) -> None:
        self._passthrough(f"&{name};")

    def handle_charref(self, name: str) -> None:
        self._passthrough(f"&#{name};")

    def _passthrough(self, text: str) -> None:
        if self._in_style or self._in_title:
            return
        if self._svg_depth:
            self._svg_buffer.append(text)
            return
        self._out.append(text)

    # -- transforms -----------------------------------------------------

    def _render(self, tag: str, mapping: dict[str, str | None], *, close: bool) -> str:
        classes: list[str] = []
        attributes: list[tuple[str, str | None]] = []

        for name, value in list(mapping.items()):
            if name == "class":
                if value:
                    classes.append(value)
                continue
            if name == "style" and not self._svg_depth:
                # An inline style becomes a semantic class, or fails the
                # build. It never survives into the published page.
                mapped = self._style_class(value or "")
                if mapped:
                    classes.append(mapped)
                continue
            if name == "id" and tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
                # Replaced with a slug once the heading's text is known.
                self._pending_heading_id = value
                continue
            attributes.append((name, value))

        parts = [tag]
        if classes:
            parts.append(f'class="{_escape_attr(" ".join(classes))}"')
        for name, value in attributes:
            parts.append(name if value is None else f'{name}="{_escape_attr(value)}"')
        return f"<{' '.join(parts)}{' /' if close else ''}>"

    def _style_class(self, value: str) -> str:
        normalized = " ".join(value.split()).rstrip(";")
        if normalized in STYLE_CLASSES:
            return STYLE_CLASSES[normalized]
        if not self.strict:
            return ""
        raise ContractError(
            f"unmapped inline style {normalized!r} on page {self.page_id!r}. "
            "Add it to STYLE_CLASSES with a semantic class name, or change the "
            "source so it is not emitted; it cannot be published as an inline "
            "style because the content policy forbids one."
        )

    def _close_heading(self, tag: str) -> None:
        text = "".join(self._heading or []).strip()
        slug = unique_slug(text, self._taken)
        self.doc.headings.append((self._heading_level, slug, text))
        # Rewrite the opening tag that is still sitting in the output buffer.
        for index in range(len(self._out) - 1, -1, -1):
            if self._out[index].startswith(f"<{tag}"):
                opening = self._out[index][:-1]
                legacy = self._pending_heading_id
                extra = f' id="{slug}"'
                if legacy:
                    # Kept for one release so links minted against the old
                    # positional identifier still land somewhere.
                    extra += f' data-legacy-id="{_escape_attr(legacy)}"'
                self._out[index] = f"{opening}{extra}>"
                break
        self._out.append(
            f'<a class="permalink" href="#{slug}" '
            f'aria-label="Permalink to this section">#</a>'
        )
        self._out.append(f"</{tag}>")
        self._heading = None
        self._pending_heading_id = None

    def _emit_figure(self) -> None:
        svg = "".join(self._svg_buffer)
        self._svg_buffer = []
        alt = self._svg_alt or ""
        if not alt:
            raise ContractError(
                f"a diagram on page {self.page_id!r} has no alternative text. "
                "Typst renders figure text as glyph outlines, so a diagram "
                "without alt text is unreadable to a screen reader; give it "
                "one through diagram_figure(alt: ...)."
            )
        digest = hashlib.sha256(svg.encode("utf-8")).hexdigest()[:12]
        name = f"{self.page_id}-{len(self.doc.figures) + 1}.{digest}.svg"
        self.doc.figures.append(Figure(name=name, svg=svg, alt=alt))
        width, height = _dimensions(svg)
        self._out.append(
            f'<img src="{{ASSET:fig/{name}}}" alt="{_escape_attr(alt)}"'
            f'{width}{height} loading="lazy" decoding="async">'
        )
        self._svg_alt = None


_DIMENSION = re.compile(r'\b(width|height)="([^"]+)"')


def _dimensions(svg: str) -> tuple[str, str]:
    """Carries the drawing's own size onto the image element, so the page
    does not reflow when a lazily loaded diagram arrives."""
    found = dict(_DIMENSION.findall(svg[:400]))
    width = f' width="{found["width"]}"' if "width" in found else ""
    height = f' height="{found["height"]}"' if "height" in found else ""
    return width, height


def _escape_attr(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace('"', "&quot;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def parse(source: str, *, page_id: str, strict: bool = True) -> Document:
    """Parses one Typst-generated page into a publishable document."""
    parser = _Parser(page_id=page_id, strict=strict)
    parser.feed(source)
    parser.close()
    parser.doc.body = "".join(parser._out).strip()
    return parser.doc


def assert_figures(doc: Document, expected: int, page_id: str) -> None:
    """Guards against the failure this exporter actually has: a diagram that
    exports as an empty element, with its caption intact and no warning."""
    if len(doc.figures) != expected:
        raise ContractError(
            f"page {page_id!r} produced {len(doc.figures)} diagrams, expected "
            f"{expected}. Typst drops a figure it cannot map without reporting "
            "it, so a count that has fallen usually means a diagram exported "
            "empty rather than that one was removed on purpose."
        )
