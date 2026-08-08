"""Argument validation, reusable policy, and the public conversion call
(ZDS 0014). Contains no document-format logic: format identity comes from
native capability metadata only."""

from __future__ import annotations

import os
from pathlib import Path, PurePath
from typing import Any

from . import _capabilities, _diagnostics, _ffi, _loader, _marshal
from ._limits import Limits
from ._models import Conversion, Format, Strictness

_UNSET: Any = object()


def _normalize_strict(value: Any) -> Strictness:
    if value is False or value is None:
        return Strictness.OFF
    if value is True:
        # Bare `--strict` means content, and so does `strict=True`.
        return Strictness.CONTENT
    if isinstance(value, Strictness):
        return value
    if isinstance(value, str):
        try:
            return Strictness(value.lower())
        except ValueError:
            raise _diagnostics.invalid_strict(value) from None
    raise _diagnostics.invalid_strict(value)


def _normalize_limits(value: Any) -> Limits | None:
    if value is None:
        return None
    if isinstance(value, Limits):
        return value
    raise _diagnostics.invalid_limits_argument(value)


def _normalize_format(argument: str, value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, Format):
        return value.name
    if isinstance(value, str):
        return value
    raise _diagnostics.invalid_format_argument(argument, value)


def _validate_name(name: str) -> str:
    if not isinstance(name, str):
        raise _diagnostics.invalid_name(repr(name), "must be a str display basename")
    if not name:
        raise _diagnostics.invalid_name(name, "must not be empty")
    if any(ch in name for ch in ("/", "\\")):
        raise _diagnostics.invalid_name(name, "must not contain a directory separator")
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in name):
        raise _diagnostics.invalid_name(name, "must not contain control characters")
    return name


def _sanitize_stream_name(value: Any) -> str | None:
    """The optional display-only ``.name`` attribute of a reader: used
    only when it is already a str, reduced to a basename, never opened."""
    if not isinstance(value, str) or not value:
        return None
    base = PurePath(value).name
    if not base:
        return None
    try:
        return _validate_name(base)
    except ValueError:
        return None


class _Source:
    """One classified conversion source."""

    __slots__ = ("data", "display_name", "kind", "path")

    def __init__(
        self,
        kind: str,
        *,
        path: str | bytes | None = None,
        data: bytes | None = None,
        display_name: str | None = None,
    ) -> None:
        self.kind = kind
        self.path = path
        self.data = data
        self.display_name = display_name


def _classify_source(source: Any, name: str | None, max_input_bytes: int) -> _Source:
    if isinstance(source, (str, PurePath)) or (
        not isinstance(source, (bytes, bytearray, memoryview))
        and hasattr(source, "__fspath__")
    ):
        # A Python str is always a filesystem path, never inline text.
        if name is not None:
            raise _diagnostics.name_with_path_source()
        path = os.fspath(source)
        display = os.path.basename(path) if isinstance(path, str) else None
        if display is None:
            display = os.path.basename(os.fsdecode(path))
        return _Source("path", path=path, display_name=display)

    display = _validate_name(name) if name is not None else None
    if isinstance(source, (bytes, bytearray, memoryview)):
        # Mutable or non-contiguous buffers are copied before the GIL is
        # released; immutable bytes pass through.
        data = source if isinstance(source, bytes) else bytes(source)
        return _Source("bytes", data=data, display_name=display or "<memory>")

    read = getattr(source, "read", None)
    if callable(read):
        data = _marshal.read_bounded(source, max_input_bytes)
        fallback = _sanitize_stream_name(getattr(source, "name", None))
        return _Source(
            "bytes",
            data=data,
            display_name=display or fallback or "<stream>",
        )

    raise _diagnostics.invalid_source_type(source)


def _artifact_name(display_name: str, extension: str) -> str:
    """The memory-mode artifact basename: source stem plus the writer's
    primary extension, or ``artifact.<extension>`` when no usable stem
    exists."""
    stem = display_name
    dot = stem.rfind(".")
    if dot > 0:
        stem = stem[:dot]
    if not stem or stem.startswith("<"):
        stem = "artifact"
    return f"{stem}.{extension}"


