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
    expect(page.locator("html")).to_have_class("theme-light")

    page.get_by_label("Theme").select_option("dark")
    expect(page.locator("html")).to_have_class("theme-dark")
    page.reload()
    expect(page.get_by_label("Theme")).to_have_value("dark")

    page.get_by_label("Search docs").fill("first conversion")
    result = page.locator("[data-search-results]")
    expect(result).to_be_visible()
    expect(result).to_contain_text("A Conversion, End to End")

    page.goto(f"{site_url}download/")
    wasm = page.get_by_role("link", name="Download WASM bundle")
    expect(wasm).to_have_attribute(
        "href",
        "https://github.com/insanai/zenfmt/releases/download/v0.3.0/"
        "zenfmt-0.3.0-wasm32-freestanding.tar.gz",
    )
    assert page.locator(".download-button").count() >= 11

    page.goto(f"{site_url}book/tour/")
    expect(page.locator(".docs-nav")).to_contain_text("The zenfmt book")
    expect(page.locator(".page-toc")).to_contain_text("On this page")
    expect(page.get_by_role("link", name="Download this PDF")).to_be_visible()
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
    expect(summary).to_contain_text("Recorded 0.3.0 Docling parser only")
    expect(summary).to_contain_text("Recorded 0.3.0 server startup")
    expect(summary).to_contain_text("Docling parser only")
    expect(summary).to_contain_text("5/16")
    expect(summary).to_contain_text("68.5×")
    expect(summary).to_contain_text("0.11 / 10.98 s")

    page.goto(f"{site_url}benchmark/")
    baseline = page.locator(".reference-baseline")
    expect(baseline).to_contain_text("Current release native lens: zenfmt 0.3.0")
    expect(baseline).to_contain_text("Current release server lens: zenfmt 0.3.0")
    expect(baseline).to_contain_text("Docling parser only")
    expect(baseline).to_contain_text("Tika Server")
    expect(baseline).to_contain_text("53.1 / 2147.5 MiB")
    context.close()
