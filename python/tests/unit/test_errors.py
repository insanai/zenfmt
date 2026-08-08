"""The Elm-style error contract: rendering, catalog coverage, chaining,
and the no-raw-exception-leak proof."""

from __future__ import annotations

import pytest
from support import FakeBridge, report_payload

import zenfmt
from zenfmt import _diagnostics
from zenfmt._errors import Direction, render_message


def test_render_message_answers_the_four_questions() -> None:
    text = render_message(
        title="Something Broke",
        problem="The value is wrong.",
        consequence="Nothing was written.",
        directions=(
            Direction(title="Fix it", explanation="Pass the right value."),
            Direction(
                title="Or reinstall",
                explanation="Run:",
                command=("pip", "install", "zenfmt"),
            ),
        ),
        context="argument `source`",
    )
    lines = text.splitlines()
    assert lines[0] == "SOMETHING BROKE"
    assert "The value is wrong." in text
    assert "argument `source`" in text
    assert "Nothing was written." in text
    assert "What you can do:" in text
    assert "pip install zenfmt" in text


def test_the_normative_invalid_source_example_renders() -> None:
    error = _diagnostics.invalid_source_type(7)
    text = str(error)
    assert text.startswith("INVALID SOURCE TYPE")
    assert "`source` must be a path, bytes-like object, or binary reader" in text
    assert "received `int`" in text
    assert "The conversion did not start" in text
    assert "What you can do:" in text
    assert 'Path("report.docx")' in text


def test_every_cataloged_failure_has_code_and_direction() -> None:
    cases = [
        _diagnostics.reader_failed(OSError("x")),
        _diagnostics.reader_returned_non_bytes("s"),
        _diagnostics.unsupported_platform("Plan9", "mips"),
        _diagnostics.bridge_missing("/pkg/_native/libzenfmt_py.so"),
        _diagnostics.bridge_load_failed("/pkg/x.so", OSError("bad elf")),
        _diagnostics.bridge_symbol_missing("zenfmt_py_convert", AttributeError()),
        _diagnostics.abi_mismatch(2, 0, required_major=1, minimum_minor=0),
        _diagnostics.version_mismatch("0.2.0", "0.1.0"),
        _diagnostics.runtime_mismatch("pointer width"),
        _diagnostics.capabilities_invalid("no formats"),
        _diagnostics.corrupt_result("empty"),
        _diagnostics.invalid_request(),
    ]
    for error in cases:
        assert isinstance(error, zenfmt.ZenfmtError)
        assert error.code.startswith("python.")
        assert error.directions, error.code
        assert error.hint
        text = str(error)
        assert "What you can do:" in text
        # No lazy placeholders: title, problem, consequence all present.
        assert error.title
        assert error.problem
        assert error.consequence


def test_exception_hierarchy_is_exactly_the_documented_tree() -> None:
    assert issubclass(zenfmt.ConversionError, zenfmt.ZenfmtError)
    assert issubclass(zenfmt.LimitExceededError, zenfmt.ConversionError)
    assert issubclass(zenfmt.UnknownFormatError, zenfmt.ConversionError)
    assert issubclass(zenfmt.DestinationExistsError, zenfmt.ConversionError)
    assert issubclass(zenfmt.InputReadError, zenfmt.ZenfmtError)
    assert issubclass(zenfmt.NativeLibraryError, zenfmt.ZenfmtError)
    assert issubclass(zenfmt.UnsupportedPlatformError, zenfmt.ZenfmtError)
    assert not issubclass(zenfmt.NativeLibraryError, zenfmt.ConversionError)


def test_conversion_error_facts_come_from_the_primary_report(
    fake_bridge: FakeBridge,
) -> None:
    note = report_payload(
        code="docx.comment-dropped",
        severity="note",
        exit_class="conversion",
        title="COMMENT DROPPED",
    )
    failure = report_payload()
    fake_bridge.queue({"status": 1, "exit_class": "usage", "reports": [note, failure]})
    with pytest.raises(zenfmt.ConversionError) as info:
        zenfmt.convert(b"# T\n")
    error = info.value
    # The primary report is the first error-severity report, not the note.
    assert error.primary_report.code == "core.unknown-input-format"
    assert error.title == "UNKNOWN INPUT FORMAT"
    assert [r.code for r in error.reports] == [
        "docx.comment-dropped",
        "core.unknown-input-format",
    ]
    assert error.details["report_codes"] == (
        "docx.comment-dropped",
        "core.unknown-input-format",
    )