class Converter:
    """Immutable, reusable conversion policy over the shared native
    bridge. Thread-safe: independent calls may run concurrently on one
    instance, and the GIL is released while native conversion runs."""

    __slots__ = ("_limits", "_preserve_facets", "_strict")

    def __init__(
        self,
        *,
        strict: Any = False,
        limits: Limits | None = None,
        preserve_facets: bool = False,
    ) -> None:
        object.__setattr__(self, "_strict", _normalize_strict(strict))
        object.__setattr__(self, "_limits", _normalize_limits(limits))
        object.__setattr__(self, "_preserve_facets", bool(preserve_facets))

    def __setattr__(self, name: str, value: Any) -> None:
        raise AttributeError("Converter is immutable")

    @property
    def strict(self) -> Strictness:
        return self._strict

    @property
    def limits(self) -> Limits | None:
        return self._limits

    @property
    def preserve_facets(self) -> bool:
        return self._preserve_facets

    @property
    def formats(self) -> tuple[Format, ...]:
        """The native reader and writer capabilities of this release."""
        return _capabilities.capabilities(_loader.bridge()).formats

    def convert(
        self,
        source: Any,
        *,
        to: Any = None,
        from_: Any = None,
        output: Any = None,
        name: str | None = None,
        strict: Any = _UNSET,
        limits: Any = _UNSET,
        overwrite: bool = False,
        preserve_facets: Any = _UNSET,
    ) -> Conversion:
        """One conversion using this converter's policy; each keyword
        explicitly supplied here overrides the stored policy for this
        call only."""
        effective_strict = (
            self._strict if strict is _UNSET else _normalize_strict(strict)
        )
        effective_limits = (
            self._limits if limits is _UNSET else _normalize_limits(limits)
        )
        effective_facets = (
            self._preserve_facets
            if preserve_facets is _UNSET
            else bool(preserve_facets)
        )
        to_value = _normalize_format("to", to)
        from_value = _normalize_format("from_", from_)
        output_path = _normalize_output(output)

        bridge = _loader.bridge()
        caps = _capabilities.capabilities(bridge)

        resolved_from = caps.resolve(from_value) if from_value is not None else None
        resolved_to = caps.resolve(to_value) if to_value is not None else None
        if resolved_to is None and output_path is not None:
            # An output suffix may select the writer when `to` is absent.
            suffix = output_path.suffix.removeprefix(".")
            if suffix:
                candidate = caps.resolve(suffix)
                entry = caps.by_name(candidate)
                if entry is not None and entry.can_write:
                    resolved_to = candidate

        max_input = (
            effective_limits.max_input_bytes
            if effective_limits is not None
            else caps.limits.get("max_input_bytes", 512 * 1024 * 1024)
        )
        classified = _classify_source(source, name, max_input)

        artifact_name = None
        if output_path is None:
            writer = resolved_to or caps.default_output_format
            extension = caps.primary_extension(writer) or "out"
            artifact_name = _artifact_name(
                classified.display_name or "<memory>", extension
            )

        options = _marshal.options_json(
            input_kind=classified.kind,
            input_name=(
                classified.display_name if classified.kind == "bytes" else None
            ),
            output_kind="path" if output_path is not None else "memory",
            artifact_name=artifact_name,
            from_=resolved_from,
            to=resolved_to,
            strict=effective_strict.value,
            overwrite=overwrite,
            preserve_facets=effective_facets,
            limits=(
                effective_limits.to_dict() if effective_limits is not None else None
            ),
        )
        raw = _marshal.perform(
            bridge,
            options=options,
            input_bytes=classified.data,
            input_path=(
                _marshal.encode_native_path(classified.path)
                if classified.kind == "path"
                else None
            ),
            output_path=(
                _marshal.encode_native_path(os.fspath(output_path))
                if output_path is not None
                else None
            ),
        )
        if raw.status == _ffi.STATUS_INVALID_REQUEST:
            raise _diagnostics.invalid_request()
        if raw.status == _ffi.STATUS_FAILED:
            raise _diagnostics.conversion_error(raw.reports)
        return _marshal.build_conversion(raw, caps, output_path=output_path)


def _normalize_output(output: Any) -> Path | None:
    if output is None:
        return None
    if isinstance(output, (str, PurePath)) or hasattr(output, "__fspath__"):
        # The caller's spelling is preserved rather than silently
        # resolved.
        return Path(os.fsdecode(os.fspath(output)))
    raise _diagnostics.invalid_output_argument(output)


_default_converter: Converter | None = None


def _default() -> Converter:
    global _default_converter
    if _default_converter is None:
        _default_converter = Converter()
    return _default_converter


def convert(
    source: Any,
    *,
    to: Any = None,
    from_: Any = None,
    output: Any = None,
    name: str | None = None,
    strict: Any = False,
    limits: Limits | None = None,
    overwrite: bool = False,
    preserve_facets: bool = False,
) -> Conversion:
    """Converts one document with safe defaults (ZDS 0014).

    ``source`` is a path, bytes-like object, or binary reader; a Python
    str is always a filesystem path, never inline text. With no
    ``output`` the complete artifact ensemble is returned in memory;
    an ``output`` path selects transactional publication. Failures raise
    :class:`zenfmt.ConversionError` (or a subclass) carrying every native
    report.
    """
    return _default().convert(
        source,
        to=to,
        from_=from_,
        output=output,
        name=name,
        strict=strict,
        limits=limits,
        overwrite=overwrite,
        preserve_facets=preserve_facets,
    )


def formats() -> tuple[Format, ...]:
    """Every reader and writer compiled into this release, in native
    registry order, from capability metadata only."""
    return _capabilities.capabilities(_loader.bridge()).formats
