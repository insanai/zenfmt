"""Exercise a release zenfmt executable from an otherwise empty directory.

This is intentionally Python standard library only. Release runners copy the
single executable into a fresh temporary directory, give it a minimal PATH,
and prove conversion, the open server, embedded UI assets, secure bootstrap,
restart, and login without referring to the checkout at runtime.
"""

from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def wait_ready(base: str, process: subprocess.Popen[str]) -> None:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"server exited early with {process.returncode}")
        try:
            with urllib.request.urlopen(base + "/readyz", timeout=1) as response:
                if response.status == 200 and response.read() == b"ok\n":
                    return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    raise RuntimeError("server did not become ready within 15 seconds")


def stop(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        process.send_signal(signal.CTRL_BREAK_EVENT)
    else:
        process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def start_server(
    binary: Path,
    cwd: Path,
    env: dict[str, str],
    *extra: str,
) -> tuple[subprocess.Popen[str], str]:
    port = free_port()
    creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    process = subprocess.Popen(
        [str(binary), "serve", "--port", str(port), *extra],
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        creationflags=creationflags,
    )
    base = f"http://127.0.0.1:{port}"
    wait_ready(base, process)
    return process, base


def request(
    url: str,
    *,
    data: bytes | None = None,
    headers: dict[str, str] | None = None,
    opener: urllib.request.OpenerDirector | None = None,
) -> tuple[int, bytes, object]:
    req = urllib.request.Request(url, data=data, headers=headers or {})
    sender = opener.open if opener else urllib.request.urlopen
    with sender(req, timeout=10) as response:
        return response.status, response.read(), response.headers


def smoke(binary_source: Path, version: str, revision: str) -> None:
    with tempfile.TemporaryDirectory(prefix="zenfmt-release-smoke-") as raw:
        root = Path(raw)
        binary = root / ("zenfmt.exe" if os.name == "nt" else "zenfmt")
        shutil.copy2(binary_source.resolve(), binary)
        binary.chmod(0o755)
        env = {
            key: value
            for key, value in os.environ.items()
            if key in {"SYSTEMROOT", "WINDIR", "COMSPEC", "TMP", "TEMP", "LANG"}
        }
        env["PATH"] = str(root)

        actual = subprocess.check_output(
            [str(binary), "--version"], cwd=root, env=env, text=True
        ).strip()
        assert actual == f"zenfmt {version}", actual
        help_text = subprocess.check_output(
            [str(binary), "--help"], cwd=root, env=env, text=True
        )
        assert "zenfmt serve" in help_text

        source = root / "note.md"
        source.write_text("# Release smoke\n\nself contained\n", encoding="utf-8")
        converted = subprocess.check_output(
            [str(binary), "--stdout", str(source)], cwd=root, env=env
        )
        assert b"self contained" in converted

        process, base = start_server(binary, root, env)
        try:
            status, status_body, _ = request(base + "/api/v1/status")
            identity = json.loads(status_body)
            assert status == 200
            assert identity["version"] == version
            assert identity["revision"] == revision
            status, body, _ = request(
                base + "/api/v1/convert?to=markdown",
                data=b"# API smoke\n\nbody\n",
                headers={"X-Zenfmt-Name": "api.md"},
            )
            assert status == 200 and b"API smoke" in body
            status, shell, _ = request(base + "/")
            assert status == 200
            html = shell.decode("utf-8")
            assets = set(re.findall(r"/assets/[A-Za-z0-9_.-]+", html))
            assert len(assets) == 3, assets
            for asset in assets:
                asset_status, asset_body, _ = request(base + asset)
                assert asset_status == 200 and asset_body
        finally:
            stop(process)

        data_dir = root / "data"
        secure, secure_base = start_server(
            binary, root, env, "--secure", "--data-dir", str(data_dir)
        )
        assert secure.stderr is not None
        password = ""
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            line = secure.stderr.readline()
            if "password:" in line:
                password = line.split("password:", 1)[1].strip()
                break
        assert password, "bootstrap password was not printed"
        stop(secure)

        restarted, restarted_base = start_server(
            binary, root, env, "--secure", "--data-dir", str(data_dir)
        )
        try:
            jar = http.cookiejar.CookieJar()
            opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
            status, body, _ = request(
                restarted_base + "/api/v1/session",
                data=json.dumps({"name": "admin", "password": password}).encode(),
                headers={"Content-Type": "application/json"},
                opener=opener,
            )
            session = json.loads(body)
            assert status == 200
            assert session["role"] == "administrator"
            assert session["must_change_password"] is True
            shell_status, shell_body, _ = request(restarted_base + "/login")
            assert shell_status == 200 and b"zenfmt-ui-" in shell_body
        finally:
            stop(restarted)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("version")
    parser.add_argument("revision")
    args = parser.parse_args()
    smoke(args.binary, args.version, args.revision)
    print(f"release smoke passed: {args.binary} ({args.version})")


if __name__ == "__main__":
    main()
