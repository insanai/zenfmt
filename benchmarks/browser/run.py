"""Pinned Chromium benchmark for the released zenfmt WebAssembly adapter.

The runner serves only the local checkout, loads the exact release module,
checks every browser artifact against the installed wheel's native memory API,
then records raw warm samples. Competitors remain explicit `not_benchmarked`
rows until a maintained browser artifact can satisfy the same file-to-Markdown
contract.
"""

from __future__ import annotations

import argparse
import functools
import gzip
import hashlib
import http.server
import json
import platform
import statistics
import subprocess
import threading
from pathlib import Path
from typing import ClassVar
from urllib.parse import quote

from playwright.sync_api import sync_playwright


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map: ClassVar[dict[str, str]] = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript; charset=utf-8",
    }

    def log_message(self, format: str, *args: object) -> None:
        del format, args


def percentile(samples: list[float], fraction: float) -> float:
    ordered = sorted(samples)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction))]


def native_digest(python: Path, source: Path, root: Path) -> str:
    result = subprocess.run(
        [
            str(python),
            "-I",
            str(root / "python/benchmarks/python_api.py"),
            "--artifact-sha256",
            str(source),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    digest = result.stdout.strip()
    if len(digest) != 64 or any(
        character not in "0123456789abcdef" for character in digest
    ):
        raise RuntimeError(
            f"native conversion of {source.name} returned an invalid digest"
        )
    return digest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument(
        "--python", type=Path, default=Path("benchmarks/.venv-wheel/bin/python")
    )
    parser.add_argument("--iterations", type=int, default=15)
    parser.add_argument("--file")
    parser.add_argument(
        "--out", type=Path, default=Path("benchmarks/results/wasm.json")
    )
    args = parser.parse_args()
    if args.iterations < 15:
        parser.error("publishable browser results require at least 15 iterations")

    root = args.root.resolve()
    wasm = root / "zig-out/wasm/zenfmt.wasm"
    adapter = root / "site/assets/js/zenfmt.js"
    corpus = root / "benchmarks/corpus"
    python = args.python if args.python.is_absolute() else root / args.python
    manifest = json.loads((root / "benchmarks/corpus.json").read_text())
    for required in (wasm, adapter, corpus, python):
        if not required.exists():
            raise RuntimeError(f"benchmark input is missing: {required}")

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=root)
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    base = f"http://{host}:{port}/"

    files = []
    browser_version = "unavailable"
    try:
        with sync_playwright() as runtime:
            browser = runtime.chromium.launch(headless=True)
            browser_version = browser.version
            page = browser.new_page()
            page.goto(base)
            cold = page.evaluate(
                """async ({ moduleUrl, adapterUrl }) => {
                  const fetchedAt = performance.now();
                  const response = await fetch(moduleUrl);
                  const bytes = await response.arrayBuffer();
                  const fetched = performance.now();
                  const module = await WebAssembly.compile(bytes);
                  const compiled = performance.now();
                  const api = await import(adapterUrl);
                  const converter = new api.Converter(module);
                  await converter.ready();
                  const ready = performance.now();
                  globalThis.benchmarkConverter = converter;
                  return {
                    fetch_ms: fetched - fetchedAt,
                    compile_ms: compiled - fetched,
                    instantiate_ms: ready - compiled,
                    first_ready_ms: ready - fetchedAt,
                  };
                }""",
                {
                    "moduleUrl": f"{base}zig-out/wasm/zenfmt.wasm",
                    "adapterUrl": f"{base}site/assets/js/zenfmt.js",
                },
            )

            entries = manifest["files"]
            if args.file:
                entries = [entry for entry in entries if entry["name"] == args.file]
                if not entries:
                    raise RuntimeError(f"unknown corpus file: {args.file}")
            for entry in entries:
                source = corpus / entry["name"]
                if not source.is_file():
                    raise RuntimeError(f"corpus file is missing: {source}")
                expected = native_digest(python, source, root)
                result = page.evaluate(
                    """async ({ sourceUrl, name, iterations }) => {
                      const input = new Uint8Array(await (await fetch(sourceUrl)).arrayBuffer());
                      for (let index = 0; index < 3; index += 1) {
                        await globalThis.benchmarkConverter.convert(input, { name });
                      }
                      const samples = [];
                      const digests = [];
                      let sourceFormat = null;
                      let highWaterPages = 0;
                      for (let index = 0; index < iterations; index += 1) {
                        const result = await globalThis.benchmarkConverter.convert(input, { name });
                        samples.push(result.elapsedMs);
                        sourceFormat = result.sourceFormat;
                        highWaterPages = Math.max(
                          highWaterPages,
                          globalThis.benchmarkConverter.memory.highWaterPages,
                        );
                        const digest = await crypto.subtle.digest('SHA-256', result.artifact);
                        digests.push(Array.from(new Uint8Array(digest), (byte) =>
                          byte.toString(16).padStart(2, '0')).join(''));
                      }
                      return { samples, digests, source_format: sourceFormat, high_water_pages: highWaterPages };
                    }""",
                    {
                        "sourceUrl": f"{base}benchmarks/corpus/{quote(entry['name'])}",
                        "name": entry["name"],
                        "iterations": args.iterations,
                    },
                )
                samples = result["samples"]
                stable = len(set(result["digests"])) == 1
                parity = stable and result["digests"][0] == expected
                if not parity:
                    raise RuntimeError(
                        f"WASM/native parity failed for {entry['name']}: "
                        f"native={expected}, wasm={result['digests'][0]}, stable={stable}"
                    )
                median = statistics.median(samples)
                files.append(
                    {
                        "name": entry["name"],
                        "format": entry["format"],
                        "bytes": entry["bytes"],
                        "correct": True,
                        "artifact_sha256": expected,
                        "source_format": result["source_format"],
                        "samples_ms": samples,
                        "median_ms": median,
                        "p95_ms": percentile(samples, 0.95),
                        "mad_ms": statistics.median(
                            abs(value - median) for value in samples
                        ),
                        "high_water_pages": result["high_water_pages"],
                    }
                )
            browser.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    wasm_bytes = wasm.read_bytes()
    output = {
        "schema": 1,
        "zenfmt_version": args.version,
        "git_revision": args.revision,
        "tool": {
            "name": "zenfmt",
            "target": "wasm32-freestanding",
            "optimization": "ReleaseSafe",
            "artifact_sha256": hashlib.sha256(wasm_bytes).hexdigest(),
            "raw_bytes": len(wasm_bytes),
            "gzip_bytes": len(gzip.compress(wasm_bytes, compresslevel=9, mtime=0)),
        },
        "environment": {
            "browser": f"Chromium {browser_version}",
            "os": platform.platform(),
            "architecture": platform.machine(),
            "cpu": platform.processor() or "unavailable",
            "power_mode": "unavailable",
            "runner": "local reference host",
        },
        "config": {"warmups": 3, "iterations": args.iterations},
        "cold": cold,
        "files": files,
        "competitors": [
            {
                "tool": "anydoc",
                "state": "not_benchmarked",
                "reason": "No pinned browser distribution exposes a maintained file-to-Markdown API contract.",
            },
            {
                "tool": "pandoc",
                "state": "not_benchmarked",
                "reason": "No maintained Pandoc WASM distribution meets the pinned harness contract.",
            },
        ],
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print(f"browser benchmark: {len(files)} parity-checked files -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
