"""The Python-to-native boundary (ZDS 0014).

Source ingestion, versioned options JSON, one native call, and result
decoding. Every borrowed native byte slice is copied before the handle is
released, inside ``try``/``finally``, so a result owns only Python values.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, BinaryIO

from . import _diagnostics, _ffi
from ._capabilities import Capabilities
from ._loader import Bridge
from ._models import (
    Conversion,
    Manifest,
    Report,
    Resource,
    report_from_json,
)

_READ_CHUNK = 1024 * 1024


def encode_native_path(value: str | bytes) -> bytes:
    """The private ABI's explicit native path encoding: raw bytes on
    POSIX, UTF-16LE code units on Windows. Embedded NUL is rejected
    before native entry."""
    if sys.platform == "win32":
        if isinstance(value, bytes):
            raise _diagnostics.argument_error(
                TypeError,
                title="BYTES PATHS ARE POSIX-ONLY",
                problem="On Windows, paths must be str/Unicode.",
                consequence=(
                    "The conversion did not start, and no output or "
                    "manifest was created."
                ),
                hint="Pass the path as str or pathlib.Path.",
            )
        if "\x00" in value:
            raise _bad_nul()
        return value.encode("utf-16-le")
    raw = os.fsencode(value)
    if b"\x00" in raw:
        raise _bad_nul()
    return raw


def _bad_nul() -> Exception:
    return _diagnostics.argument_error(
        ValueError,
        title="PATH CONTAINS A NUL CHARACTER",
        problem="The supplied path embeds NUL, which no filesystem accepts.",
        consequence=(
            "The conversion did not start, and no output or manifest was created."
        ),
        hint="Pass the intended path without embedded NUL characters.",
    )


def read_bounded(reader: BinaryIO, cap: int) -> bytes:
    """Consumes a binary reader from its current position in bounded
    chunks, reading at most one byte past ``cap`` so exact-boundary EOF is
    distinguishable from overflow. On overflow the bounded bytes go to the
    engine, which produces the canonical limit report. The reader is
    neither seeked nor closed."""
    chunks: list[bytes] = []
    total = 0
    budget = cap + 1
    while total < budget:
        want = min(_READ_CHUNK, budget - total)
        try:
            chunk = reader.read(want)
        except (KeyboardInterrupt, SystemExit, GeneratorExit):
            raise
        except BaseException as error:
            raise _diagnostics.reader_failed(error) from error
        if not isinstance(chunk, (bytes, bytearray)):
            raise _diagnostics.reader_returned_non_bytes(chunk)
        if not chunk:
            break
        chunks.append(bytes(chunk))
        total += len(chunk)
    return b"".join(chunks)


def options_json(
    *,
    input_kind: str,
    input_name: str | None,
    output_kind: str,
    artifact_name: str | None,
    from_: str | None,
    to: str | None,
    strict: str,
    overwrite: bool,
    preserve_facets: bool,
    limits: dict[str, int] | None,
) -> bytes:
    """The versioned options document: deterministic key order, integers
    only, no floating-point values."""
    document: dict[str, Any] = {
        "schema": _ffi.OPTIONS_SCHEMA,
        "input": {"kind": input_kind},
        "output": {"kind": output_kind},
        "from": from_,
        "to": to,
        "strict": strict,
        "overwrite": bool(overwrite),
        "preserve_facets": bool(preserve_facets),
    }
    if input_name is not None:
        document["input"]["name"] = input_name
    if artifact_name is not None:
        document["output"]["artifact_name"] = artifact_name
    if limits is not None:
        document["limits"] = limits
    return json.dumps(
        document, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


class RawResult:
    """Everything copied out of one native result, as plain Python data."""

    __slots__ = (
        "artifact",
        "artifact_name",
        "exit_class",
        "manifest_json",
        "output_format",
        "reports",
        "resources",
        "source_format",
        "status",
    )

    def __init__(self) -> None:
        self.status = _ffi.STATUS_INVALID_REQUEST
        self.exit_class = "usage"
        self.reports: tuple[Report, ...] = ()
        self.manifest_json: bytes | None = None
        self.source_format: str | None = None
        self.output_format: str | None = None
        self.artifact: bytes | None = None
        self.artifact_name: str | None = None
        self.resources: list[tuple[str, bytes, str]] = []


def perform(
    bridge: Bridge,
    *,
    options: bytes,
    input_bytes: bytes | None,
    input_path: bytes | None,
    output_path: bytes | None,
) -> RawResult:
    """One conversion through the bridge: call, copy everything, release
    the handle even when decoding raises."""
    handle = bridge.convert(
        options_json=options,
        input_bytes=input_bytes,
        input_path=input_path,
        output_path=output_path,
    )
    raw = RawResult()
    try:
        raw.status = handle.status()
        raw.exit_class = handle.exit_class()
        try:
            entries = json.loads(handle.reports_json())
            raw.reports = tuple(report_from_json(entry) for entry in entries)
        except ValueError as error:
            raise _diagnostics.corrupt_result(
                "the reports JSON does not parse"
            ) from error
        if raw.status == _ffi.STATUS_SUCCESS:
            raw.manifest_json = handle.manifest_json()
            raw.source_format = handle.source_format()
            raw.output_format = handle.output_format()
            raw.artifact = handle.artifact()
            raw.artifact_name = handle.artifact_name()
            if raw.artifact is not None:
                raw.resources = handle.resources()
    finally:
        handle.free()
    return raw


def build_conversion(
    raw: RawResult,
    caps: Capabilities,
    *,
    output_path: Path | None,
) -> Conversion:
    """Turns a successful raw result into the public model."""
    if raw.manifest_json is None:
        raise _diagnostics.corrupt_result("success carried no manifest")
    if raw.source_format is None or raw.output_format is None:
        raise _diagnostics.corrupt_result("success carried no format ids")
    manifest = Manifest(raw.manifest_json)

    if output_path is None:
        if raw.artifact is None or raw.artifact_name is None:
            raise _diagnostics.corrupt_result("a memory success carried no artifact")
        name = raw.artifact_name
    else:
        name = output_path.name

    embedded_bytes = {rel: (data, digest) for rel, data, digest in raw.resources}
    resources: list[Resource] = []
    for entry in manifest.media:
        external = bool(entry.get("external")) or entry.get("kind") == "external"
        rel_path = str(entry.get("path", ""))
        digest = entry.get("digest", {})
        common = {
            "media_type": str(entry.get("mime", "")),
            "digest": str(digest.get("value", "")),
            "source": str(entry.get("source", "")),
            "alt": entry.get("alt"),
            "pixel_width": entry.get("pixel_width"),
            "pixel_height": entry.get("pixel_height"),
        }
        if external:
            resources.append(Resource(kind="external", name=rel_path, **common))
        elif output_path is None:
            found = embedded_bytes.get(rel_path)
            if found is None:
                raise _diagnostics.corrupt_result(
                    f"the manifest lists `{rel_path}` but the result "
                    "carries no such resource"
                )
            resources.append(
                Resource(kind="embedded", name=rel_path, content=found[0], **common)
            )
        else:
            resources.append(
                Resource(
                    kind="embedded",
                    name=rel_path,
                    path=output_path.parent / rel_path,
                    **common,
                )
            )

    return Conversion(
        name=name,
        source_format=raw.source_format,
        output_format=raw.output_format,
        manifest=manifest,
        reports=raw.reports,
        resources=tuple(resources),
        content=raw.artifact if output_path is None else None,
        path=output_path,
        _text_output=caps.writer_emits_text(raw.output_format),
    )
