"""Dependency-free public-API smoke for a clean installed environment.

Run with ``python -I smoke.py``: imports only the standard library and
the installed ``zenfmt`` distribution, never the checkout. Exercises
import, version, capabilities, byte and path conversion with manifest
validation, a structured failure, a limit refusal, and a concurrent
conversion. Exits nonzero with a message on the first broken contract.
"""

from __future__ import annotations

import json
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def main() -> int:
    # A leaked checkout directory carries pyproject.toml (the python/
    # subproject) or build.zig.zon (the repository root).
    for entry in sys.path:
        for marker in ("pyproject.toml", "build.zig.zon"):
            if entry and (Path(entry) / marker).is_file():
                print(f"checkout leaked onto sys.path: {entry}")
                return 1

    import zenfmt

    package_dir = Path(zenfmt.__file__).resolve()
    print(f"zenfmt {zenfmt.__version__} from {package_dir.parent}", flush=True)

    formats = zenfmt.formats()
    readers = [f for f in formats if f.can_read]
    writers = [f for f in formats if f.can_write]
    assert len(readers) == 19, f"expected 19 readers, found {len(readers)}"
    assert [w.name for w in writers] == ["markdown"], writers

    conversion = zenfmt.convert(b"# Smoke\n\nbody with *emphasis*\n", name="smoke.md")
    assert conversion.text.startswith("# Smoke"), conversion.text
    assert conversion.source_format == "markdown"
    manifest = json.loads(conversion.manifest.raw)
    assert manifest["schema"] == "ai.insan.zenfmt.artifact-manifest"

    with tempfile.TemporaryDirectory() as scratch:
        output = Path(scratch) / "smoke.md"
        published = zenfmt.convert(
            b"plain paragraph\n", name="smoke.txt", output=output
        )
        assert published.path == output
        assert output.is_file()
        assert (Path(scratch) / "smoke.md.zenfmt.json").is_file()

    try:
        zenfmt.convert(b"x", from_="nope")
    except zenfmt.UnknownFormatError as error:
        assert error.code == "core.unknown-input-format"
        assert "What you can do:" in str(error)
    else:
        print("unknown format did not raise")
        return 1

    try:
        zenfmt.convert(
            b"# T\n\nbody\n",
            name="t.md",
            limits=zenfmt.Limits(max_output_bytes=1),
        )
    except zenfmt.LimitExceededError as error:
        assert error.exit_class == "limit"
    else:
        print("limit refusal did not raise")
        return 1

    converter = zenfmt.Converter()
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(
            pool.map(
                lambda i: (
                    converter.convert(f"# Doc {i}\n".encode(), name=f"d{i}.md").text
                ),
                range(8),
            )
        )
    assert all(results[i].startswith(f"# Doc {i}") for i in range(8))

    print("smoke-ok", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