def test_details_mapping_is_read_only() -> None:
    error = _diagnostics.bridge_missing("/x")
    with pytest.raises(TypeError):
        error.details["path"] = "other"  # type: ignore[index]


def test_no_raw_exception_leaks_through_expected_paths(
    fake_bridge: FakeBridge,
) -> None:
    """Corrupt native payloads surface as NativeLibraryError, never as
    bare JSONDecodeError / KeyError / UnicodeDecodeError."""
    # Reports JSON that does not parse.
    fake_bridge.queue({"status": 0, "exit_class": "conversion", "reports": None})
    fake_bridge.results[-1]["reports"] = object()  # json.dumps will fail

    class BadHandle:
        freed = 0

        def status(self) -> int:
            return 0

        def exit_class(self) -> str:
            return "conversion"

        def reports_json(self) -> bytes:
            return b"{not json"

        def free(self) -> None:
            self.freed += 1

    bad = BadHandle()
    fake_bridge.results.pop()
    fake_bridge.convert = (  # type: ignore[method-assign]
        lambda **kwargs: bad
    )
    with pytest.raises(zenfmt.NativeLibraryError):
        zenfmt.convert(b"# T\n")
    assert bad.freed == 1


def test_success_without_manifest_is_corrupt(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue({"status": 0, "exit_class": "conversion", "reports": []})
    with pytest.raises(zenfmt.NativeLibraryError, match="INCONSISTENT"):
        zenfmt.convert(b"# T\n")


@pytest.mark.parametrize(
    "reports",
    [
        {},
        ["not-an-object"],
        [report_payload(directions=[])],
        [report_payload(problem="")],
    ],
)
def test_malformed_report_payload_never_leaks_a_raw_exception(
    fake_bridge: FakeBridge, reports: object
) -> None:
    class BadReportsHandle:
        freed = 0

        def status(self) -> int:
            return 1

        def exit_class(self) -> str:
            return "conversion"

        def reports_json(self) -> bytes:
            import json

            return json.dumps(reports).encode()

        def free(self) -> None:
            self.freed += 1

    handle = BadReportsHandle()
    fake_bridge.convert = lambda **kwargs: handle  # type: ignore[method-assign]
    with pytest.raises(zenfmt.NativeLibraryError) as info:
        zenfmt.convert(b"# T\n")
    assert info.value.code == "python.corrupt-result"
    assert "What you can do:" in str(info.value)
    assert handle.freed == 1


def test_unknown_native_status_is_corrupt(fake_bridge: FakeBridge) -> None:
    fake_bridge.queue(
        {
            "status": 99,
            "exit_class": "conversion",
            "reports": [],
        }
    )
    with pytest.raises(zenfmt.NativeLibraryError, match="status tag"):
        zenfmt.convert(b"# T\n")
    assert fake_bridge.handles[-1].freed == 1


def test_success_decoder_failure_never_leaks_unicode_error(
    fake_bridge: FakeBridge,
) -> None:
    class BadTextHandle:
        freed = 0

        def status(self) -> int:
            return 0

        def exit_class(self) -> str:
            return "conversion"

        def reports_json(self) -> bytes:
            return b"[]"

        def manifest_json(self) -> bytes:
            return b"{}"

        def source_format(self) -> str:
            raise UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid")

        def free(self) -> None:
            self.freed += 1

    handle = BadTextHandle()
    fake_bridge.convert = lambda **kwargs: handle  # type: ignore[method-assign]
    with pytest.raises(zenfmt.NativeLibraryError) as info:
        zenfmt.convert(b"# T\n")
    assert info.value.code == "python.corrupt-result"
    assert "What you can do:" in str(info.value)
    assert handle.freed == 1


def test_process_control_exceptions_pass_through(
    fake_bridge: FakeBridge,
) -> None:
    class Interrupting:
        def read(self, size: int) -> bytes:
            raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        zenfmt.convert(Interrupting())
