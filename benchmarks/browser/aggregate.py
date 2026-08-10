"""Generate the versioned site benchmark record from raw result files."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def geometric_ratios(native: dict, other: str) -> tuple[int, dict[str, float | None]]:
    ratios: dict[str, list[float]] = {
        "wall_ratio": [],
        "cpu_ratio": [],
        "rss_ratio": [],
    }
    for file in native["files"]:
        tools = {row["tool"]: row for row in file["tools"]}
        ours = tools["zenfmt"]
        theirs = tools[other]
        if not ours["ok"] or not theirs["ok"]:
            continue
        pairs = (
            ("wall_ratio", "wall_ms"),
            ("cpu_ratio", "cpu_ms"),
            ("rss_ratio", "max_rss_mb"),
        )
        for ratio_name, metric in pairs:
            if ours[metric] > 0 and theirs[metric] > 0:
                ratios[ratio_name].append(theirs[metric] / ours[metric])
    shared = len(ratios["wall_ratio"])
    means = {
        name: (
            math.exp(sum(math.log(value) for value in values) / len(values))
            if values
            else None
        )
        for name, values in ratios.items()
    }
    return shared, means


def load_records(results: Path) -> tuple[dict[str, Path], dict[str, dict]]:
    paths = {
        "native": results / "latest.json",
        "python": results / "python.json",
        "wasm": results / "wasm.json",
        "stages": results / "stages.json",
        "server": results / "server.json",
        "corpus": Path("benchmarks/corpus.json"),
    }
    return paths, {name: json.loads(path.read_text()) for name, path in paths.items()}


def validate_identity(data: dict[str, dict], version: str, revision: str) -> None:
    wasm = data["wasm"]
    if wasm["zenfmt_version"] != version:
        raise RuntimeError("WASM benchmark version does not match the site release")
    if wasm["git_revision"] != revision:
        raise RuntimeError(
            "WASM benchmark revision does not match the requested revision"
        )
    if data["python"]["identity"]["wheel"]["version"] != version:
        raise RuntimeError("Python benchmark wheel is stale")
    if data["python"].get("git_revision") != revision:
        raise RuntimeError("Python benchmark revision does not match")

    native = data["native"]
    if native.get("version") != version:
        raise RuntimeError("Native benchmark version does not match")
    if native.get("git_revision") != revision:
        raise RuntimeError("Native benchmark revision does not match")
    if data["stages"].get("version") != version:
        raise RuntimeError("Stage benchmark version does not match")
    if data["stages"].get("git_revision") != revision:
        raise RuntimeError("Stage benchmark revision does not match")
    server = data["server"]
    if server.get("version") != version:
        raise RuntimeError("Server benchmark version does not match")
    if server.get("git_revision") != revision:
        raise RuntimeError("Server benchmark revision does not match")


def native_aggregates(native: dict) -> tuple[list[dict], dict[str, dict]]:
    coverage = []
    for tool in ("zenfmt", "docling", "anydoc", "pandoc", "zenfmt-python-wheel"):
        converted = sum(
            next(row for row in file["tools"] if row["tool"] == tool)["ok"]
            for file in native["files"]
        )
        coverage.append(
            {"tool": tool, "converted": converted, "total": len(native["files"])}
        )
    comparisons = {}
    for tool in ("docling", "anydoc", "pandoc", "zenfmt-python-wheel"):
        count, ratios = geometric_ratios(native, tool)
        comparisons[tool] = {"shared_files": count, **ratios}
    return coverage, comparisons


def headline_summary(coverage: list[dict]) -> str:
    by_tool = {row["tool"]: row["converted"] for row in coverage}
    return (
        f"On this {coverage[0]['total']}-file corpus, zenfmt converted "
        f"{by_tool['zenfmt']} files, Docling (parser only) converted "
        f"{by_tool['docling']}, AnyDoc converted {by_tool['anydoc']}, and Pandoc "
        f"converted {by_tool['pandoc']}. The method, shared-file timings, machine "
        "details, and raw samples are available below."
    )


def browser_aggregate(wasm: dict) -> dict:
    return {
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
    }


def server_aggregate(server: dict) -> dict:
    return {
        "tika_version": server["tika_version"],
        "startup": server["startup"],
        "peak_rss_mb": server["peak_rss_mb"],
        "files": server["files"],
        "throughput": server["throughput"],
    }


def aggregate_output(
    data: dict[str, dict], paths: dict[str, Path], version: str, revision: str
) -> dict:
    wasm = data["wasm"]
    coverage, comparisons = native_aggregates(data["native"])
    return {
        "schema": 1,
        "zenfmt_version": version,
        "git_revision": revision,
        "sources": {
            name: {"path": str(path), "sha256": digest(path)}
            for name, path in paths.items()
        },
        "aggregates": {
            "headline": {"summary": headline_summary(coverage)},
            "native": {"coverage": coverage, "comparisons": comparisons},
            "browser": browser_aggregate(wasm),
            "server": server_aggregate(data["server"]),
            "quality": {
                "rule": "nonempty UTF-8, stable artifact digest, and byte parity with the native memory API",
                "passed": len(wasm["files"]),
                "total": len(wasm["files"]),
            },
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--results", type=Path, default=Path("benchmarks/results"))
    args = parser.parse_args()

    paths, data = load_records(args.results)
    validate_identity(data, args.version, args.revision)
    output = aggregate_output(data, paths, args.version, args.revision)

    out = args.results / "site.json"
    out.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print(f"benchmark dashboard data -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
