"""The shared page shell and the content policy (ZDS 0015).

Typst emits content, not pages: it cannot write into the document head, so
every stylesheet reference, the policy, the metadata, and the navigation have
to be applied here anyway. That settles who owns the shell — this module does,
for the Typst-generated pages and the generated ones alike, so there is one
header rather than two that drift.

The policy below is the same string on every page, which is what makes it
checkable: a page that differs is a page something was allowed on.
"""

from __future__ import annotations

from dataclasses import dataclass

from . import routes

# What a document policy can enforce, and only that.
#
# GitHub Pages serves static files and sets no headers we control, so the
# policy travels in the document. That leaves `frame-ancestors`, `sandbox`, and
# violation reporting unavailable — they are ignored in a meta policy — and the
# site therefore has no clickjacking protection. ZDS 0015 records that as an
# accepted gap rather than implying otherwise, and the security page says so in
# words.
#
# `wasm-unsafe-eval` is the one allowance: Chromium requires it to instantiate
# WebAssembly under a restrictive script-src, and other engines ignore the
# token. `trusted-types` is free protection given the output window never uses
# innerHTML — it turns a regression there into a runtime failure.
CONTENT_SECURITY_POLICY = "; ".join(
    [
        "default-src 'none'",
        "base-uri 'none'",
        "object-src 'none'",
        "form-action 'none'",
        "frame-src 'none'",
        "img-src 'self'",
        "font-src 'self'",
        "style-src 'self'",
        "script-src 'self' 'wasm-unsafe-eval'",
        "worker-src 'self'",
        "connect-src 'self'",
        "manifest-src 'self'",
        "trusted-types zenfmt-worker",
        "require-trusted-types-for 'script'",
    ]
)

NAV = [
    ("", "Convert"),
    ("benchmark/", "Benchmarks"),
    ("download/", "Download"),
    ("book/", "Book"),
    ("zds/", "ZDS"),
    ("security/", "Security"),
]


@dataclass
class Page:
    route: str
    title: str
    description: str
    body: str
    stylesheets: list[str]
    scripts: list[str] = None  # type: ignore[assignment]
    toc: list[tuple[int, str, str]] = None  # type: ignore[assignment]
    absolute_base: str | None = None
    wasm_url: str | None = None
    adapter_url: str | None = None
    worker_url: str | None = None
    search_url: str | None = None


def render(page: Page, *, version: str) -> str:
    """One complete HTML document."""
    link = _linker(page)
    head = [
        "<!doctype html>",
        '<html lang="en" class="theme-system">',
        "<head>",
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        (
            '<meta http-equiv="Content-Security-Policy" '
            f'content="{CONTENT_SECURITY_POLICY}">'
        ),
        f"<title>{_escape(page.title)}</title>",
        f'<meta name="description" content="{_escape(page.description)}">',
        f'<meta name="generator" content="zenfmt {_escape(version)}">',
        # The shell starts in System mode so the stylesheet can follow the
        # operating system before JavaScript applies a stored preference.
        '<meta name="color-scheme" content="light dark">',
    ]
    for sheet in page.stylesheets:
        head.append(f'<link rel="stylesheet" href="{link(sheet)}">')
    for script in page.scripts or []:
        # The runtime URLs travel as data attributes rather than being written
        # into the script, so the fingerprinted names stay a build concern and
        # the script itself is the same bytes on every page.
        extra = ""
        if page.wasm_url:
            extra += f' data-wasm="{link(page.wasm_url)}"'
        if page.adapter_url:
            extra += f' data-adapter="{link(page.adapter_url)}"'
        if page.worker_url:
            extra += f' data-worker="{link(page.worker_url)}"'
        if page.search_url:
            extra += f' data-search="{link(page.search_url)}"'
        head.append(f'<script type="module" src="{link(script)}"{extra}></script>')
    head.append("</head>")

    body = [
        "<body>",
        '<a class="skip-link" href="#main">Skip to content</a>',
        _header(page, link),
        '<main id="main">',
        _main(page, link),
        "</main>",
        _footer(link, version),
        "</body>",
        "</html>",
    ]
    return "\n".join(head + body) + "\n"


def _linker(page: Page):
    """Relative for every page but the not-found document, which is served
    for a path of unknown depth and so cannot use one."""
    if page.absolute_base is not None:
        return lambda target: routes.absolute(page.absolute_base, target)
    return lambda target: routes.relative(page.route, target)


def _header(page: Page, link) -> str:
    items = []
    for route, label in NAV:
        current = (
            ' aria-current="page"'
            if routes.normalize(route) == routes.normalize(page.route)
            else ""
        )
        items.append(f'<li><a href="{link(route)}"{current}>{label}</a></li>')
    return (
        '<header class="site-header">'
        f'<a class="site-mark" href="{link("")}">zenfmt</a>'
        '<nav aria-label="Site"><ul>' + "".join(items) + "</ul></nav>"
        '<div class="site-tools">'
        '<label class="search-label" for="site-search">Search docs</label>'
        '<input id="site-search" class="site-search" type="search" '
        'placeholder="Search Book and ZDS" autocomplete="off" data-search-input>'
        '<label class="theme-label" for="theme-select">Theme</label>'
        '<select id="theme-select" class="theme-select" data-theme-select>'
        '<option value="system" selected>System</option>'
        '<option value="light">Light</option><option value="dark">Dark</option>'
        "</select>"
        "</div>"
        '<div class="search-results" data-search-results hidden></div>'
        "</header>"
    )


def _main(page: Page, link) -> str:
    if not page.toc:
        return page.body

    toc = "".join(
        f'<li class="toc-level-{level}"><a href="#{_escape(anchor)}">'
        f"{_escape(label)}</a></li>"
        for level, anchor, label in page.toc
        if level in (2, 3)
    )
    if page.route.startswith("book/"):
        collection = "The zenfmt book"
        collection_link = link("book/")
        pdf = link("pdf/zenfmt-book.pdf")
    else:
        collection = "Zen Discussions"
        collection_link = link("zds/")
        stem = page.route.rsplit("/", 1)[-1].removesuffix(".html")
        pdf = link(f"pdf/zds-{stem}.pdf")

    return (
        '<div class="docs-layout">'
        '<aside class="docs-nav" aria-label="Documentation">'
        f'<p class="docs-kicker">{_escape(collection)}</p>'
        f'<p><a href="{collection_link}">Browse contents</a></p>'
        f'<p><a href="{link("book/")}">Book</a></p>'
        f'<p><a href="{link("zds/")}">Design records</a></p>'
        f'<p><a href="{pdf}">Download this PDF</a></p>'
        f'<p><a href="{link("")}">Try in browser</a></p>'
        "</aside>"
        f'<article class="docs-content">{page.body}</article>'
        '<aside class="page-toc" aria-label="On this page">'
        '<p class="docs-kicker">On this page</p>'
        f"<ol>{toc}</ol>"
        "</aside>"
        "</div>"
    )


def _footer(link, version: str) -> str:
    return (
        '<footer class="site-footer">'
        f"<p>zenfmt {_escape(version)} — documents convert in your browser; "
        "nothing is uploaded.</p>"
        f'<p><a href="{link("security/")}">Security and privacy</a> · '
        f'<a href="{link("zds/")}">Design records</a> · '
        '<a href="https://github.com/insanai/zenfmt">Source</a></p>'
        "</footer>"
    )


def _escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )
