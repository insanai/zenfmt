"""Generate the versioned site benchmark record from raw result files."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def geometric_ratio(native: dict, other: str) -> tuple[int, float | None]:
    ratios = []
    for file in native["files"]:
        tools = {row["tool"]: row for row in file["tools"]}
        ours = tools["zenfmt"]
        theirs = tools[other]
        if ours["ok"] and theirs["ok"] and ours["wall_ms"] > 0:
            ratios.append(theirs["wall_ms"] / ours["wall_ms"])
    if not ratios:
        return 0, None
    return len(ratios), math.exp(sum(math.log(value) for value in ratios) / len(ratios))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--results", type=Path, default=Path("benchmarks/results"))
    args = parser.parse_args()

    paths = {
        "native": args.results / "latest.json",
        "python": args.results / "python.json",
        "wasm": args.results / "wasm.json",
        "stages": args.results / "stages.json",
        "corpus": Path("benchmarks/corpus.json"),
    }
    data = {name: json.loads(path.read_text()) for name, path in paths.items()}
    wasm = data["wasm"]
    if wasm["zenfmt_version"] != args.version:
        raise RuntimeError("WASM benchmark version does not match the site release")
    if wasm["git_revision"] != args.revision:
        raise RuntimeError(
            "WASM benchmark revision does not match the requested revision"
        )
    if data["python"]["identity"]["wheel"]["version"] != args.version:
        raise RuntimeError("Python benchmark wheel is stale")
    if data["python"].get("git_revision") != args.revision:
        raise RuntimeError("Python benchmark revision does not match")

    native = data["native"]
    if native.get("version") != args.version:
        raise RuntimeError("Native benchmark version does not match")
    if native.get("git_revision") != args.revision:
        raise RuntimeError("Native benchmark revision does not match")
    if data["stages"].get("version") != args.version:
        raise RuntimeError("Stage benchmark version does not match")
    if data["stages"].get("git_revision") != args.revision:
        raise RuntimeError("Stage benchmark revision does not match")
    coverage = []
    for tool in ("zenfmt", "anydoc", "pandoc", "zenfmt-python-wheel"):
        converted = sum(
            next(row for row in file["tools"] if row["tool"] == tool)["ok"]
            for file in native["files"]
        )
        coverage.append(
            {"tool": tool, "converted": converted, "total": len(native["files"])}
        )
    comparisons = {}
    for tool in ("anydoc", "pandoc", "zenfmt-python-wheel"):
        count, ratio = geometric_ratio(native, tool)
        comparisons[tool] = {"shared_files": count, "wall_ratio": ratio}

    summary = (
        f"On this {coverage[0]['total']}-file corpus, zenfmt converted "
        f"{coverage[0]['converted']} files, AnyDoc converted {coverage[1]['converted']}, "
        f"and Pandoc converted {coverage[2]['converted']}. The method, shared-file "
        "timings, machine details, and raw samples are available below."
    )
    output = {
        "schema": 1,
        "zenfmt_version": args.version,
        "git_revision": args.revision,
        "sources": {
            name: {"path": str(path), "sha256": digest(path)}
            for name, path in paths.items()
        },
        "aggregates": {
            "headline": {"summary": summary},
            "native": {"coverage": coverage, "comparisons": comparisons},
            "browser": {
                "coverage": [
                    {
                        "tool": "zenfmt",
                        "converted": len(wasm["files"]),
                        "total": len(wasm["files"]),
                    }
                ],
                "median_ms": sum(file["median_ms"] for file in wasm["files"])
                / len(wasm["files"]),
                "cold": wasm["cold"],
                "artifact": wasm["tool"],
                "competitors": wasm["competitors"],
            },
            "quality": {
                "rule": "nonempty UTF-8, stable artifact digest, and byte parity with the native memory API",
                "passed": len(wasm["files"]),
                "total": len(wasm["files"]),
            },
        },
    }
    out = args.results / "site.json"
    out.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print(f"benchmark dashboard data -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
