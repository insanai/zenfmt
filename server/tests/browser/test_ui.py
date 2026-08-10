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
    expect(page.locator("[data-drop]")).to_contain_text("garbage.bin")
    page.click("button[data-action='convert']")
    alert = page.locator(".alert-error").first
    expect(alert).to_contain_text("CANNOT DETECT INPUT FORMAT")
    expect(alert).to_contain_text("core.undetectable-input-format")


def test_theme_choice_applies_and_persists(page: Page) -> None:
    html = page.locator("html")
    expect(page.locator("button[data-action='theme_system']")).to_have_class(
        re.compile("btn-active")
    )
    assert page.evaluate("localStorage.getItem('zenfmt-theme-v1')") is None
    page.click("button[data-action='theme_light']")
    expect(html).to_have_attribute("data-theme", "light")
    page.click("button[data-action='theme_dark']")
    expect(html).to_have_attribute("data-theme", "dark")
    page.reload()
    expect(html).to_have_attribute("data-theme", "dark")
    expect(page.locator("button[data-action='theme_dark']")).to_have_class(
        re.compile("btn-active")
    )
    page.click("button[data-action='theme_system']")
    page.emulate_media(color_scheme="dark")
    expect(html).to_have_attribute("data-theme", "dark")


def test_noscript_page_serves_the_api_path(page: Page, server_url: str) -> None:
    response = page.request.get(server_url + "/")
    body = response.text()
    assert "<noscript>" in body
    assert "curl -s -T" in body
    assert "content-security-policy" in response.headers
    assert "wasm-unsafe-eval" in response.headers["content-security-policy"]


def test_secure_login_and_user_management(secure_page: Page, secure_server) -> None:
    page = secure_page
    expect(page).to_have_url(re.compile(r"/login$"))
    expect(page.get_by_role("heading", name="Sign in")).to_be_visible()
    page.locator("input[name='name']").fill("admin")
    page.locator("input[name='password']").fill(secure_server.password)
    page.click("button[data-action='login']")

    expect(page).to_have_url(re.compile(r"/account$"))
    expect(page.get_by_text("Change the one-time password")).to_be_visible()
    page.locator("input[name='new_password']").fill("admin-release-password")
    page.click("button[data-action='change_password']")
    expect(page.get_by_text("Password changed.")).to_be_visible()

    page.click("button[data-action='nav:/admin/users']")
    expect(page).to_have_url(re.compile(r"/admin/users$"))
    expect(page.get_by_role("heading", name="Users")).to_be_visible()
    expect(page.locator("tbody")).to_contain_text("admin")

    page.click("button[data-action='manage_user:admin']")
    expect(page.locator("#user-dialog")).to_contain_text("last active administrator")
    expect(page.locator("select[name='manage_role']")).to_be_disabled()
    expect(page.locator("button[data-action='delete_user']")).to_be_disabled()
    page.click("button[data-action='close_user_dialog']")

    page.click("button[data-action='create_user_dialog']")
    expect(page.locator("#user-dialog")).to_have_attribute("open", "")
    page.locator("input[name='user_name']").fill("release-user")
    page.locator("select[name='user_role']").select_option("user")
    page.click("button[data-action='create_user']")
    expect(page.locator("#secret-dialog")).to_have_attribute("open", "")
    expect(page.locator("#secret-dialog")).to_contain_text("release-user")
    page.click("button[data-action='close_secret']")

    page.locator("input[name='user_query']").fill("release-user")
    page.click("button[data-action='filter_users']")
    expect(page.locator("tbody")).to_contain_text("release-user")
    page.click("button[data-action='manage_user:release-user']")
    page.locator("select[name='manage_role']").select_option("administrator")
    page.click("button[data-action='save_user']")
    expect(page.locator("tbody")).to_contain_text("administrator")

    page.click("button[data-action='manage_user:release-user']")
    page.click("button[data-action='reset_user']")
    expect(page.locator("#secret-dialog")).to_have_attribute("open", "")
    page.click("button[data-action='close_secret']")

    page.click("button[data-action='manage_user:release-user']")
    page.locator("select[name='manage_disabled']").select_option("true")
    page.click("button[data-action='save_user']")
    expect(page.locator("tbody")).to_contain_text("Disabled")

    page.click("button[data-action='manage_user:release-user']")
    page.locator("input[name='delete_confirm']").fill("release-user")
    page.click("button[data-action='delete_user']")
    expect(page.locator("tbody")).not_to_contain_text("release-user")
