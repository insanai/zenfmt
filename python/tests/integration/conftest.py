"""Integration fixtures: the real host bridge staged by
``zig build python-sync``. Every test here is marked ``integration``.

The reader/writer matrix is parameterized from live capability metadata
at collection time, so an unexpected new native format creates required
cases automatically. A missing document fixture is a visible skip
locally and a failure under the strict release gate
(``ZENFMT_REQUIRE_ALL_FORMATS=1``)."""

from __future__ import annotations

import os
from collections.abc import Callable
from pathlib import Path

import pytest

import zenfmt

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).parent / "fixtures"
CORPUS = REPO_ROOT / "benchmarks" / "corpus"

REQUIRE_ALL = os.environ.get("ZENFMT_REQUIRE_ALL_FORMATS") == "1"


def collect_fixture(format_entry: zenfmt.Format) -> Path | None:
    """The committed fixture for a reader, falling back to the benchmark
    corpus for formats no open tool can write (`xlsb`)."""
    for directory in (FIXTURES, CORPUS):
        if not directory.is_dir():
            continue
        for extension in format_entry.extensions:
            for candidate in sorted(directory.glob(f"*.{extension}")):
                return candidate
    return None


def fixture_or_report(format_entry: zenfmt.Format) -> Path:
    found = collect_fixture(format_entry)
    if found is None:
        message = (
            f"no fixture for reader `{format_entry.name}` "
            f"(extensions: {', '.join(format_entry.extensions)}); run "
            "benchmarks/fetch_corpus.sh to provide one"
        )
        if REQUIRE_ALL:
            pytest.fail(message)
        pytest.skip(message)
    return found


@pytest.fixture
def format_fixture() -> Callable[[str], Path]:
    formats = {entry.name: entry for entry in zenfmt.formats()}

    def resolve(name: str) -> Path:
        return fixture_or_report(formats[name])

    return resolve


def pytest_generate_tests(metafunc: pytest.Metafunc) -> None:
    if {"reader_name", "writer_name"} <= set(metafunc.fixturenames):
        try:
            formats = zenfmt.formats()
            cases = [
                (reader.name, writer.name)
                for reader in formats
                if reader.can_read
                for writer in formats
                if writer.can_write
            ]
        except zenfmt.ZenfmtError as error:
            reason = f"native bridge unavailable at collection: {error.code}"
            cases = []
            metafunc.parametrize(
                ("reader_name", "writer_name"),
                [
                    pytest.param(
                        "none",
                        "none",
                        marks=pytest.mark.skip(reason=reason),
                    )
                ],
            )
            return
        metafunc.parametrize(
            ("reader_name", "writer_name"),
            cases,
            ids=[f"{reader}-to-{writer}" for reader, writer in cases],
        )


@pytest.fixture(scope="session")
def cli_binary() -> Path:
    path = REPO_ROOT / "zig-out" / "bin" / "zenfmt"
    if not path.is_file():
        pytest.skip("zig-out/bin/zenfmt is not built; run `zig build`")
    return path
