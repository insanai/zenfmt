"""Model semantics: immutability, manifest byte fidelity, report parsing,
strictness and alias normalization."""

from __future__ import annotations

import dataclasses
import json

import pytest
from support import (
    FakeBridge,
    capability_payload,
    manifest_payload,
    report_payload,
    success_payload,
)

import zenfmt
from zenfmt._models import report_from_json


def test_manifest_raw_is_exact_and_never_reencoded() -> None:
    raw = manifest_payload()
    manifest = zenfmt.Manifest(raw)
    assert manifest.raw == raw
    assert manifest.to_dict()["x-unknown-extension"] == {"kept": True}
    # Typed access does not disturb the raw bytes.
    assert manifest.artifact.format == "markdown"
    assert manifest.raw == raw


def test_manifest_typed_access() -> None:
    manifest = zenfmt.Manifest(manifest_payload())
    assert manifest.schema == "ai.insan.zenfmt.artifact-manifest"
    assert manifest.schema_version == 2
    assert manifest.source.name == "note.md"
    assert manifest.artifact.plugin_id == "ai.insan.zenfmt.markdown"
    assert manifest.artifact.digest == "ab" * 32
    assert manifest.reports == ()


def test_manifest_to_dict_is_defensive() -> None:
    manifest = zenfmt.Manifest(manifest_payload())
    copy_one = manifest.to_dict()
    copy_one["artifact"]["name"] = "tampered"
    assert manifest.to_dict()["artifact"]["name"] == "note.md"


def test_manifest_is_immutable() -> None:
    manifest = zenfmt.Manifest(manifest_payload())
    with pytest.raises(AttributeError):
        manifest.raw = b"{}"  # type: ignore[misc]


def test_invalid_manifest_is_a_native_library_error() -> None:
    manifest = zenfmt.Manifest(b"not json")
    with pytest.raises(zenfmt.NativeLibraryError):
        _ = manifest.artifact


@pytest.mark.parametrize(
    ("payload", "attribute"),
    [
        ({"schema_version": "not-an-int"}, "schema_version"),
        ({"reports": {}}, "reports"),
        ({"document_metadata": []}, "document_metadata"),
        ({"plugins": []}, "plugins"),
        ({"media": {}}, "media"),
        ({"facets": {}}, "facets"),
    ],
)
def test_malformed_manifest_fields_raise_native_library_error(
    payload: dict, attribute: str
) -> None:
    manifest = zenfmt.Manifest(json.dumps(payload).encode())
    with pytest.raises(zenfmt.NativeLibraryError) as info:
        getattr(manifest, attribute)
    assert info.value.code == "python.corrupt-result"
    assert "What you can do:" in str(info.value)


def test_malformed_manifest_reference_fields_are_rejected() -> None:
    payload = json.loads(manifest_payload())
    payload["artifact"]["name"] = 7
    manifest = zenfmt.Manifest(json.dumps(payload).encode())
    with pytest.raises(zenfmt.NativeLibraryError, match="incomplete"):
        _ = manifest.artifact


def test_report_parsing_keeps_stable_machine_fields() -> None:
    entry = report_payload(
        loss="structural",
        count=3,
        samples=[
            {
                "kind": "source",
                "name": "note.md",
                "line": 4,
                "excerpt": "x",
                "span_start": 1,
                "span_len": 2,
            }
        ],
    )
    report = report_from_json(entry)
    assert report.code == "core.unknown-input-format"
    assert report.severity == "error"
    assert report.count == 3
    assert report.loss == "structural"
    assert report.exit_class == "usage"
    assert report.context is not None
    assert report.context.kind == "source"
    assert report.context.line == 4
    assert report.samples == (report.context,)
    assert report.directions[0].command == (
        "zenfmt",
        "--from",
        "markdown",
        "note.md",
    )


def test_models_are_frozen_and_hashable() -> None:
    report = report_from_json(report_payload())
    with pytest.raises(dataclasses.FrozenInstanceError):
        report.code = "x"  # type: ignore[misc]
    assert hash(report) == hash(report_from_json(report_payload()))
    strictness = zenfmt.Strictness.CONTENT
    assert strictness == "content"


def test_binary_writer_text_raises(fake_bridge: FakeBridge) -> None:
    fake_bridge.queue(
        success_payload(
            artifact=b"\x00\x01", artifact_name="note.bin", output_format="binfake"
        )
    )
    conversion = zenfmt.convert(b"data", name="note.bin", to="binfake")
    assert conversion.content == b"\x00\x01"
    with pytest.raises(TypeError, match="BINARY OUTPUT"):
        _ = conversion.text


def test_text_writer_invalid_utf8_is_a_native_library_error(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload(artifact=b"\xff"))
    conversion = zenfmt.convert(b"data", name="note.md")
    with pytest.raises(zenfmt.NativeLibraryError) as info:
        _ = conversion.text
    assert info.value.code == "python.corrupt-result"
    assert "What you can do:" in str(info.value)


def test_strictness_values_and_true_false() -> None:
    converter = zenfmt.Converter(strict=True)
    assert converter.strict is zenfmt.Strictness.CONTENT
    assert zenfmt.Converter(strict=False).strict is zenfmt.Strictness.OFF
    assert zenfmt.Converter(strict="STRUCTURE").strict is zenfmt.Strictness.STRUCTURE
    with pytest.raises(ValueError, match="INVALID STRICTNESS"):
        zenfmt.Converter(strict="loose")


def test_alias_resolution_is_case_insensitive_with_one_dot(
    fake_bridge: FakeBridge,
) -> None:
    for alias in ("MD", ".md", "Markdown", "markdown"):
        fake_bridge.queue(success_payload())
        zenfmt.convert(b"# T\n", to=alias)
        assert fake_bridge.requests[-1]["options"]["to"] == "markdown"


def test_unknown_alias_passes_through_to_the_engine(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(
        {
            "status": 1,
            "exit_class": "usage",
            "reports": [report_payload(code="core.unknown-output-format")],
        }
    )
    with pytest.raises(zenfmt.UnknownFormatError):
        zenfmt.convert(b"# T\n", to="nope")
    assert fake_bridge.requests[-1]["options"]["to"] == "nope"


def test_format_argument_accepts_format_objects(
    fake_bridge: FakeBridge,
) -> None:
    fake_bridge.queue(success_payload())
    markdown = next(f for f in zenfmt.formats() if f.name == "markdown")
    fake_bridge.queue(success_payload())
    zenfmt.convert(b"# T\n", to=markdown)
    assert fake_bridge.requests[-1]["options"]["to"] == "markdown"


def test_formats_come_only_from_capability_metadata(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import zenfmt._loader as loader_module

    invented = {
        "extensions": ["zzz"],
        "format": "invented",
        "plugin_id": "ai.insan.zenfmt.invented",
        "primary_extension": "zzz",
        "read": True,
        "seekable_input": False,
        "text_writer": True,
        "write": True,
    }
    payload = json.loads(capability_payload())
    payload["formats"].append(invented)
    bridge = FakeBridge(capability_json=json.dumps(payload).encode())
    monkeypatch.setattr(loader_module, "_bridge", bridge)
    names = [f.name for f in zenfmt.formats()]
    # No hardcoded Python table filters an unknown native format.
    assert "invented" in names
    assert names.index("markdown") < names.index("invented")
