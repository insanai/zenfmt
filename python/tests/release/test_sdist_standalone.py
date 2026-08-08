"""Standalone source distribution (ZDS 0014): the sdist unpacks outside
the checkout, builds a wheel with only its own contents plus Zig, and the
result passes the public smoke suite. An sdist that reaches for
parent-directory monorepo files is invalid."""

from __future__ import annotations

import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest
from release_support import install_into_venv, run_smoke

pytestmark = pytest.mark.release

REQUIRED_MEMBERS = (
    "pyproject.toml",
    "hatch_build.py",
    "LICENSE",
    "src/zenfmt/__init__.py",
    "tests/release/smoke.py",
    "engine/build.zig",
    "engine/build.zig.zon",
    "engine/bindings/python/abi.zig",
    "engine/core/src/root.zig",
    "engine/src/root.zig",
    "engine/formats/markdown/src/writer.zig",
)
FORBIDDEN_MEMBERS = (
    "docs/",
    "benchmarks/",
    "zig-out/",
    ".github/",
    "cli/",
    "engine/zig-out/",
    "engine/docs/",
    "engine/cli/",
)


def test_sdist_file_list_is_standalone(sdist_path: Path) -> None:
    with tarfile.open(sdist_path) as archive:
        names = [name.split("/", 1)[1] for name in archive.getnames() if "/" in name]
    for required in REQUIRED_MEMBERS:
        assert any(name == required for name in names), required
    for forbidden in FORBIDDEN_MEMBERS:
        assert not any(name.startswith(forbidden) for name in names), forbidden
    # No prebuilt bridge binaries ride along.
    assert not any(name.endswith((".so", ".dylib", ".dll")) for name in names)


def test_sdist_builds_a_working_wheel_outside_the_checkout(
    sdist_path: Path, tmp_path: Path
) -> None:
    if shutil.which("zig") is None:
        pytest.skip("zig is required to build the sdist")
    with tarfile.open(sdist_path) as archive:
        archive.extractall(tmp_path, filter="data")
    unpacked = next(tmp_path.glob("zenfmt-*"))

    dist = tmp_path / "dist"
    completed = subprocess.run(
        [
            "uv",
            "build",
            "--wheel",
            "--no-sources",
            "--out-dir",
            str(dist),
        ],
        capture_output=True,
        text=True,
        cwd=unpacked,
        check=False,
    )
    assert completed.returncode == 0, f"{completed.stdout}\n{completed.stderr}"
    wheel = next(dist.glob("zenfmt-*.whl"))

    venv = tmp_path / "sdist-venv"
    python = install_into_venv(venv, wheel)
    run_smoke(python, cwd=tmp_path)
