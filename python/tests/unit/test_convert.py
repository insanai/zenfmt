"""The conversion call through the fake bridge: options JSON, results,
failures, and handle release."""

from __future__ import annotations

from pathlib import Path

import pytest
from support import (
    FakeBridge,
    media_entry,
    report_payload,
    success_payload,
)

import zenfmt


def test_memory_success_returns_the_full_ensemble(
    fake_bridge: FakeBridge,
) -> None:
    png = b"\x89PNGdata"
    fake_bridge.queue(
        success_payload(
            artifact=b"![a](note_media/image-1.png)\n",
            media=[media_entry("note_media/image-1.png", png)],
            resources=[("note_media/image-1.png", png, "ab" * 32)],
        )
    )
    conversion = zenfmt.convert(b"# T\n", name="note.md")
    assert conversion.content == b"![a](note_media/image-1.png)\n"
    assert conversion.path is None
    assert conversion.name == "note.md"
    assert conversion.source_format == "markdown"
    assert conversion.output_format == "markdown"
    assert len(conversion.resources) == 1
    resource = conversion.resources[0]
    assert resource.embedded
    assert resource.name == "note_media/image-1.png"
    assert resource.content == png
    assert resource.path is None
    assert conversion.text.startswith("![a]")


def test_options_json_is_deterministic_and_versioned(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())
    zenfmt.convert(b"# T\n", name="note.md", to="markdown", strict="exact")
    options = fake_bridge.requests[-1]["options"]
    assert options["schema"] == 1
    assert options["output"] == {"kind": "memory", "artifact_name": "note.md"}
    assert options["to"] == "markdown"
    assert options["strict"] == "exact"
    assert options["overwrite"] is False
    assert "limits" not in options


def test_limits_cross_completely_when_supplied(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())
    zenfmt.convert(b"# T\n", limits=zenfmt.Limits(max_depth=32))
    limits = fake_bridge.requests[-1]["options"]["limits"]
    assert limits["max_depth"] == 32
    assert limits["max_output_bytes"] == 512 * 1024 * 1024
    assert len(limits) == 22


def test_path_output_returns_path_and_no_content(
    fake_bridge: FakeBridge, tmp_path: Path
) -> None:
    fake_bridge.queue(success_payload(memory=False, artifact_name="out.md"))
    target = tmp_path / "out.md"
    conversion = zenfmt.convert(b"# T\n", output=target)
    assert conversion.path == target
    assert conversion.content is None
    assert conversion.name == "out.md"
    with pytest.raises(TypeError, match="TEXT IS ONLY FOR MEMORY OUTPUT"):
        _ = conversion.text
    request = fake_bridge.requests[-1]
    assert request["options"]["output"] == {"kind": "path"}
    assert request["output_path"] is not None


def test_path_output_projects_resource_paths(
    fake_bridge: FakeBridge, tmp_path: Path
) -> None:
    png = b"\x89PNGdata"
    fake_bridge.queue(
        success_payload(
            memory=False,
            artifact_name="out.md",
            media=[media_entry("out_media/image-1.png", png)],
        )
    )
    conversion = zenfmt.convert(b"# T\n", output=tmp_path / "out.md")
    resource = conversion.resources[0]
    assert resource.content is None
    assert resource.path == tmp_path / "out_media/image-1.png"


