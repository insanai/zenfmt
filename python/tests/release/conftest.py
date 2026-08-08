"""Release-artifact fixtures: the wheel and sdist built into
``zig-out/python/dist`` by ``zig build python-check``."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
DIST = Path(
    os.environ.get("ZENFMT_DIST_DIR", REPO_ROOT / "zig-out" / "python" / "dist")
)


def _newest(pattern: str) -> Path:
    candidates = sorted(DIST.glob(pattern), key=lambda p: p.stat().st_mtime)
    if not candidates:
        pytest.skip(
            f"no {pattern} in {DIST}; run `zig build python-check` (or "
            "`zig build python-wheel`) first"
        )
    return candidates[-1]


@pytest.fixture(scope="session")
def wheel_path() -> Path:
    return _newest("zenfmt-*.whl")


@pytest.fixture(scope="session")
def sdist_path() -> Path:
    return _newest("zenfmt-*.tar.gz")
