"""The Python-to-native boundary (ZDS 0014).

Source ingestion, versioned options JSON, one native call, and result
decoding. Every borrowed native byte slice is copied before the handle is
released, inside ``try``/``finally``, so a result owns only Python values.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path, PurePosixPath
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
    copy_limits: dict[str, int],
) -> RawResult:
    """One conversion through the bridge: call, copy everything, release
    the handle even when decoding raises."""
    handle = bridge.convert(
        options_json=options,
        input_bytes=input_bytes,
        input_path=input_path,
        output_path=output_path,
        copy_limits=copy_limits,
    )
    raw = RawResult()
    try:
        raw.status = handle.status()
        if raw.status not in {
            _ffi.STATUS_SUCCESS,
            _ffi.STATUS_FAILED,
            _ffi.STATUS_INVALID_REQUEST,
        }:
            raise _diagnostics.corrupt_result(
                f"status tag {raw.status!r} is outside the ABI's fixed set"
            )
        raw.exit_class = handle.exit_class()
        try:
            entries = json.loads(handle.reports_json())
            if not isinstance(entries, list):
                raise TypeError("the reports payload is not an array")
            raw.reports = tuple(report_from_json(entry) for entry in entries)
            for report in raw.reports:
                if not report.code or not report.title or not report.problem:
                    raise TypeError("a report is missing required text fields")
                if not report.consequence or not report.directions:
                    raise TypeError(
                        "a report violates the Elm-style consequence/direction contract"
                    )
        except (AttributeError, KeyError, TypeError, UnicodeError, ValueError) as error:
            raise _diagnostics.corrupt_result(
                f"the reports payload is invalid ({type(error).__name__})"
            ) from error
        if raw.status == _ffi.STATUS_SUCCESS:
            try:
                raw.manifest_json = handle.manifest_json()
                raw.source_format = handle.source_format()
                raw.output_format = handle.output_format()
                raw.artifact = handle.artifact()
                raw.artifact_name = handle.artifact_name()
                if raw.artifact is not None:
                    raw.resources = handle.resources()
            except (
                AttributeError,
                KeyError,
                TypeError,
                UnicodeError,
                ValueError,
            ) as error:
                raise _diagnostics.corrupt_result(
                    f"the successful result payload is invalid ({type(error).__name__})"
                ) from error
            if not isinstance(raw.manifest_json, bytes):
                raise _diagnostics.corrupt_result(
                    "a successful result carries no byte manifest"
                )
            if not isinstance(raw.source_format, str) or not raw.source_format:
                raise _diagnostics.corrupt_result(
                    "a successful result carries no valid source format id"
                )
            if not isinstance(raw.output_format, str) or not raw.output_format:
                raise _diagnostics.corrupt_result(
                    "a successful result carries no valid output format id"
                )
            if raw.artifact is not None and not isinstance(raw.artifact, bytes):
                raise _diagnostics.corrupt_result(
                    "the in-memory artifact is not a byte string"
                )
            if raw.artifact_name is not None and not isinstance(raw.artifact_name, str):
                raise _diagnostics.corrupt_result(
                    "the in-memory artifact name is not text"
                )
            if raw.artifact is not None:
                for entry in raw.resources:
                    if (
                        not isinstance(entry, tuple)
                        or len(entry) != 3
                        or not isinstance(entry[0], str)
                        or not isinstance(entry[1], bytes)
                        or not isinstance(entry[2], str)
                    ):
                        raise _diagnostics.corrupt_result(
                            "an embedded resource has an invalid ABI shape"
                        )
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
    if len(embedded_bytes) != len(raw.resources):
        raise _diagnostics.corrupt_result(
            "the result carries duplicate embedded resource paths"
        )
    used_embedded: set[str] = set()
    resources: list[Resource] = []
    for entry in manifest.media:
        digest = entry.get("digest")
        required_text = ("path", "mime", "source")
        if not isinstance(digest, dict) or not all(
            isinstance(entry.get(key), str) for key in required_text
        ):
            raise _diagnostics.corrupt_result(
                "a manifest media entry is missing required text or digest fields"
            )
        digest_value = digest.get("value")
        if not isinstance(digest_value, str):
            raise _diagnostics.corrupt_result(
                "a manifest media entry carries no text digest value"
            )
        external_flag = entry.get("external", False)
        if not isinstance(external_flag, bool):
            raise _diagnostics.corrupt_result(
                "a manifest media entry has a non-boolean external flag"
            )
        external = external_flag or entry.get("kind") == "external"
        rel_path = entry["path"]
        common = {
            "media_type": entry["mime"],
            "digest": digest_value,
            "source": entry["source"],
            "alt": entry.get("alt"),
            "pixel_width": entry.get("pixel_width"),
            "pixel_height": entry.get("pixel_height"),
        }
        if external:
            resources.append(Resource(kind="external", name=rel_path, **common))
        else:
            _validate_resource_path(rel_path)
            if output_path is None:
                found = embedded_bytes.get(rel_path)
                if found is None:
                    raise _diagnostics.corrupt_result(
                        f"the manifest lists `{rel_path}` but the result "
                        "carries no such resource"
                    )
                if found[1] != common["digest"]:
                    raise _diagnostics.corrupt_result(
                        f"the manifest and result disagree about `{rel_path}`'s digest"
                    )
                used_embedded.add(rel_path)
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

    if output_path is None and used_embedded != set(embedded_bytes):
        extra = sorted(set(embedded_bytes) - used_embedded)[0]
        raise _diagnostics.corrupt_result(
            f"the result carries `{extra}` but the manifest does not list it"
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


def _validate_resource_path(value: str) -> None:
    path = PurePosixPath(value)
    if (
        not value
        or "\\" in value
        or path.is_absolute()
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise _diagnostics.corrupt_result(
            f"the embedded resource path `{value}` is not a safe relative path"
        )
