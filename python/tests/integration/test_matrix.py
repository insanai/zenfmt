"""Every registered reader into every registered writer, parameterized
from capability metadata (see conftest.pytest_generate_tests)."""

from __future__ import annotations

from collections.abc import Callable

import pytest

import zenfmt

pytestmark = pytest.mark.integration


def test_reader_writer_matrix(
    reader_name: str,
    writer_name: str,
    format_fixture: Callable[[str], object],
) -> None:
    fixture = format_fixture(reader_name)
    data = fixture.read_bytes()  # type: ignore[attr-defined]
    conversion = zenfmt.convert(
        data,
        name=fixture.name,  # type: ignore[attr-defined]
        from_=reader_name,
        to=writer_name,
    )
    assert conversion.source_format == reader_name
    assert conversion.output_format == writer_name
    assert conversion.content is not None
    assert conversion.manifest.artifact.format == writer_name
    assert conversion.manifest.source.format == reader_name
    # Detection over the same bytes selects the same reader.
    detected = zenfmt.convert(data, name=fixture.name)  # type: ignore[attr-defined]
    assert detected.source_format == reader_name