def test_external_resources_are_never_fetched(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(
        success_payload(
            media=[
                media_entry(
                    "https://example.test/chart.svg",
                    b"",
                    kind="external",
                    mime="image/svg+xml",
                )
            ],
        )
    )
    conversion = zenfmt.convert(b"# T\n")
    resource = conversion.resources[0]
    assert resource.external
    assert resource.content is None
    assert resource.path is None
    assert resource.name == "https://example.test/chart.svg"


def test_artifact_name_derivation_for_memory_output(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())
    zenfmt.convert(b"data", name="report.docx")
    assert fake_bridge.requests[-1]["options"]["output"]["artifact_name"] == "report.md"
    fake_bridge.queue(success_payload())
    zenfmt.convert(b"data")
    assert (
        fake_bridge.requests[-1]["options"]["output"]["artifact_name"] == "artifact.md"
    )


def test_output_suffix_selects_the_writer_when_to_is_absent(
    fake_bridge: FakeBridge, tmp_path: Path
) -> None:
    fake_bridge.queue(success_payload(memory=False))
    zenfmt.convert(b"data", output=tmp_path / "page.markdown")
    assert fake_bridge.requests[-1]["options"]["to"] == "markdown"


def test_failed_status_raises_conversion_error_with_reports(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(
        {
            "status": 1,
            "exit_class": "usage",
            "reports": [report_payload()],
        }
    )
    with pytest.raises(zenfmt.UnknownFormatError) as info:
        zenfmt.convert(b"# T\n", from_="nope")
    error = info.value
    assert error.code == "core.unknown-input-format"
    assert error.exit_class == "usage"
    assert len(error.reports) == 1
    assert error.primary_report.code == "core.unknown-input-format"
    assert "What you can do:" in str(error)
    assert error.hint


def test_limit_exit_class_raises_limit_exceeded(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(
        {
            "status": 1,
            "exit_class": "limit",
            "reports": [
                report_payload(code="core.output-too-large", exit_class="limit")
            ],
        }
    )
    with pytest.raises(zenfmt.LimitExceededError):
        zenfmt.convert(b"# T\n")


def test_destination_exists_maps_to_its_class(
    fake_bridge: FakeBridge, tmp_path: Path
) -> None:
    fake_bridge.queue(
        {
            "status": 1,
            "exit_class": "conversion",
            "reports": [
                report_payload(code="core.destination-exists", exit_class="conversion")
            ],
        }
    )
    with pytest.raises(zenfmt.DestinationExistsError):
        zenfmt.convert(b"# T\n", output=tmp_path / "x.md")


def test_invalid_request_status_is_a_native_library_error(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue({"status": 2, "exit_class": "usage", "reports": []})
    with pytest.raises(zenfmt.NativeLibraryError, match="ABI"):
        zenfmt.convert(b"# T\n")


def test_handle_released_on_success_and_on_every_failure(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())
    zenfmt.convert(b"# T\n")
    fake_bridge.queue(
        {"status": 1, "exit_class": "usage", "reports": [report_payload()]}
    )
    with pytest.raises(zenfmt.ConversionError):
        zenfmt.convert(b"# T\n")
    # A corrupt success also releases its handle.
    fake_bridge.queue({"status": 0, "exit_class": "conversion", "reports": []})
    with pytest.raises(zenfmt.NativeLibraryError):
        zenfmt.convert(b"# T\n")
    assert [handle.freed for handle in fake_bridge.handles] == [1, 1, 1]


def test_converter_policy_applies_and_call_overrides_win(
    fake_bridge: FakeBridge,
) -> None:
    converter = zenfmt.Converter(
        strict=zenfmt.Strictness.STRUCTURE,
        limits=zenfmt.Limits(max_input_bytes=64),
    )
    fake_bridge.queue(success_payload())
    converter.convert(b"# T\n")
    options = fake_bridge.requests[-1]["options"]
    assert options["strict"] == "structure"
    assert options["limits"]["max_input_bytes"] == 64

    fake_bridge.queue(success_payload())
    converter.convert(b"# T\n", strict=False, limits=None)
    options = fake_bridge.requests[-1]["options"]
    assert options["strict"] == "off"
    assert "limits" not in options


def test_converter_is_immutable(fake_bridge: FakeBridge) -> None:
    converter = zenfmt.Converter()
    with pytest.raises(AttributeError):
        converter.strict = zenfmt.Strictness.EXACT  # type: ignore[misc]


def test_keyword_only_arguments_are_enforced(
    fake_bridge: FakeBridge,
) -> None:
    with pytest.raises(TypeError):
        zenfmt.convert(b"# T\n", "markdown")  # type: ignore[misc]


def test_output_stream_objects_are_rejected(fake_bridge: FakeBridge) -> None:
    import io

    with pytest.raises(TypeError, match="INVALID OUTPUT ARGUMENT"):
        zenfmt.convert(b"# T\n", output=io.BytesIO())
    assert fake_bridge.requests == []
