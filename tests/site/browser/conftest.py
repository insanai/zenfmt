from __future__ import annotations

import contextlib
import functools
import http.server
import os
import threading
from collections.abc import Iterator
from pathlib import Path
from typing import ClassVar

import pytest
from playwright.sync_api import Browser, Playwright, sync_playwright


class SiteHandler(http.server.SimpleHTTPRequestHandler):
    extensions_map: ClassVar[dict[str, str]] = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript; charset=utf-8",
    }

    def log_message(self, format: str, *args: object) -> None:
        del format, args


@pytest.fixture(scope="session")
def site_url() -> Iterator[str]:
    public = os.environ.get("ZENFMT_SITE_URL")
    if public:
        yield public.rstrip("/") + "/"
        return
    site = Path("zig-out/site").resolve()
    if not (site / "index.html").is_file():
        pytest.fail(
            "zig-out/site is missing; run this through `zig build site-browser-test`"
        )

    handler = functools.partial(SiteHandler, directory=site)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}/"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


@pytest.fixture(scope="session")
def playwright_runtime() -> Iterator[Playwright]:
    with sync_playwright() as runtime:
        yield runtime


@pytest.fixture(scope="session")
def browser(playwright_runtime: Playwright) -> Iterator[Browser]:
    instance = playwright_runtime.chromium.launch(headless=True)
    try:
        yield instance
    finally:
        with contextlib.suppress(Exception):
            instance.close()
