"""Helpers for the installed-artifact release tests (ZDS 0014)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SMOKE = Path(__file__).parent / "release" / "smoke.py"


def run_uv(*argv: str, cwd: Path | None = None) -> None:
    completed = subprocess.run(
        ["uv", *argv],
        capture_output=True,
        text=True,
        cwd=cwd,
        check=False,
    )
    assert completed.returncode == 0, (
        f"uv {' '.join(argv)} failed:\n{completed.stdout}\n{completed.stderr}"
    )


def install_into_venv(venv: Path, artifact: Path) -> Path:
    """Creates a clean venv, installs one artifact, and returns the venv's
    python executable."""
    run_uv("venv", "-q", str(venv))
    run_uv("pip", "install", "-q", "--python", str(venv), str(artifact))
    if sys.platform == "win32":
        return venv / "Scripts" / "python.exe"
    return venv / "bin" / "python"


def run_smoke(python: Path, cwd: Path) -> str:
    completed = subprocess.run(
        [str(python), "-I", str(SMOKE)],
        capture_output=True,
        text=True,
        cwd=cwd,
        check=False,
    )
    assert completed.returncode == 0, (
        f"smoke failed:\n{completed.stdout}\n{completed.stderr}"
    )
    assert "smoke-ok" in completed.stdout
    return completed.stdout
