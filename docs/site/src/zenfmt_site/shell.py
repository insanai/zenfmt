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

LANGUAGES = (
    ("en", "English"),
    ("zh-Hans", "简体中文"),
    ("ja", "日本語"),
    ("ko", "한국어"),
)

SHELL_TEXT = {
    "en": {
        "skip": "Skip to content",
        "nav": ("Convert", "Benchmarks", "Download", "Book", "ZDS", "Security"),
        "site": "Site",
        "search": "Search docs",
        "search_placeholder": "Search Book and ZDS",
        "theme": "Theme",
        "system": "System",
        "light": "Light",
        "dark": "Dark",
        "language": "Language",
        "documentation": "Documentation",
        "book": "The zenfmt book",
        "records": "Zen Discussions",
        "browse": "Browse contents",
        "design_records": "Design records",
        "download_pdf": "Download this PDF",
        "try": "Try in browser",
        "on_page": "On this page",
        "footer": "documents convert in your browser; nothing is uploaded.",
        "privacy": "Security and privacy",
        "source": "Source",
    },
    "zh-Hans": {
        "skip": "跳到正文",
        "nav": ("转换", "性能测试", "下载", "文档", "ZDS", "安全"),
        "site": "网站导航",
        "search": "搜索文档",
        "search_placeholder": "搜索文档和 ZDS",
        "theme": "主题",
        "system": "跟随系统",
        "light": "浅色",
        "dark": "深色",
        "language": "语言",
        "documentation": "文档",
        "book": "zenfmt 中文文档",
        "records": "Zen Discussions",
        "browse": "浏览目录",
        "design_records": "设计记录（英文）",
        "download_pdf": "下载本语言 PDF",
        "try": "在浏览器中试用",
        "on_page": "本页目录",
        "footer": "文档在浏览器本地转换，不会上传。",
        "privacy": "安全与隐私",
        "source": "源代码",
    },
    "ja": {
        "skip": "本文へ移動",
        "nav": (
            "変換",
            "ベンチマーク",
            "ダウンロード",
            "ドキュメント",
            "ZDS",
            "セキュリティ",
        ),
        "site": "サイト",
        "search": "ドキュメントを検索",
        "search_placeholder": "ドキュメントと ZDS を検索",
        "theme": "テーマ",
        "system": "システム",
        "light": "ライト",
        "dark": "ダーク",
        "language": "言語",
        "documentation": "ドキュメント",
        "book": "zenfmt 日本語ドキュメント",
        "records": "Zen Discussions",
        "browse": "目次を見る",
        "design_records": "設計記録（英語）",
        "download_pdf": "日本語 PDF をダウンロード",
        "try": "ブラウザで試す",
        "on_page": "このページの内容",
        "footer": "ドキュメントはブラウザ内で変換され、アップロードされません。",
        "privacy": "セキュリティとプライバシー",
        "source": "ソースコード",
    },
    "ko": {
        "skip": "본문으로 이동",
        "nav": ("변환", "벤치마크", "다운로드", "문서", "ZDS", "보안"),
        "site": "사이트",
        "search": "문서 검색",
        "search_placeholder": "문서와 ZDS 검색",
        "theme": "테마",
        "system": "시스템 설정",
        "light": "라이트",
        "dark": "다크",
        "language": "언어",
        "documentation": "문서",
        "book": "zenfmt 한국어 문서",
        "records": "Zen Discussions",
        "browse": "목차 보기",
        "design_records": "설계 기록 (영어)",
        "download_pdf": "한국어 PDF 다운로드",
        "try": "브라우저에서 사용해 보기",
        "on_page": "이 페이지의 내용",
        "footer": "문서는 브라우저에서 변환되며 업로드되지 않습니다.",
        "privacy": "보안과 개인정보 보호",
        "source": "소스 코드",
    },
}


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
    locale: str = "en"
    language_links: dict[str, str] | None = None


