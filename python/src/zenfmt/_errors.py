"""The public exception hierarchy and Elm-style renderer (ZDS 0014).

Every :class:`ZenfmtError` answers the engine's four diagnostic questions —
what happened, where, what was and was not produced, and what to do next —
and ``str(error)`` renders them under the same ``What you can do:``
contract as the engine's text renderer, so one failure reads the same
through the CLI and Python.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any


@dataclass(frozen=True, slots=True)
class Direction:
    """One concrete next action from a diagnostic."""

    title: str
    explanation: str
    command: tuple[str, ...] | None = None
    replacement: str | None = None

    def render(self) -> str:
        text = f"{self.title}: {self.explanation}"
        if self.command is not None:
            text += "\n    " + " ".join(self.command)
        if self.replacement is not None:
            text += f"\n    {self.replacement}"
        return text


def render_message(
    *,
    title: str,
    problem: str,
    consequence: str,
    directions: tuple[Direction, ...] = (),
    context: object | None = None,
) -> str:
    """The compact, color-free Elm-style rendering shared by every
    library-raised failure."""
    parts = [title.upper(), "", problem]
    if context is not None:
        parts += ["", str(context)]
    parts += ["", consequence]
    if directions:
        parts += ["", "What you can do:", ""]
        parts += [
            "    " + direction.render().replace("\n", "\n    ")
            for direction in directions
        ]
    return "\n".join(parts)


class ZenfmtError(Exception):
    """Base of every zenfmt library failure.

    Attributes carry the structured diagnostic; ``str(error)`` renders it.
    Applications switch on :attr:`code` and structured fields rather than
    matching rendered prose, which may improve between releases.
    """

    def __init__(
        self,
        *,
        code: str,
        title: str,
        problem: str,
        consequence: str,
        directions: tuple[Direction, ...],
        context: object | None = None,
        details: Mapping[str, Any] | None = None,
    ) -> None:
        message = render_message(
            title=title,
            problem=problem,
            consequence=consequence,
            directions=directions,
            context=context,
        )
        super().__init__(message)
        self.code = code
        self.title = title
        self.problem = problem
        self.consequence = consequence
        self.directions = directions
        self.context = context
        self.details: Mapping[str, Any] = MappingProxyType(dict(details or {}))

    @property
    def hint(self) -> str:
        """The first direction, rendered; always present."""
        return self.directions[0].render()


class ConversionError(ZenfmtError):
    """The document could not be converted.

    Carries every native report in canonical order; :attr:`primary_report`
    is the report this exception's text derives from.
    """

    def __init__(self, *, reports: tuple[Any, ...], primary_report: Any) -> None:
        super().__init__(
            code=primary_report.code,
            title=primary_report.title,
            problem=primary_report.problem,
            consequence=primary_report.consequence,
            directions=tuple(primary_report.directions),
            context=primary_report.context,
            details={"report_codes": tuple(r.code for r in reports)},
        )
        self.reports = reports
        self.primary_report = primary_report
        self.exit_class = primary_report.exit_class or "conversion"


class LimitExceededError(ConversionError):
    """A configured engine resource limit refused the conversion."""


class UnknownFormatError(ConversionError):
    """The requested or detected format is not in this release's bundle."""


class DestinationExistsError(ConversionError):
    """The output ensemble would replace existing files without
    ``overwrite=True``."""


class InputReadError(ZenfmtError):
    """A caller-supplied binary reader failed before native conversion
    began. The original exception is chained as ``__cause__``."""


class NativeLibraryError(ZenfmtError):
    """The packaged native bridge is missing, mismatched, or returned an
    impossible result. An installation or library defect, never a document
    failure."""


class UnsupportedPlatformError(ZenfmtError):
    """No bridge exists for the running platform in this distribution."""
