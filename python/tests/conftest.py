"""Shared fixtures: the fake bridge seam (ZDS 0014).

Unit tests never touch ctypes or a real library. The seam is the verified
bridge object returned by ``zenfmt._loader.bridge()``.
"""

from __future__ import annotations

import pytest
from support import FakeBridge

import zenfmt._loader as loader_module


@pytest.fixture(autouse=True)
def _no_stale_bridge(monkeypatch: pytest.MonkeyPatch) -> None:
    """No test inherits a previously loaded bridge singleton."""
    monkeypatch.setattr(loader_module, "_bridge", None)


@pytest.fixture
def fake_bridge(monkeypatch: pytest.MonkeyPatch) -> FakeBridge:
    bridge = FakeBridge()
    monkeypatch.setattr(loader_module, "_bridge", bridge)
    return bridge
