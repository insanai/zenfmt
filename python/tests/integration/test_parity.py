"""Memory/path parity and CLI artifact parity against the same release."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

import zenfmt

pytestmark = pytest.mark.integration

FIXTURES = Path(__file__).parent / "fixtures"


def test_memory_and_path_publication_agree(tmp_path: Path) -> None:
    data = (FIXTURES / "note.md").read_bytes()
    memory = zenfmt.convert(data, name="note.md")
    published = zenfmt.convert(data, name="note.md", output=tmp_path / "note.md")

    assert memory.content == (tmp_path / "note.md").read_bytes()
    assert memory.manifest.artifact.digest == published.manifest.artifact.digest
    assert memory.manifest.raw == (tmp_path / "note.md.zenfmt.json").read_bytes()
    assert [r.code for r in memory.reports] == [r.code for r in published.reports]
    assert memory.source_format == published.source_format
    assert memory.output_format == published.output_format


def test_python_and_cli_artifacts_are_identical(
    cli_binary: Path, tmp_path: Path
) -> None:
    fixture = FIXTURES / "min.docx"
    memory = zenfmt.convert(fixture)
    completed = subprocess.run(
        [str(cli_binary), str(fixture), "--stdout"],
        capture_output=True,
        check=True,
    )
    assert completed.stdout == memory.content


def test_docx_fixture_converts_with_manifest_digests(tmp_path: Path) -> None:
    conversion = zenfmt.convert(FIXTURES / "min.docx", output=tmp_path / "d.md")
    assert conversion.manifest.source.format == "docx"
    assert len(conversion.manifest.source.digest) == 64
    assert (tmp_path / "d.md").is_file()
    assert (tmp_path / "d.md.zenfmt.json").is_file()
