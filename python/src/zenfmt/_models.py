"""Immutable public models (ZDS 0014).

Every model here is built only from bridge-supplied JSON and bytes; the
Python layer never invents a reader, writer, report, loss, manifest field,
or resource digest. All models are frozen and slotted.
"""

from __future__ import annotations

import copy
import enum
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ._diagnostics import argument_error, corrupt_result
from ._errors import Direction

__all__ = [
    "Context",
    "Conversion",
    "Direction",
    "Format",
    "Manifest",
    "ManifestRef",
    "Report",
    "Resource",
    "Strictness",
]


class Strictness(str, enum.Enum):
    """The graded strict predicate (ZDS 0013): refuse before output when
    the priced loss crosses the grade."""

    OFF = "off"
    CONTENT = "content"
    STRUCTURE = "structure"
    EXACT = "exact"


@dataclass(frozen=True, slots=True)
class Context:
    """Where a report happened: one of the engine's context kinds
    (``source``, ``logical``, ``archive-member``, ``argv``, ``path``) with
    that kind's fields populated."""

    kind: str
    name: str | None = None
    line: int | None = None
    excerpt: str | None = None
    span_start: int | None = None
    span_len: int | None = None
    location: str | None = None
    member: str | None = None
    args: tuple[str, ...] | None = None
    highlight: int | None = None
    operation: str | None = None
    path: str | None = None

    def __str__(self) -> str:
        if self.kind == "source":
            return f"{self.name}:{self.line}: {self.excerpt}"
        if self.kind == "logical":
            return str(self.location)
        if self.kind == "archive-member":
            return f"archive member {self.member}"
        if self.kind == "argv":
            return " ".join(self.args or ())
        if self.kind == "path":
            return f"`{self.path}` while trying to {self.operation}"
        return self.kind


@dataclass(frozen=True, slots=True)
class Report:
    """One canonical native diagnostic. Stable machine fields are exact;
    human prose may improve between releases, so switch on :attr:`code`
    and enums, not on rendered text."""

    code: str
    severity: str
    title: str
    problem: str
    consequence: str
    count: int = 1
    loss: str | None = None
    exit_class: str | None = None
    context: Context | None = None
    samples: tuple[Context, ...] = ()
    directions: tuple[Direction, ...] = ()


@dataclass(frozen=True, slots=True)
class Format:
    """One compiled reader/writer capability from native metadata."""

    name: str
    plugin_id: str
    extensions: tuple[str, ...]
    can_read: bool
    can_write: bool
    primary_extension: str | None
    seekable_input: bool
    text_writer: bool | None


@dataclass(frozen=True, slots=True)
class Resource:
    """One artifact resource: embedded media bytes or an external
    reference. Collections preserve manifest order."""

    kind: str
    name: str
    media_type: str
    digest: str
    source: str
    alt: str | None = None
    pixel_width: int | None = None
    pixel_height: int | None = None
    content: bytes | None = None
    path: Path | None = None

    @property
    def embedded(self) -> bool:
        return self.kind == "embedded"

    @property
    def external(self) -> bool:
        return self.kind == "external"


@dataclass(frozen=True, slots=True)
class ManifestRef:
    """The manifest's source or artifact reference."""

    name: str
    format: str
    digest: str
    plugin_id: str


