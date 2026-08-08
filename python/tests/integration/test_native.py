"""Bridge identity and capability parity against the real native library."""

from __future__ import annotations

import pytest

import zenfmt
from zenfmt import _capabilities, _loader
from zenfmt._limits import LIMIT_TABLE

pytestmark = pytest.mark.integration


def test_bridge_loads_and_verifies() -> None:
    bridge = _loader.bridge()
    assert bridge.abi_major == 1
    assert bridge.native_version == _loader.distribution_version()


def test_formats_report_the_full_default_bundle() -> None:
    formats = zenfmt.formats()
    readers = [f for f in formats if f.can_read]
    writers = [f for f in formats if f.can_write]
    assert len(readers) == 19
    assert [w.name for w in writers] == ["markdown"]
    markdown = writers[0]
    assert markdown.primary_extension == "md"
    assert markdown.text_writer is True
    by_name = {f.name: f for f in formats}
    assert by_name["docx"].seekable_input is True
    assert by_name["text"].seekable_input is False
    # Deterministic native registry order, text first.
    assert formats[0].name == "text"


def test_limit_table_parity_with_native_metadata() -> None:
    """The Python `Limits` table and the engine's limits agree on names
    and defaults, both directions."""
    caps = _capabilities.capabilities(_loader.bridge())
    native = caps.limits
    assert set(native) == set(LIMIT_TABLE)
    for name, (default, _cap) in LIMIT_TABLE.items():
        assert native[name] == default, name


def test_the_zds_byte_example_runs_unchanged() -> None:
    conversion = zenfmt.convert(
        b"A heading\n=========\n",
        from_="rst",
        to="markdown",
    )
    assert conversion.text.startswith("# A heading")


def test_strictness_grades_are_accepted_natively() -> None:
    for grade in ("off", "content", "structure", "exact"):
        conversion = zenfmt.convert(b"plain paragraph\n", name="note.txt", strict=grade)
        assert conversion.output_format == "markdown"
