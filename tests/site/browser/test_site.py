from __future__ import annotations

from playwright.sync_api import Browser, expect


def test_worker_conversion_is_local(browser: Browser, site_url: str) -> None:
    context = browser.new_context()
    page = context.new_page()
    workers: list[str] = []
    requests: list[str] = []
    page.on("worker", lambda worker: workers.append(worker.url))
    page.on("request", lambda request: requests.append(request.url))

    page.goto(site_url)
    expect(page.locator("[data-status]")).to_have_text("Ready. Choose a document.")
    assert len(workers) == 1
    assert "zenfmt.worker" in workers[0]

    requests.clear()
    page.locator("[data-example]").click()
    expect(page.locator('[data-status][data-state="complete"]')).to_contain_text(
        "converted locally"
    )
    expect(page.locator("[data-output]")).to_contain_text("# A first conversion")
    assert requests == []
    assert page.locator("[data-output]").evaluate("node => node.tagName") == "PRE"
    context.close()


def test_download_is_the_markdown_artifact(browser: Browser, site_url: str) -> None:
    context = browser.new_context(accept_downloads=True)
    page = context.new_page()
    page.goto(site_url)
    expect(page.locator("[data-status]")).to_have_text("Ready. Choose a document.")

    source = b"<h1>Converted heading</h1><p>Body text.</p>"
    page.locator("[data-source]").set_input_files(
        {"name": "report.html", "mimeType": "text/html", "buffer": source}
    )
    expect(page.locator('[data-status][data-state="complete"]')).to_contain_text(
        "converted locally"
    )
    expected = page.locator("[data-output]").text_content()
    with page.expect_download() as event:
        page.locator("[data-download]").click()
    download = event.value

    assert download.suggested_filename == "report.md"
    assert download.path().read_text(encoding="utf-8") == expected
    assert download.path().read_bytes() != source
    context.close()


def test_workspace_keeps_markdown_readable(browser: Browser, site_url: str) -> None:
    context = browser.new_context(viewport={"width": 1440, "height": 1000})
    page = context.new_page()
    page.goto(site_url)
    expect(page.locator("[data-status]")).to_have_text("Ready. Choose a document.")

    source = page.locator(".pane-input").bounding_box()
    output_pane = page.locator(".pane-output").bounding_box()
    output = page.locator("[data-output]").bounding_box()
    assert source is not None and output_pane is not None and output is not None
    ratio = output_pane["width"] / (source["width"] + output_pane["width"])
    assert 0.57 <= ratio <= 0.63
    assert output["width"] >= 640

    page.set_viewport_size({"width": 1000, "height": 1000})
    source = page.locator(".pane-input").bounding_box()
    output_pane = page.locator(".pane-output").bounding_box()
    assert source is not None and output_pane is not None
    assert output_pane["y"] > source["y"] + source["height"]

    page.set_viewport_size({"width": 390, "height": 844})
    navigation = page.get_by_role("navigation", name="Site")
    assert navigation.evaluate("node => node.scrollWidth <= node.clientWidth")
    expect(navigation.get_by_role("link", name="Security")).to_be_in_viewport()
    context.close()


def test_theme_search_help_and_downloads(browser: Browser, site_url: str) -> None:
    context = browser.new_context()
    page = context.new_page()
    page.goto(site_url)
    expect(page.locator("html")).to_have_class("theme-system")
    expect(page.get_by_label("Theme")).to_have_value("system")

    page.get_by_label("Theme").select_option("dark")
    expect(page.locator("html")).to_have_class("theme-dark")
    page.reload()
    expect(page.get_by_label("Theme")).to_have_value("dark")

    page.get_by_label("Theme").select_option("light")
    expect(page.locator("html")).to_have_class("theme-light")
    page.get_by_label("Theme").select_option("system")
    expect(page.locator("html")).to_have_class("theme-system")

    page.get_by_label("Search docs").fill("first conversion")
    result = page.locator("[data-search-results]")
    expect(result).to_be_visible()
    expect(result).to_contain_text("A Conversion, End to End")

    page.goto(f"{site_url}download/")
    wasm = page.get_by_role("link", name="Download WASM bundle")
    expect(wasm).to_have_attribute(
        "href",
        "https://github.com/insanai/zenfmt/releases/download/v0.3.7/"
        "zenfmt-0.3.7-wasm32-freestanding.tar.gz",
    )
    assert page.locator(".download-button").count() >= 11
    expect(page.get_by_role("link", name="Open npm")).to_have_attribute(
        "href", "https://www.npmjs.com/package/@insanai/zenfmt/v/0.3.7"
    )
    expect(page.get_by_role("link", name="Install with Homebrew")).to_be_visible()

    page.goto(f"{site_url}book/tour/")
    expect(page.locator(".docs-nav")).to_contain_text("The zenfmt book")
    expect(page.locator(".page-toc")).to_contain_text("On this page")
    expect(page.get_by_role("link", name="Download this PDF")).to_be_visible()
    context.close()