class Manifest:
    """The canonical artifact manifest.

    :attr:`raw` is the exact canonical UTF-8 JSON bytes returned by the
    engine — never re-encoded, so byte identity and unknown preservation
    fields survive. Typed accessors parse lazily from one cached load;
    :meth:`to_dict` returns a defensive JSON-compatible copy.
    """

    __slots__ = ("_parsed", "_raw")

    def __init__(self, raw: bytes) -> None:
        object.__setattr__(self, "_raw", bytes(raw))
        object.__setattr__(self, "_parsed", None)

    def __setattr__(self, name: str, value: Any) -> None:
        raise AttributeError("Manifest is immutable")

    @property
    def raw(self) -> bytes:
        return self._raw

    def _load(self) -> dict[str, Any]:
        parsed = self._parsed
        if parsed is None:
            try:
                parsed = json.loads(self._raw)
            except (TypeError, UnicodeError, ValueError) as error:
                raise corrupt_result("the manifest is not valid JSON") from error
            if not isinstance(parsed, dict):
                raise corrupt_result("the manifest is not a JSON object")
            object.__setattr__(self, "_parsed", parsed)
        return parsed

    def _ref(self, key: str) -> ManifestRef:
        value = self._load().get(key)
        if not isinstance(value, dict):
            raise corrupt_result(f"the manifest carries no `{key}` object")
        try:
            fields = (
                value["name"],
                value["format"],
                value["digest"]["value"],
                value["plugin"]["id"],
            )
            if not all(isinstance(field, str) for field in fields):
                raise TypeError("reference fields must be text")
            return ManifestRef(*fields)
        except (KeyError, TypeError) as error:
            raise corrupt_result(
                f"the manifest `{key}` object is incomplete"
            ) from error

    @property
    def schema(self) -> str:
        return str(self._load().get("schema", ""))

    @property
    def schema_version(self) -> int:
        try:
            return int(self._load().get("schema_version", 0))
        except (TypeError, ValueError) as error:
            raise corrupt_result(
                "the manifest schema version is not an integer"
            ) from error

    @property
    def source(self) -> ManifestRef:
        return self._ref("source")

    @property
    def artifact(self) -> ManifestRef:
        return self._ref("artifact")

    @property
    def reports(self) -> tuple[Report, ...]:
        entries = self._load().get("reports", [])
        if not isinstance(entries, list) or not all(
            isinstance(entry, dict) for entry in entries
        ):
            raise corrupt_result("the manifest reports field is not an object array")
        try:
            return tuple(report_from_json(entry) for entry in entries)
        except (AttributeError, KeyError, TypeError, ValueError) as error:
            raise corrupt_result("the manifest contains an invalid report") from error

    @property
    def document_metadata(self) -> dict[str, Any]:
        value = self._load().get("document_metadata", {})
        if not isinstance(value, dict):
            raise corrupt_result(
                "the manifest document_metadata field is not an object"
            )
        return copy.deepcopy(value)

    @property
    def plugins(self) -> dict[str, Any]:
        value = self._load().get("plugins", {})
        if not isinstance(value, dict):
            raise corrupt_result("the manifest plugins field is not an object")
        return copy.deepcopy(value)

    @property
    def media(self) -> tuple[dict[str, Any], ...]:
        value = self._load().get("media", [])
        if not isinstance(value, list) or not all(
            isinstance(entry, dict) for entry in value
        ):
            raise corrupt_result("the manifest media field is not an object array")
        return tuple(copy.deepcopy(value))

    @property
    def facets(self) -> dict[str, dict[str, Any]]:
        value = self._load().get("facets", {})
        if not isinstance(value, dict) or not all(
            isinstance(entry, dict) for entry in value.values()
        ):
            raise corrupt_result("the manifest facets field is not an object")
        return copy.deepcopy(value)

    def to_dict(self) -> dict[str, Any]:
        return copy.deepcopy(self._load())

    def __repr__(self) -> str:
        return f"Manifest({len(self._raw)} canonical bytes)"


