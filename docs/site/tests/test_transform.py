"""The transforms that make the published pages publishable.

These are the parts of the assembler with real logic, and they run without a
built site or a browser, so they belong in the ordinary test suite.
"""

from __future__ import annotations

import pytest

from zenfmt_site import routes
from zenfmt_site.build import Builder
from zenfmt_site.document import ContractError, parse
from zenfmt_site.validate import check


def wrap(body: str, title: str = "A page") -> str:
    return f"<html><head><title>{title}</title></head><body>{body}</body></html>"


class TestRoutes:
    def test_a_directory_route_becomes_an_index_document(self):
        assert routes.output_path("book/tour/") == "book/tour/index.html"
        assert routes.output_path("") == "index.html"
        # A record keeps its published .html address rather than gaining a
        # directory, because those links are already out in the world.
        assert routes.output_path("zds/0015-x.html") == "zds/0015-x.html"

    def test_links_are_relative_to_the_page_that_carries_them(self):
        assert routes.relative("", "book/") == "book/"
        assert routes.relative("book/tour/", "") == "../../"
        assert routes.relative("book/tour/", "zds/") == "../../zds/"
        # A record page sits one level down, not two: its address is a file.
        assert routes.relative("zds/0015-x.html", "") == "../"

    def test_the_same_tree_serves_from_any_base(self):
        # Nothing in a relative link mentions a deployment path, which is why
        # the same output works at / and at /zenfmt/.
        for route in ("", "book/", "book/tour/", "zds/0001-x.html"):
            assert not routes.relative(route, "download/").startswith("/")

    def test_the_not_found_page_can_be_base_absolute(self):
        assert routes.absolute("/zenfmt/", "book/") == "/zenfmt/book/"
        assert routes.absolute("/", "book/") == "/book/"

    def test_anchors_come_from_heading_text_and_are_disambiguated(self):
        taken: set[str] = set()
        assert routes.unique_slug("The document model", taken) == "the-document-model"
        assert routes.unique_slug("The document model", taken) == "the-document-model-2"
        assert routes.slugify("Ünicode — and punctuation!") == "unicode-and-punctuation"
        assert routes.slugify("!!!") == "section"


class TestStyleRemoval:
    def test_a_known_inline_style_becomes_a_class(self):
        doc = parse(wrap('<code style="color: #d73948">x</code>'), page_id="p")
        assert 'class="tok-string"' in doc.body
        assert "style=" not in doc.body

    def test_an_unknown_inline_style_fails_the_build(self):
        # Passing it through would force the content policy to allow inline
        # style for the whole site, which is the thing being prevented.
        with pytest.raises(ContractError, match="unmapped inline style"):
            parse(wrap('<b style="color: #abcdef">x</b>'), page_id="p")

    def test_an_existing_class_is_kept_alongside_the_mapped_one(self):
        doc = parse(
            wrap('<span class="a" style="color: #198810">x</span>'), page_id="p"
        )
        assert 'class="a tok-function"' in doc.body

    def test_the_stylesheet_is_lifted_out_of_the_document(self):
        doc = parse(
            "<html><head><title>t</title><style>p{color:red}</style></head>"
            "<body><p>x</p></body></html>",
            page_id="p",
        )
        assert doc.stylesheets == ["p{color:red}"]
        assert "<style" not in doc.body


class TestHeadings:
    def test_headings_gain_slugged_anchors_and_a_permalink(self):
        doc = parse(wrap('<h2 id="loc-7">Hostile by default</h2>'), page_id="p")
        assert 'id="hostile-by-default"' in doc.body
        assert 'href="#hostile-by-default"' in doc.body
        # The positional identifier is kept for one release so existing links
        # still land somewhere.
        assert 'data-legacy-id="loc-7"' in doc.body
        assert doc.headings == [(2, "hostile-by-default", "Hostile by default")]

    def test_repeated_heading_text_still_yields_unique_anchors(self):
        doc = parse(wrap("<h2>Limits</h2><h3>Limits</h3>"), page_id="p")
        assert [slug for _, slug, _ in doc.headings] == ["limits", "limits-2"]


class TestFigures:
    def test_a_diagram_is_lifted_into_its_own_file(self):
        body = (
            '<figure data-alt="A pipeline from reader to writer">'
            '<svg width="100" height="50"><path d="M0 0"/></svg>'
            "<figcaption>Fig</figcaption></figure>"
        )
        doc = parse(wrap(body), page_id="tour")
        assert len(doc.figures) == 1
        assert doc.figures[0].alt.startswith("A pipeline")
        assert "<svg" not in doc.body
        assert "<img" in doc.body
        assert 'alt="A pipeline from reader to writer"' in doc.body
        assert doc.figures[0].svg.endswith("</svg>")
        # The drawing's own size travels onto the image so a lazily loaded
        # diagram does not reflow the page when it arrives.
        assert 'width="100"' in doc.body
        assert 'loading="lazy"' in doc.body

    def test_a_diagram_without_alt_text_fails_the_build(self):
        # Typst renders figure text as glyph outlines, so a diagram with no
        # alt text is unreadable rather than merely undescribed.
        with pytest.raises(ContractError, match="no alternative text"):
            parse(wrap("<figure><svg><path d='M0 0'/></svg></figure>"), page_id="p")

    def test_stroke_width_cannot_replace_the_diagram_width(self):
        body = (
            '<figure data-alt="A visible diagram">'
            '<svg width="150pt" height="75pt">'
            '<path stroke-width="0.8" d="M0 0"/></svg></figure>'
        )
        doc = parse(wrap(body), page_id="p")
        assert 'width="200"' in doc.body
        assert 'height="100"' in doc.body
        assert 'width="0.8"' not in doc.body


class TestBuilderOutput:
    def builder(self, tmp_path):
        out = tmp_path / "site"
        out.mkdir()
        return Builder(None, out, base="/", version="test")

    def test_two_inputs_cannot_overwrite_one_output(self, tmp_path):
        builder = self.builder(tmp_path)
        builder.write_text("asset.txt", "first")
        with pytest.raises(ContractError, match="same output"):
            builder.write_text("asset.txt", "second")

    def test_parent_traversal_cannot_escape_the_output(self, tmp_path):
        builder = self.builder(tmp_path)
        with pytest.raises(ContractError, match="outside the output tree"):
            builder.write_text("../escaped.txt", "no")

    def test_an_output_symlink_cannot_escape_the_output(self, tmp_path):
        builder = self.builder(tmp_path)
        outside = tmp_path / "outside"
        outside.mkdir()
        (builder.out / "link").symlink_to(outside, target_is_directory=True)
        with pytest.raises(ContractError, match="outside the output tree"):
            builder.write_text("link/escaped.txt", "no")


class TestValidation:
    def _site(self, tmp_path, name: str, text: str):
        (tmp_path / name).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / name).write_text(text, encoding="utf-8")

    def _page(self, body: str) -> str:
        return (
            "<!doctype html><html lang=en><head>"
            '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'">'
            f"<title>t</title></head><body>{body}</body></html>"
        )

    def test_a_clean_page_passes(self, tmp_path):
        self._site(tmp_path, "index.html", self._page("<h1>Only one</h1>"))
        assert check(tmp_path) == []

    def test_an_inline_style_is_reported(self, tmp_path):
        self._site(tmp_path, "index.html", self._page('<h1 style="color:red">x</h1>'))
        assert any("inline style" in problem for problem in check(tmp_path))

    def test_a_broken_link_is_reported(self, tmp_path):
        self._site(
            tmp_path, "index.html", self._page('<h1>x</h1><a href="gone/">g</a>')
        )
        assert any("does not resolve" in problem for problem in check(tmp_path))

    def test_a_link_that_only_differs_in_case_is_reported(self, tmp_path):
        # A case-insensitive developer filesystem would resolve this and the
        # server would not, so the check compares against the real file set.
        self._site(
            tmp_path, "index.html", self._page('<h1>x</h1><a href="Book/">b</a>')
        )
        self._site(tmp_path, "book/index.html", self._page("<h1>b</h1>"))
        assert any("does not resolve" in problem for problem in check(tmp_path))

    def test_a_link_to_the_site_root_resolves(self, tmp_path):
        self._site(tmp_path, "index.html", self._page("<h1>home</h1>"))
        self._site(
            tmp_path, "book/index.html", self._page('<h1>b</h1><a href="../">home</a>')
        )
        assert check(tmp_path) == []

    def test_an_uninformative_link_is_reported(self, tmp_path):
        self._site(
            tmp_path, "index.html", self._page('<h1>x</h1><a href="#a">Learn more</a>')
        )
        assert any("says nothing out of context" in p for p in check(tmp_path))

    def test_a_missing_heading_is_reported(self, tmp_path):
        self._site(tmp_path, "index.html", self._page("<p>no heading</p>"))
        assert any("top-level headings" in problem for problem in check(tmp_path))

    def test_an_image_without_alt_text_is_reported(self, tmp_path):
        self._site(tmp_path, "index.html", self._page('<h1>x</h1><img src="a.svg">'))
        assert any("alternative text" in problem for problem in check(tmp_path))
