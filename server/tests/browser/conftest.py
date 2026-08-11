"""Fixtures for the server interface smoke test (ZDS 0016).

Starts the real ``zenfmt serve`` binary on a free loopback port and hands
Playwright a Chromium page pointed at it. The binary must be built
(``zig build``); the fixture fails loudly when it is missing, because a
skipped smoke test looks exactly like a passing one in CI output.
"""

from __future__ import annotations

import socket
import subprocess
import tempfile
import time
import urllib.request
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import pytest
from playwright.sync_api import Browser, Page, sync_playwright

REPO_ROOT = Path(__file__).resolve().parents[3]
SERVER_BINARY = REPO_ROOT / "zig-out" / "bin" / "zenfmt"


def _free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@pytest.fixture(scope="session")
def server_url() -> Iterator[str]:
    if not SERVER_BINARY.exists():
        pytest.fail(f"{SERVER_BINARY} is not built; run `zig build` first")
    port = _free_port()
    with tempfile.TemporaryDirectory(prefix="zenfmt-open-ui-") as work_dir:
        process = subprocess.Popen(
            [str(SERVER_BINARY), "serve", "--port", str(port)],
            cwd=work_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        url = f"http://127.0.0.1:{port}"
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    with urllib.request.urlopen(f"{url}/readyz", timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    pass
                if time.monotonic() > deadline:
                    pytest.fail("the server did not become ready within 10 seconds")
                time.sleep(0.1)
            yield url
        finally:
            process.terminate()
            process.wait(timeout=10)


@pytest.fixture(scope="session")
def browser() -> Iterator[Browser]:
    with sync_playwright() as playwright:
        instance = playwright.chromium.launch(headless=True)
        yield instance
        instance.close()


@pytest.fixture()
def page(browser: Browser, server_url: str) -> Iterator[Page]:
    context = browser.new_context()
    page = context.new_page()
    errors: list[str] = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(server_url + "/")
    page.locator("[data-formats-ready='true']").wait_for()
    yield page
    assert not errors, "browser errors: " + "; ".join(errors)
    context.close()


@dataclass(frozen=True)
class SecureServer:
    url: str
    password: str


@pytest.fixture(scope="session")
def secure_server() -> Iterator[SecureServer]:
    if not SERVER_BINARY.exists():
        pytest.fail(f"{SERVER_BINARY} is not built; run `zig build` first")
    port = _free_port()
    with tempfile.TemporaryDirectory(prefix="zenfmt-secure-ui-") as data_dir:
        process = subprocess.Popen(
            [
                str(SERVER_BINARY),
                "serve",
                "--port",
                str(port),
                "--secure",
                "--data-dir",
                data_dir,
            ],
            cwd=data_dir,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert process.stderr is not None
        password = ""
        for _ in range(40):
            line = process.stderr.readline()
            if "password:" in line:
                password = line.split("password:", 1)[1].strip()
                break
        if not password:
            process.terminate()
            pytest.fail("secure server did not print its bootstrap password")

        url = f"http://127.0.0.1:{port}"
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    with urllib.request.urlopen(f"{url}/readyz", timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    pass
                if time.monotonic() > deadline:
                    pytest.fail("secure server did not become ready within 10 seconds")
                time.sleep(0.1)
            yield SecureServer(url=url, password=password)
        finally:
            process.terminate()
            process.wait(timeout=10)


@pytest.fixture()
def secure_page(browser: Browser, secure_server: SecureServer) -> Iterator[Page]:
    context = browser.new_context()
    page = context.new_page()
    errors: list[str] = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.goto(secure_server.url + "/")
    yield page
    assert not errors, "browser errors: " + "; ".join(errors)
    context.close()