@dataclass(frozen=True, slots=True)
class Conversion:
    """A successful conversion: the whole artifact ensemble.

    If a :class:`Conversion` exists, conversion succeeded — expected
    failures raise instead, and there is no ``.ok`` flag. Warnings and
    notes stay in :attr:`reports` in canonical order.
    """

    name: str
    source_format: str
    output_format: str
    manifest: Manifest
    reports: tuple[Report, ...]
    resources: tuple[Resource, ...]
    content: bytes | None = None
    path: Path | None = None
    _text_output: bool = field(default=False, repr=False)

    @property
    def text(self) -> str:
        """The artifact decoded as UTF-8, for an in-memory textual writer.

        Raises :class:`TypeError` for path output or a binary writer; the
        library never guesses an encoding.
        """
        if self.content is None:
            raise argument_error(
                TypeError,
                title="TEXT IS ONLY FOR MEMORY OUTPUT",
                problem=(
                    "This conversion published to a path, so no artifact "
                    "bytes are held in memory."
                ),
                consequence="Nothing was changed on disk.",
                hint="Read `conversion.path` yourself, or convert without "
                "`output` for an in-memory result.",
            )
        if not self._text_output:
            raise argument_error(
                TypeError,
                title="THIS WRITER EMITS BINARY OUTPUT",
                problem=(
                    f"The `{self.output_format}` writer emits arbitrary "
                    "bytes, and zenfmt never guesses an encoding."
                ),
                consequence="Nothing was decoded.",
                hint="Use `conversion.content` for the raw bytes.",
            )
        try:
            return self.content.decode("utf-8")
        except UnicodeDecodeError as error:
            raise corrupt_result(
                f"the `{self.output_format}` writer declared text but emitted "
                "invalid UTF-8"
            ) from error


def context_from_json(entry: dict[str, Any]) -> Context:
    if not isinstance(entry, dict) or not isinstance(entry.get("kind"), str):
        raise TypeError("a report context must be an object with a text kind")
    return Context(
        kind=entry["kind"],
        name=entry.get("name"),
        line=entry.get("line"),
        excerpt=entry.get("excerpt"),
        span_start=entry.get("span_start"),
        span_len=entry.get("span_len"),
        location=entry.get("location"),
        member=entry.get("member"),
        args=tuple(entry["args"]) if "args" in entry else None,
        highlight=entry.get("highlight"),
        operation=entry.get("operation"),
        path=entry.get("path"),
    )


def direction_from_json(entry: dict[str, Any]) -> Direction:
    if not isinstance(entry, dict):
        raise TypeError("a report direction must be an object")
    title = entry.get("title")
    explanation = entry.get("explanation")
    if not isinstance(title, str) or not isinstance(explanation, str):
        raise TypeError("a report direction needs text title and explanation fields")
    command = entry.get("command")
    if command is not None and (
        not isinstance(command, list)
        or not all(isinstance(part, str) for part in command)
    ):
        raise TypeError("a report direction command must be a text array")
    replacement = entry.get("replacement")
    if replacement is not None and not isinstance(replacement, str):
        raise TypeError("a report direction replacement must be text")
    return Direction(
        title=title,
        explanation=explanation,
        command=tuple(command) if command is not None else None,
        replacement=replacement,
    )


def report_from_json(entry: dict[str, Any]) -> Report:
    if not isinstance(entry, dict):
        raise TypeError("a report must be an object")
    required_text = ("code", "severity", "title", "problem", "consequence")
    if not all(isinstance(entry.get(key), str) for key in required_text):
        raise TypeError("a report is missing required text fields")
    sample_entries = entry.get("samples", [])
    direction_entries = entry.get("directions", [])
    if not isinstance(sample_entries, list):
        raise TypeError("a report samples field must be an array")
    if not isinstance(direction_entries, list):
        raise TypeError("a report directions field must be an array")
    count = entry.get("count", 1)
    if isinstance(count, bool) or not isinstance(count, int) or count < 1:
        raise TypeError("a report count must be a positive integer")
    samples = tuple(context_from_json(sample) for sample in sample_entries)
    return Report(
        code=entry["code"],
        severity=entry["severity"],
        title=entry["title"],
        problem=entry["problem"],
        consequence=entry["consequence"],
        count=count,
        loss=entry.get("loss"),
        exit_class=entry.get("exit_class"),
        context=samples[0] if samples else None,
        samples=samples,
        directions=tuple(
            direction_from_json(direction) for direction in direction_entries
        ),
    )
