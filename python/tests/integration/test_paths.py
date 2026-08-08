"""Filesystem behavior: Unicode paths, adjacent manifests, overwrite
refusal, and native limit enforcement through the public API."""

from __future__ import annotations

from pathlib import Path

import pytest

import zenfmt

pytestmark = pytest.mark.integration

FIXTURES = Path(__file__).parent / "fixtures"


def test_unicode_and_spaced_paths(tmp_path: Path) -> None:
    source = tmp_path / "übersicht 文档.md"
    source.write_bytes(b"# Titel\n\nInhalt\n")
    output = tmp_path / "out dir" / "übersicht.md"
    output.parent.mkdir()
    conversion = zenfmt.convert(source, output=output)
    assert conversion.path == output
    assert output.read_bytes().startswith(b"# Titel")


def test_valid_adjacent_manifest_is_loaded_silently(tmp_path: Path) -> None:
    source = tmp_path / "note.md"
    source.write_bytes(b"# T\n\nbody\n")
    first = zenfmt.convert(source)
    # The manifest of this exact input, adjacent under the documented name.
    (tmp_path / "note.md.zenfmt.json").write_bytes(first.manifest.raw)
    second = zenfmt.convert(source)
    assert not [r for r in second.reports if r.severity == "warning"]


def test_stale_adjacent_manifest_is_reported_and_ignored(
    tmp_path: Path,
) -> None:
    source = tmp_path / "note.md"
    source.write_bytes(b"# T\n\nbody\n")
    manifest = zenfmt.convert(source).manifest.raw
    source.write_bytes(b"# Different now\n")
    (tmp_path / "note.md.zenfmt.json").write_bytes(manifest)
    conversion = zenfmt.convert(source)
    assert "core.stale-or-invalid-manifest" in [r.code for r in conversion.reports]


def test_adjacent_manifest_never_probed_for_bytes(tmp_path: Path) -> None:
    # A poisoned adjacent file for the display name must not be read.
    (tmp_path / "note.md.zenfmt.json").write_bytes(b"{poison")
    conversion = zenfmt.convert(b"# T\n", name="note.md")
    assert not [r for r in conversion.reports if "manifest" in r.code]


def test_overwrite_refusal_and_explicit_replacement(tmp_path: Path) -> None:
    output = tmp_path / "out.md"
    zenfmt.convert(b"# One\n", name="a.md", output=output)
    with pytest.raises(zenfmt.DestinationExistsError) as info:
        zenfmt.convert(b"# Two\n", name="a.md", output=output)
    assert info.value.code == "core.destination-exists"
    assert output.read_bytes().startswith(b"# One")
    replaced = zenfmt.convert(b"# Two\n", name="a.md", output=output, overwrite=True)
    assert replaced.path == output
    assert output.read_bytes().startswith(b"# Two")


def test_native_input_limit_produces_limit_exceeded() -> None:
    with pytest.raises(zenfmt.LimitExceededError) as info:
        zenfmt.convert(
            b"x" * 128,
            name="big.txt",
            from_="text",
            limits=zenfmt.Limits(max_input_bytes=16),
        )
    assert info.value.code == "core.input-too-large"
    assert info.value.exit_class == "limit"


def test_native_output_limit_produces_limit_exceeded() -> None:
    with pytest.raises(zenfmt.LimitExceededError) as info:
        zenfmt.convert(
            b"# Title\n\nbody paragraph\n",
            name="note.md",
            limits=zenfmt.Limits(max_output_bytes=1),
        )
    assert info.value.code == "core.output-too-large"


def test_embedded_resources_round_trip_from_docx(tmp_path: Path) -> None:
    """The docx corpus file carries embedded media; when available, memory
    and path modes must expose the same resource bytes."""
    corpus = Path(__file__).resolve().parents[3] / "benchmarks/corpus/report.docx"
    if not corpus.is_file():
        pytest.skip("benchmark corpus not fetched")
    memory = zenfmt.convert(corpus)
    published = zenfmt.convert(corpus, output=tmp_path / "report.md")
    embedded_memory = [r for r in memory.resources if r.embedded]
    embedded_published = [r for r in published.resources if r.embedded]
    assert len(embedded_memory) == len(embedded_published)
    for from_memory, from_path in zip(embedded_memory, embedded_published, strict=True):
        assert from_memory.name == from_path.name
        assert from_memory.digest == from_path.digest
        assert from_memory.content == from_path.path.read_bytes()
