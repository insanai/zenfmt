"""Wheel inspection (ZDS 0014): tags, typing marker, license, exactly one
bridge, and no development leakage."""

from __future__ import annotations

import zipfile
from pathlib import Path

import pytest

pytestmark = pytest.mark.release

BRIDGE_NAMES = {"libzenfmt_py.so", "libzenfmt_py.dylib", "zenfmt_py.dll"}
FORBIDDEN_FRAGMENTS = (
    "__pycache__",
    ".pytest_cache",
    ".pyc",
    "zig-cache",
    ".zig",
    "tests/",
    "conftest",
    ".env",
    "credential",
)


def test_wheel_contents(wheel_path: Path) -> None:
    with zipfile.ZipFile(wheel_path) as wheel:
        names = wheel.namelist()

        bridges = [
            name
            for name in names
            if name.startswith("zenfmt/_native/")
            and name.rsplit("/", 1)[-1] in BRIDGE_NAMES
        ]
        assert len(bridges) == 1, bridges

        assert "zenfmt/py.typed" in names
        assert any(name.endswith("METADATA") for name in names)
        assert any(name.endswith("RECORD") for name in names)
        assert any(
            "licenses/LICENSE" in name or name.endswith("LICENSE") for name in names
        ), names

        for name in names:
            lowered = name.lower()
            for fragment in FORBIDDEN_FRAGMENTS:
                assert fragment not in lowered, name

        wheel_metadata = next(
            wheel.read(name).decode()
            for name in names
            if name.endswith(".dist-info/WHEEL")
        )
        assert "Root-Is-Purelib: false" in wheel_metadata
        tag_line = next(
            line for line in wheel_metadata.splitlines() if line.startswith("Tag:")
        )
        assert "py3-none-" in tag_line
        assert "any" not in tag_line

        metadata = next(
            wheel.read(name).decode()
            for name in names
            if name.endswith(".dist-info/METADATA")
        )
        assert "Requires-Python: >=3.10" in metadata
        # No runtime dependencies, permanently.
        assert "Requires-Dist" not in metadata


def test_wheel_filename_carries_version_and_platform(wheel_path: Path) -> None:
    name = wheel_path.name
    assert name.startswith("zenfmt-")
    assert "-py3-none-" in name
    assert not name.endswith("any.whl")
