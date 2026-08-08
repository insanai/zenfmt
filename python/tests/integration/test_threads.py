"""Concurrent conversions through one immutable Converter: the GIL is
released during native calls and independent calls never interfere."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

import zenfmt

pytestmark = pytest.mark.integration

FIXTURES = Path(__file__).parent / "fixtures"


def test_one_converter_across_threads_returns_identical_results() -> None:
    converter = zenfmt.Converter(strict=zenfmt.Strictness.OFF)
    sources = [
        (FIXTURES / "note.md").read_bytes(),
        (FIXTURES / "note.txt").read_bytes(),
        (FIXTURES / "table.csv").read_bytes(),
        (FIXTURES / "page.html").read_bytes(),
    ]
    names = ["note.md", "note.txt", "table.csv", "page.html"]
    reference = [
        converter.convert(data, name=name).content
        for data, name in zip(sources, names, strict=True)
    ]

    def convert_one(index: int) -> bytes:
        data = sources[index % len(sources)]
        name = names[index % len(names)]
        result = converter.convert(data, name=name)
        assert result.content is not None
        return result.content

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(convert_one, range(64)))

    for index, content in enumerate(results):
        assert content == reference[index % len(reference)]
