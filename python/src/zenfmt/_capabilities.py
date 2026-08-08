"""Capability discovery from native metadata (ZDS 0014).

The bridge's compile-time capability JSON is the only format table: it
drives :func:`zenfmt.formats`, alias resolution, artifact naming, and the
``Conversion.text`` decision. No hard-coded Python format list exists
anywhere in this package.
"""

from __future__ import annotations

import json

from . import _diagnostics
from ._loader import Bridge
from ._models import Format

_cache: dict[bytes, Capabilities] = {}


class Capabilities:
    __slots__ = ("_aliases", "default_output_format", "formats", "limits")

    def __init__(
        self,
        formats: tuple[Format, ...],
        default_output_format: str,
        limits: dict[str, int],
    ) -> None:
        self.formats = formats
        self.default_output_format = default_output_format
        self.limits = limits
        aliases: dict[str, str] = {}
        for entry in formats:
            aliases[entry.name] = entry.name
            for extension in entry.extensions:
                aliases.setdefault(extension, entry.name)
        self._aliases = aliases

    def resolve(self, alias: str) -> str:
        """Canonical format id for a name or extension-like alias.

        ASCII case-insensitive; one leading dot is ignored. Unknown
        aliases pass through unchanged so the engine produces the
        canonical unknown-format failure with its suggestions — the
        wrapper never maintains a second table of judgments.
        """
        normalized = alias.strip().lower().removeprefix(".")
        return self._aliases.get(normalized, normalized)

    def by_name(self, name: str) -> Format | None:
        for entry in self.formats:
            if entry.name == name:
                return entry
        return None

    def writer_emits_text(self, name: str) -> bool:
        entry = self.by_name(name)
        return bool(entry and entry.text_writer)

    def primary_extension(self, name: str) -> str | None:
        entry = self.by_name(name)
        return entry.primary_extension if entry else None


def capabilities(bridge: Bridge) -> Capabilities:
    """The parsed capability view for a verified bridge, cached by the
    exact capability bytes (identical metadata parses identically)."""
    key = bridge.capability_json
    cached = _cache.get(key)
    if cached is not None:
        return cached
    parsed = _parse(key)
    _cache.clear()
    _cache[key] = parsed
    return parsed


def _parse(raw: bytes) -> Capabilities:
    try:
        document = json.loads(raw)
        formats = tuple(
            Format(
                name=str(entry["format"]),
                plugin_id=str(entry["plugin_id"]),
                extensions=tuple(str(e) for e in entry["extensions"]),
                can_read=bool(entry["read"]),
                can_write=bool(entry["write"]),
                primary_extension=entry["primary_extension"],
                seekable_input=bool(entry["seekable_input"]),
                text_writer=entry["text_writer"],
            )
            for entry in document["formats"]
        )
        default_output = str(document["default_output_format"])
        limits = {str(name): int(value) for name, value in document["limits"].items()}
    except (KeyError, TypeError, ValueError) as error:
        raise _diagnostics.capabilities_invalid(
            f"{type(error).__name__}: {error}"
        ) from error
    if not formats:
        raise _diagnostics.capabilities_invalid("no formats are declared")
    return Capabilities(formats, default_output, limits)
