"""Clean-environment wheel installation (ZDS 0014): the installed package
works with the checkout absent from ``sys.path``, from a path with spaces
and non-ASCII characters, and from a read-only package directory."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest
from release_support import install_into_venv, run_smoke

pytestmark = pytest.mark.release


def test_wheel_installs_and_passes_smoke(wheel_path: Path, tmp_path: Path) -> None:
    # A venv path with a space and non-ASCII characters, per the wheel
    # inspection contract.
    venv = tmp_path / "smoke venv ü"
    python = install_into_venv(venv, wheel_path)
    output = run_smoke(python, cwd=tmp_path)
    assert "zenfmt " in output
    # The loaded package is the installed one, not the checkout.
    assert str(venv) in output


def test_wheel_works_from_read_only_site_packages(
    wheel_path: Path, tmp_path: Path
) -> None:
    if sys.platform == "win32":
        pytest.skip("POSIX permission bits only")
    venv = tmp_path / "readonly-venv"
    python = install_into_venv(venv, wheel_path)
    package_dirs = list(venv.glob("lib/python*/site-packages/zenfmt"))
    assert package_dirs, "installed package directory not found"
    stripped: list[tuple[Path, int]] = []
    try:
        for directory in package_dirs:
            for path in [directory, *directory.rglob("*")]:
                mode = path.stat().st_mode
                stripped.append((path, mode))
                path.chmod(mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
        run_smoke(python, cwd=tmp_path)
    finally:
        for path, mode in reversed(stripped):
            path.chmod(mode)


def test_installed_package_needs_no_toolchain(wheel_path: Path, tmp_path: Path) -> None:
    """Conversion works with Zig and the dev tools hidden from PATH."""
    venv = tmp_path / "no-toolchain"
    python = install_into_venv(venv, wheel_path)
    environment = dict(os.environ)
    environment["PATH"] = str(python.parent)
    completed = subprocess.run(
        [
            str(python),
            "-I",
            "-c",
            "import zenfmt; print(zenfmt.convert(b'# T\\n', name='t.md').text)",
        ],
        capture_output=True,
        text=True,
        env=environment,
        cwd=tmp_path,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.startswith("# T")
