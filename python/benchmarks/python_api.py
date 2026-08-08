"""Installed-wheel benchmark worker (ZDS 0014).

Runs against the clean-installed ``zenfmt`` wheel only — never the
checkout (`-I` keeps it off ``sys.path``) and never a bridge from
``zig-out``. Two modes:

``--convert FILE``
    One cold conversion for the parent harness's child-process row:
    import, convert to memory, consume the full public result, exit 0/1.

``--suite``
    The detailed profile suite: identity, artifact parity against the
    same-revision CLI, cold and warm profiles, path publication,
    diagnostic rendering, a tiny boundary microbenchmark (reported
    separately), and a thread-count sweep. Writes
    ``benchmarks/results/python.json``; a parity mismatch marks the
    sample, is excluded from aggregates, and exits nonzero after the
    results are written.

Cold and warm numbers answer different questions and are never merged.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import statistics
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import zenfmt


def consume(conversion: zenfmt.Conversion) -> int:
    """Touches every part of the public result so a sample prices the
    complete API, not a lazy shell."""
    total = len(conversion.content or b"")
    total += len(conversion.manifest.raw)
    total += sum(len(report.code) for report in conversion.reports)
    total += sum(len(resource.digest) for resource in conversion.resources)
    return total


def cold_convert(path: str) -> int:
    conversion = zenfmt.convert(path)
    return 0 if consume(conversion) >= 0 else 1


# ------------------------------------------------------------------ suite


def corpus_files(corpus: Path) -> list[Path]:
    supported = {
        extension
        for entry in zenfmt.formats()
        if entry.can_read
        for extension in entry.extensions
    }
    return sorted(
        path
        for path in corpus.iterdir()
        if path.is_file()
        and not path.name.startswith(".")
        and path.suffix.removeprefix(".") in supported
    )


def identity(wheel_dir: Path | None) -> dict:
    from zenfmt import _loader

    bridge = _loader.bridge()
    wheel: dict = {}
    if wheel_dir is not None and wheel_dir.is_dir():
        wheels = sorted(wheel_dir.glob("zenfmt-*.whl"))
        if wheels:
            newest = wheels[-1]
            wheel = {
                "filename": newest.name,
                "sha256": hashlib.sha256(newest.read_bytes()).hexdigest(),
            }
    return {
        "wheel": wheel
        | {
            "version": zenfmt.__version__,
            "location": str(Path(zenfmt.__file__).parent),
        },
        "native": {
            "version": bridge.native_version,
            "abi_major": bridge.abi_major,
            "abi_minor": bridge.abi_minor,
        },
        "interpreter": {
            "implementation": sys.implementation.name,
            "version": ".".join(map(str, sys.version_info[:3])),
        },
        "platform": sys.platform,
    }


def first_difference(label: str, ours: object, theirs: object) -> str:
    return f"{label}: {str(ours)[:80]!r} != {str(theirs)[:80]!r}"


def parity_check(files: list[Path], cli: Path | None) -> dict:
    entries = []
    all_ok = True
    for path in files:
        entry: dict = {"name": path.name, "ok": True}
        try:
            memory = zenfmt.convert(path)
            with tempfile.TemporaryDirectory() as scratch:
                # Publish under the memory result's own artifact name so
                # deterministic `<stem>_media/` targets inside the artifact
                # agree; only the destination representation may differ.
                published = zenfmt.convert(path, output=Path(scratch) / memory.name)
                checks: list[tuple[str, object, object]] = [
                    ("source_format", memory.source_format, published.source_format),
                    ("output_format", memory.output_format, published.output_format),
                    (
                        "artifact_digest",
                        memory.manifest.artifact.digest,
                        published.manifest.artifact.digest,
                    ),
                    (
                        "report_codes",
                        [r.code for r in memory.reports],
                        [r.code for r in published.reports],
                    ),
                    (
                        "resources",
                        [(r.name, r.digest) for r in memory.resources],
                        [(r.name, r.digest) for r in published.resources],
                    ),
                ]
            if cli is not None:
                completed = subprocess.run(
                    [str(cli), str(path), "--stdout", "--quiet"],
                    capture_output=True,
                    check=False,
                )
                if completed.returncode == 0 and not memory.resources:
                    # Stream output intentionally skips media projection,
                    # so byte parity holds only for media-free documents.
                    checks.append(("cli_artifact", memory.content, completed.stdout))
            for label, ours, theirs in checks:
                if ours != theirs:
                    entry["ok"] = False
                    entry["difference"] = first_difference(label, ours, theirs)
                    break
        except zenfmt.ZenfmtError as error:
            entry["ok"] = False
            entry["difference"] = f"conversion failed: {error.code}"
        all_ok = all_ok and entry["ok"]
        entries.append(entry)
    return {"ok": all_ok, "files": entries}


def timed(callable_, iterations: int) -> dict:
    callable_()  # discarded warm-up
    samples = []
    for _ in range(iterations):
        gc.collect()
        started = time.perf_counter_ns()
        callable_()
        samples.append((time.perf_counter_ns() - started) / 1e6)
    return {
        "samples_ms": [round(s, 4) for s in samples],
        "median_ms": round(statistics.median(samples), 4),
    }


def timed_subprocess(argv: list[str], iterations: int) -> dict:
    def run() -> None:
        completed = subprocess.run(argv, capture_output=True, check=False)
        if completed.returncode != 0:
            raise RuntimeError(completed.stderr.decode()[:400])

    return timed(run, iterations)


def profile_suite(files: list[Path], iterations: int, cli: Path | None) -> dict:
    profiles: dict = {}
    python = sys.executable

    profiles["cold_import"] = timed_subprocess(
        [python, "-I", "-c", "import zenfmt; zenfmt.__version__"],
        iterations,
    )
    if files:
        sample = str(files[0])
        profiles["cold_first_conversion"] = timed_subprocess(
            [
                python,
                "-I",
                "-c",
                "import sys, zenfmt\n"
                "conversion = zenfmt.Converter().convert(sys.argv[1])\n"
                "assert conversion.manifest.raw\n",
                sample,
            ],
            iterations,
        )

    converter = zenfmt.Converter()
    warm_path: dict = {}
    warm_bytes: dict = {}
    publication: dict = {}
    for path in files:
        preloaded = path.read_bytes()
        warm_path[path.name] = timed(
            lambda p=path: consume(converter.convert(str(p))), iterations
        )
        warm_bytes[path.name] = timed(
            lambda d=preloaded, n=path.name: consume(converter.convert(d, name=n)),
            iterations,
        )

        def publish(p: Path = path) -> None:
            with tempfile.TemporaryDirectory() as scratch:
                consume(converter.convert(p, output=Path(scratch) / "out.md"))

        publication[path.name] = timed(publish, iterations)
    profiles["warm_path_memory"] = warm_path
    profiles["warm_bytes_memory"] = warm_bytes
    profiles["path_publication"] = publication

    def diagnostics() -> None:
        try:
            zenfmt.convert(b"x", from_="nope")
        except zenfmt.UnknownFormatError as error:
            assert str(error)
        try:
            zenfmt.convert(
                b"# T\n\nbody\n",
                name="t.md",
                limits=zenfmt.Limits(max_output_bytes=1),
            )
        except zenfmt.LimitExceededError as error:
            assert str(error)

    profiles["diagnostic_failure"] = timed(diagnostics, iterations)

    # The boundary microbenchmark: parsing work is negligible, so FFI,
    # validation, copies, and model construction dominate. Reported under
    # its own key and never used to claim corpus throughput.
    profiles["micro"] = {
        "tiny_text_to_markdown": timed(
            lambda: consume(converter.convert(b"tiny\n", name="tiny.txt")),
            iterations,
        )
    }
    return profiles


def concurrency_sweep(files: list[Path], iterations: int) -> list[dict]:
    if not files:
        return []
    converter = zenfmt.Converter()
    preloaded = [(path.name, path.read_bytes()) for path in files]
    rounds = max(iterations, 2)
    results = []
    for workers in (1, 2, 4, 8):
        jobs = preloaded * rounds

        def convert_one(job: tuple[str, bytes]) -> int:
            name, data = job
            return consume(converter.convert(data, name=name))

        started = time.perf_counter_ns()
        with ThreadPoolExecutor(max_workers=workers) as pool:
            consumed = list(pool.map(convert_one, jobs))
        wall_ms = (time.perf_counter_ns() - started) / 1e6
        assert all(value >= 0 for value in consumed)
        results.append(
            {
                "threads": workers,
                "documents": len(jobs),
                "wall_ms": round(wall_ms, 2),
                "docs_per_s": round(len(jobs) / (wall_ms / 1000), 2),
            }
        )
    return results


def run_suite(arguments: argparse.Namespace) -> int:
    corpus = Path(arguments.corpus)
    files = corpus_files(corpus) if corpus.is_dir() else []
    cli = Path(arguments.zenfmt_cli) if arguments.zenfmt_cli else None
    if cli is not None and not cli.is_file():
        cli = None

    parity = parity_check(files, cli)
    ok_files = [
        path for path, entry in zip(files, parity["files"], strict=True) if entry["ok"]
    ]

    document = {
        "schema": 1,
        "identity": identity(
            Path(arguments.wheel_dir) if arguments.wheel_dir else None
        ),
        "config": {
            "iterations": arguments.iterations,
            "warmup": 1,
            "corpus": str(corpus),
            "corpus_files": [path.name for path in files],
        },
        "parity": parity,
        "profiles": profile_suite(ok_files, arguments.iterations, cli),
        "concurrency": concurrency_sweep(ok_files, arguments.iterations),
    }

    out = Path(arguments.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(document, indent=1) + "\n", encoding="utf-8")
    print(f"written to {out}")
    if not parity["ok"]:
        failed = [e["name"] for e in parity["files"] if not e["ok"]]
        print(f"parity FAILED for: {', '.join(failed)}", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--convert", metavar="FILE")
    parser.add_argument("--suite", action="store_true")
    parser.add_argument("--corpus", default="benchmarks/corpus")
    parser.add_argument("--out", default="benchmarks/results/python.json")
    parser.add_argument("--zenfmt-cli", default="zig-out/bin/zenfmt")
    parser.add_argument("--wheel-dir", default="zig-out/python/dist")
    parser.add_argument("--iterations", type=int, default=5)
    arguments = parser.parse_args()
    if arguments.convert:
        return cold_convert(arguments.convert)
    if arguments.suite:
        return run_suite(arguments)
    parser.error("one of --convert or --suite is required")
    return 2


if __name__ == "__main__":
    sys.exit(main())