def render(page: Page, *, version: str) -> str:
    """One complete HTML document."""
    link = _linker(page)
    head = [
        "<!doctype html>",
        f'<html lang="{_escape(page.locale)}" class="theme-system" '
        f'data-locale="{_escape(page.locale)}">',
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
        f'<a class="skip-link" href="#main">{_text(page)["skip"]}</a>',
        _header(page, link),
        '<main id="main">',
        _main(page, link),
        "</main>",
        _footer(link, version, page),
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
    words = _text(page)
    items = []
    for (route, _), label in zip(NAV, words["nav"], strict=True):
        route = _locale_route(page.locale, route)
        current = (
            ' aria-current="page"'
            if routes.normalize(route) == routes.normalize(page.route)
            else ""
        )
        items.append(f'<li><a href="{link(route)}"{current}>{label}</a></li>')
    return (
        '<header class="site-header">'
        f'<a class="site-mark" href="{link(_locale_prefix(page.locale))}">zenfmt</a>'
        f'<nav aria-label="{words["site"]}"><ul>' + "".join(items) + "</ul></nav>"
        '<div class="site-tools">'
        f'<label class="search-label" for="site-search">{words["search"]}</label>'
        '<input id="site-search" class="site-search" type="search" '
        f'placeholder="{words["search_placeholder"]}" autocomplete="off" '
        "data-search-input>"
        f'<label class="theme-label" for="theme-select">{words["theme"]}</label>'
        '<select id="theme-select" class="theme-select" data-theme-select>'
        f'<option value="system" selected>{words["system"]}</option>'
        f'<option value="light">{words["light"]}</option>'
        f'<option value="dark">{words["dark"]}</option>'
        "</select>"
        f'<label class="language-label" for="language-select">'
        f"{words['language']}</label>"
        '<select id="language-select" class="language-select" data-language-select>'
        + _language_options(page, link)
        + "</select>"
        + "</div>"
        + '<div class="search-results" data-search-results hidden></div>'
        + "</header>"
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
    words = _text(page)
    locale_prefix = _locale_prefix(page.locale)
    if page.route.startswith(f"{locale_prefix}book/"):
        collection = words["book"]
        collection_link = link(f"{locale_prefix}book/")
        suffix = "" if page.locale == "en" else f"-{page.locale}"
        pdf = link(f"pdf/zenfmt-book{suffix}.pdf")
    else:
        collection = words["records"]
        collection_link = link("zds/")
        stem = page.route.rsplit("/", 1)[-1].removesuffix(".html")
        pdf = link(f"pdf/zds-{stem}.pdf")

    return (
        '<div class="docs-layout">'
        f'<aside class="docs-nav" aria-label="{words["documentation"]}">'
        f'<p class="docs-kicker">{_escape(collection)}</p>'
        f'<p><a href="{collection_link}">{words["browse"]}</a></p>'
        f'<p><a href="{link(f"{locale_prefix}book/")}">{words["book"]}</a></p>'
        f'<p><a href="{link("zds/")}">{words["design_records"]}</a></p>'
        f'<p><a href="{pdf}">{words["download_pdf"]}</a></p>'
        f'<p><a href="{link(locale_prefix)}">{words["try"]}</a></p>'
        "</aside>"
        f'<article class="docs-content">{page.body}</article>'
        f'<aside class="page-toc" aria-label="{words["on_page"]}">'
        f'<p class="docs-kicker">{words["on_page"]}</p>'
        f"<ol>{toc}</ol>"
        "</aside>"
        "</div>"
    )


def _footer(link, version: str, page: Page | None = None) -> str:
    words = _text(page)
    locale_prefix = _locale_prefix(page.locale if page else "en")
    return (
        '<footer class="site-footer">'
        f"<p>zenfmt {_escape(version)} · {words['footer']}</p>"
        f'<p><a href="{link(f"{locale_prefix}security/")}">{words["privacy"]}</a> · '
        f'<a href="{link("zds/")}">{words["design_records"]}</a> · '
        f'<a href="https://github.com/insanai/zenfmt">{words["source"]}</a></p>'
        "</footer>"
    )


def _text(page: Page | None) -> dict:
    locale = page.locale if page and page.locale in SHELL_TEXT else "en"
    return SHELL_TEXT[locale]


def _locale_prefix(locale: str) -> str:
    return "" if locale == "en" else f"{locale.lower()}/"


def _locale_route(locale: str, route: str) -> str:
    if route == "zds/":
        return route
    return _locale_prefix(locale) + route


def _language_options(page: Page, link) -> str:
    links = page.language_links or {}
    options = []
    for locale, label in LANGUAGES:
        target = links.get(locale, _locale_prefix(locale))
        selected = " selected" if locale == page.locale else ""
        options.append(
            f'<option value="{link(target)}" data-locale="{locale}"{selected}>'
            f"{label}</option>"
        )
    return "".join(options)


def _escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )
