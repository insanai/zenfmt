"""Fake-bridge payload builders shared by the unit suite (ZDS 0014).

Unit tests never touch ctypes or a real library. ``FakeBridge`` mirrors
the ``zenfmt._loader.Bridge`` method surface, serves configurable
payloads, and records every request for assertions.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

DEFAULT_FORMATS = [
    {
        "extensions": ["md", "markdown"],
        "format": "markdown",
        "plugin_id": "ai.insan.zenfmt.markdown",
        "primary_extension": "md",
        "read": True,
        "seekable_input": False,
        "text_writer": True,
        "write": True,
    },
    {
        "extensions": ["docx", "docm"],
        "format": "docx",
        "plugin_id": "ai.insan.zenfmt.docx",
        "primary_extension": None,
        "read": True,
        "seekable_input": True,
        "text_writer": None,
        "write": False,
    },
    {
        "extensions": ["bin"],
        "format": "binfake",
        "plugin_id": "ai.insan.zenfmt.binfake",
        "primary_extension": "bin",
        "read": True,
        "seekable_input": False,
        "text_writer": False,
        "write": True,
    },
]


def capability_payload(**overrides: Any) -> bytes:
    document = {
        "default_output_format": "markdown",
        "formats": DEFAULT_FORMATS,
        "hard_caps": {"max_depth": 4096},
        "limits": {"max_input_bytes": 512 * 1024 * 1024},
        "schema": 1,
        "version": "0.1.0",
    }
    document.update(overrides)
    return json.dumps(document).encode()


def manifest_payload(
    *,
    artifact_name: str = "note.md",
    output_format: str = "markdown",
    facets: dict[str, dict] | None = None,
    media: list[dict] | None = None,
    reports: list[dict] | None = None,
) -> bytes:
    document = {
        "artifact": {
            "digest": {"algorithm": "blake3-256", "value": "ab" * 32},
            "format": output_format,
            "name": artifact_name,
            "plugin": {"id": f"ai.insan.zenfmt.{output_format}"},
        },
        "ast": {"schema": "ai.insan.zenfmt.ast", "version": 2},
        "document_metadata": {},
        "plugins": {},
        "reports": reports or [],
        "schema": "ai.insan.zenfmt.artifact-manifest",
        "schema_version": 2,
        "source": {
            "digest": {"algorithm": "blake3-256", "value": "cd" * 32},
            "format": "markdown",
            "name": "note.md",
            "plugin": {"id": "ai.insan.zenfmt.markdown"},
        },
        # An unknown preservation field that must survive .raw untouched.
        "x-unknown-extension": {"kept": True},
    }
    if facets is not None:
        document["facets"] = facets
    if media is not None:
        document["media"] = media
    return json.dumps(document, sort_keys=True).encode()


def report_payload(**overrides: Any) -> dict:
    entry = {
        "code": "core.unknown-input-format",
        "consequence": "No output file was created.",
        "count": 1,
        "directions": [
            {
                "command": ["zenfmt", "--from", "markdown", "note.md"],
                "explanation": "Select the intended format explicitly:",
                "title": "Select the intended format explicitly",
            }
        ],
        "exit_class": "usage",
        "problem": "I do not recognize `nope` as an input format.",
        "samples": [],
        "severity": "error",
        "title": "UNKNOWN INPUT FORMAT",
    }
    entry.update(overrides)
    return entry


class FakeHandle:
    def __init__(self, payload: dict) -> None:
        self.payload = payload
        self.freed = 0

    def status(self) -> int:
        return self.payload.get("status", 0)

    def exit_class(self) -> str:
        return self.payload.get("exit_class", "conversion")

    def reports_json(self) -> bytes:
        return json.dumps(self.payload.get("reports", [])).encode()

    def manifest_json(self) -> bytes | None:
        return self.payload.get("manifest")

    def source_format(self) -> str | None:
        return self.payload.get("source_format")

    def output_format(self) -> str | None:
        return self.payload.get("output_format")

    def artifact(self) -> bytes | None:
        return self.payload.get("artifact")

    def artifact_name(self) -> str | None:
        return self.payload.get("artifact_name")

    def resources(self) -> list[tuple[str, bytes, str]]:
        return list(self.payload.get("resources", []))

    def free(self) -> None:
        self.freed += 1


class FakeBridge:
    """The `_loader.Bridge` surface, served from canned payloads."""

    def __init__(
        self,
        *,
        capability_json: bytes | None = None,
        results: list[dict] | None = None,
    ) -> None:
        self.abi_major = 1
        self.abi_minor = 0
        self.native_version = "0.1.0"
        self.capability_json = capability_json or capability_payload()
        self.results = list(results or [])
        self.requests: list[dict] = []
        self.handles: list[FakeHandle] = []

    def queue(self, payload: dict) -> None:
        self.results.append(payload)

    def convert(
        self,
        *,
        options_json: bytes,
        input_bytes: bytes | None,
        input_path: bytes | None,
        output_path: bytes | None,
        copy_limits: dict[str, int],
    ) -> FakeHandle:
        self.requests.append(
            {
                "options": json.loads(options_json),
                "input_bytes": input_bytes,
                "input_path": input_path,
                "output_path": output_path,
                "copy_limits": copy_limits,
            }
        )
        if not self.results:
            raise AssertionError("FakeBridge has no queued result")
        handle = FakeHandle(self.results.pop(0))
        self.handles.append(handle)
        return handle


def success_payload(
    *,
    artifact: bytes = b"# Title\n\nbody\n",
    artifact_name: str = "note.md",
    output_format: str = "markdown",
    media: list[dict] | None = None,
    resources: list[tuple[str, bytes, str]] | None = None,
    reports: list[dict] | None = None,
    memory: bool = True,
) -> dict:
    payload = {
        "status": 0,
        "exit_class": "conversion",
        "reports": reports or [],
        "manifest": manifest_payload(
            artifact_name=artifact_name,
            output_format=output_format,
            media=media,
        ),
        "source_format": "markdown",
        "output_format": output_format,
    }
    if memory:
        payload["artifact"] = artifact
        payload["artifact_name"] = artifact_name
        payload["resources"] = resources or []
    return payload


def media_entry(rel_path: str, content: bytes, **overrides: Any) -> dict:
    entry = {
        "digest": {
            "algorithm": "blake3-256",
            "scope": "content",
            "value": hashlib.sha256(content).hexdigest(),
        },
        "kind": "embedded",
        "mime": "image/png",
        "path": rel_path,
        "source": "embedded:pic",
    }
    entry.update(overrides)
    return entry
