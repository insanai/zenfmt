"""The interface smoke test (ZDS 0016, Interface and release gates).

Drives the real wasm interface against the real server: convert a fixture
through the module, assert the report-panel text, and exercise the theme
selector including persistence across a reload.
"""

from __future__ import annotations

import re

from playwright.sync_api import Page, expect

FIXTURE_NAME = "note.md"
FIXTURE_BYTES = b"# Smoke\n\nA **bold** word.\n\n- one\n- two\n"


def test_converter_renders_from_wasm(page: Page) -> None:
    expect(page.locator("[data-drop]")).to_contain_text("Drop a document")
    expect(page.locator("button[data-action='convert']")).to_be_visible()
    # The writer select is populated from /api/v1/formats by the module.
    expect(page.locator("select[name='to'] option")).to_have_count(1)


def test_conversion_round_trip(page: Page) -> None:
    page.set_input_files(
        "#file-input",
        files=[
            {
                "name": FIXTURE_NAME,
                "mimeType": "text/markdown",
                "buffer": FIXTURE_BYTES,
            }
        ],
    )
    expect(page.locator("[data-drop]")).to_contain_text(FIXTURE_NAME)
    page.click("button[data-action='convert']")
    expect(page.locator(".zf-preview")).to_contain_text("A **bold** word.")
    expect(page.locator(".card-title").last).to_contain_text("note.md")
    expect(page.locator("button[data-action='download']")).to_be_visible()


def test_failure_reports_render_verbatim(page: Page) -> None:
    page.set_input_files(
        "#file-input",
        files=[
            {
                "name": "garbage.bin",
                "mimeType": "application/octet-stream",
                "buffer": b"not a document at all",
            }
        ],
    )
    page.click("button[data-action='convert']")
    alert = page.locator(".alert-error").first
    expect(alert).to_contain_text("CANNOT DETECT INPUT FORMAT")
    expect(alert).to_contain_text("core.undetectable-input-format")


def test_theme_choice_applies_and_persists(page: Page) -> None:
    html = page.locator("html")
    page.click("button[data-action='theme_dark']")
    expect(html).to_have_attribute("data-theme", "dark")
    page.reload()
    expect(html).to_have_attribute("data-theme", "dark")
    expect(page.locator("button[data-action='theme_dark']")).to_have_class(
        re.compile("btn-active")
    )
    page.click("button[data-action='theme_system']")


def test_noscript_page_serves_the_api_path(page: Page, server_url: str) -> None:
    response = page.request.get(server_url + "/")
    body = response.text()
    assert "<noscript>" in body
    assert "curl -s -T" in body
    assert "content-security-policy" in response.headers
    assert "wasm-unsafe-eval" in response.headers["content-security-policy"]