def test_browser_language_and_explicit_choice(browser: Browser, site_url: str) -> None:
    context = browser.new_context(locale="ja-JP")
    page = context.new_page()
    page.goto(site_url)

    expect(page).to_have_url(f"{site_url}ja/")
    expect(page.locator("html")).to_have_attribute("lang", "ja")
    expect(page.get_by_label("言語")).to_have_value("../ja/")
    expect(
        page.get_by_role("heading", name="ドキュメントを Markdown に変換。")
    ).to_be_visible()
    expect(page.locator("[data-status]")).to_have_text(
        "準備できました。ドキュメントを選択してください。"
    )

    with page.expect_navigation():
        page.get_by_label("言語").select_option(label="English")
    expect(page).to_have_url(site_url)
    expect(page.get_by_label("Language")).to_have_value("./")

    page.reload()
    expect(page).to_have_url(site_url)
    expect(page.locator("html")).to_have_attribute("lang", "en")
    context.close()


def test_localized_books_and_pdfs_are_linked(browser: Browser, site_url: str) -> None:
    context = browser.new_context()
    page = context.new_page()

    for locale, language, heading, pdf in (
        ("zh-hans", "zh-Hans", "zenfmt 中文文档", "zenfmt-book-zh-Hans.pdf"),
        ("ja", "ja", "zenfmt 日本語ドキュメント", "zenfmt-book-ja.pdf"),
        ("ko", "ko", "zenfmt 한국어 문서", "zenfmt-book-ko.pdf"),
    ):
        page.goto(f"{site_url}{locale}/book/")
        expect(page.locator("html")).to_have_attribute("lang", language)
        expect(page.locator(".chapter-title")).to_contain_text(heading)
        expect(page.locator(f'.docs-nav a[href$="{pdf}"]')).to_have_attribute(
            "href", f"../../pdf/{pdf}"
        )

    context.close()


def test_system_theme_and_zds_diagrams_render(browser: Browser, site_url: str) -> None:
    context = browser.new_context(color_scheme="dark")
    page = context.new_page()
    page.goto(f"{site_url}zds/0001-zds-process.html")

    expect(page.locator("html")).to_have_class("theme-system")
    assert page.evaluate("matchMedia('(prefers-color-scheme: dark)').matches")

    diagrams = page.locator("figure img")
    expect(diagrams).to_have_count(3)
    diagrams.first.scroll_into_view_if_needed()
    expect(diagrams.first).to_be_visible()
    dimensions = diagrams.first.evaluate(
        "async node => { await node.decode(); return "
        "{natural: node.naturalWidth, rendered: node.getBoundingClientRect().width}; }"
    )
    assert dimensions["natural"] > 100
    assert dimensions["rendered"] > 100
    context.close()


def test_unknown_input_gets_an_elm_style_error(browser: Browser, site_url: str) -> None:
    context = browser.new_context()
    page = context.new_page()
    page.goto(site_url)
    expect(page.locator("[data-status]")).to_have_text("Ready. Choose a document.")

    page.locator("[data-source]").set_input_files(
        {"name": "mystery.bin", "mimeType": "application/octet-stream", "buffer": b"?"}
    )
    expect(page.locator('[data-status][data-state="failed"]')).to_contain_text(
        "What you can do:"
    )
    expect(page.locator("[data-reports]")).to_contain_text("Details")
    expect(page.locator("[data-reports]")).to_contain_text("What you can do:")
    context.close()


def test_server_and_recorded_benchmarks_are_explained(
    browser: Browser, site_url: str
) -> None:
    context = browser.new_context()
    page = context.new_page()
    page.goto(site_url)

    server = page.locator(".server-summary")
    expect(server).to_contain_text("small HTTP service")
    expect(server).to_contain_text("zenfmt serve")
    expect(server).to_contain_text("System by default")
    expect(server).to_contain_text("7 targets")

    summary = page.locator(".benchmark-summary")
    expect(summary).to_contain_text("full release benchmark is incomplete")
    expect(summary).to_contain_text("Earlier reference run")
    expect(summary).to_contain_text("Native CLI")
    expect(summary).to_contain_text("Speed ratio")
    expect(summary).to_contain_text("CPU ratio")
    expect(summary).to_contain_text("Peak memory ratio")
    expect(summary).to_contain_text("Long-running server, measured separately")

    page.goto(f"{site_url}benchmark/")
    baseline = page.locator(".reference-baseline")
    expect(baseline).to_contain_text("Earlier reference native lens: zenfmt 0.3.3")
    expect(baseline).to_contain_text("Earlier reference server lens: zenfmt 0.3.3")
    expect(baseline).to_contain_text("Native CLI benchmark")
    expect(baseline).to_contain_text("Speed")
    expect(baseline).to_contain_text("CPU use")
    expect(baseline).to_contain_text("Peak memory")
    expect(baseline).to_contain_text("Long-running server benchmark")
    expect(baseline).to_contain_text("Docling parser only")
    expect(baseline).to_contain_text("Tika Server")
    context.close()
