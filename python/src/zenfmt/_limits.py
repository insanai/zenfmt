"""The immutable public :class:`Limits` value (ZDS 0014).

One positive-integer field per engine limit, with names, defaults, and
hard caps mirroring ``core/src/limits.zig`` exactly. The native engine
validates limits again because the ABI is a trust boundary; validating
here first turns an embedding mistake into an immediate, well-explained
Python error before any native work.
"""

from __future__ import annotations

from typing import Any

from ._diagnostics import argument_error

#: name -> (default, hard cap or None). Parity with the engine's table is
#: asserted against native capability metadata by the integration suite.
LIMIT_TABLE: dict[str, tuple[int, int | None]] = {
    "max_input_bytes": (512 * 1024 * 1024, None),
    "max_depth": (256, 4096),
    "max_archive_entries": (4096, None),
    "max_entry_uncompressed": (256 * 1024 * 1024, None),
    "max_total_uncompressed": (1024 * 1024 * 1024, None),
    "max_compression_ratio": (200, None),
    "max_entry_name_bytes": (1024, None),
    "max_xml_depth": (256, 4096),
    "max_scan_chunk_bytes": (1024 * 1024, None),
    "max_manifest_bytes": (16 * 1024 * 1024, None),
    "max_plugin_data_bytes": (4 * 1024 * 1024, None),
    "max_manifest_depth": (64, None),
    "max_report_samples": (4, None),
    "max_reports_total": (16 * 1024, None),
    "max_resources": (256, None),
    "max_resource_bytes": (128 * 1024 * 1024, None),
    "max_nodes": (16 * 1024 * 1024, None),
    "max_facet_rows": (1024 * 1024, None),
    "max_decoded_text_bytes": (256 * 1024 * 1024, None),
    "max_lowering_alternatives": (8, 64),
    "max_lowering_work": (64 * 1024 * 1024, None),
    "max_output_bytes": (512 * 1024 * 1024, None),
}

_U32_FIELDS = frozenset(
    name
    for name in LIMIT_TABLE
    if name
    not in {
        "max_input_bytes",
        "max_entry_uncompressed",
        "max_total_uncompressed",
        "max_resource_bytes",
        "max_decoded_text_bytes",
        "max_lowering_work",
        "max_output_bytes",
    }
)


class Limits:
    """Immutable engine resource limits.

    Construct with keyword overrides; unspecified fields keep the engine
    defaults::

        limits = zenfmt.Limits(max_input_bytes=64 * 1024 * 1024)

    Every field is a positive integer. Zero, negative, boolean,
    non-integer, unknown, and hard-cap-violating values raise
    :class:`ValueError` or :class:`TypeError` before any native work.
    """

    __slots__ = tuple(LIMIT_TABLE)

    def __init__(self, **overrides: int) -> None:
        for name, (default, _) in LIMIT_TABLE.items():
            object.__setattr__(self, name, default)
        for name, value in overrides.items():
            spec = LIMIT_TABLE.get(name)
            if spec is None:
                raise argument_error(
                    ValueError,
                    title="UNKNOWN LIMIT NAME",
                    problem=f"`{name}` is not an engine limit.",
                    consequence=(
                        "The conversion did not start, and no output or "
                        "manifest was created."
                    ),
                    hint=("Use one of: " + ", ".join(sorted(LIMIT_TABLE)) + "."),
                )
            _validate(name, value, spec)
            object.__setattr__(self, name, int(value))

    def __setattr__(self, name: str, value: Any) -> None:
        raise AttributeError(f"Limits is immutable; cannot set {name!r}")

    def __delattr__(self, name: str) -> None:
        raise AttributeError(f"Limits is immutable; cannot delete {name!r}")

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Limits):
            return NotImplemented
        return all(getattr(self, name) == getattr(other, name) for name in LIMIT_TABLE)

    def __hash__(self) -> int:
        return hash(tuple(getattr(self, name) for name in LIMIT_TABLE))

    def __repr__(self) -> str:
        overrides = ", ".join(
            f"{name}={getattr(self, name)}"
            for name, (default, _) in LIMIT_TABLE.items()
            if getattr(self, name) != default
        )
        return f"Limits({overrides})"

    def to_dict(self) -> dict[str, int]:
        """Every limit by name, including defaults."""
        return {name: getattr(self, name) for name in LIMIT_TABLE}

    def replace(self, **overrides: int) -> Limits:
        """A new :class:`Limits` with the given fields replaced."""
        merged = self.to_dict()
        merged.update(overrides)
        return Limits(**merged)


def _validate(name: str, value: int, spec: tuple[int, int | None]) -> None:
    if isinstance(value, bool) or not isinstance(value, int):
        raise argument_error(
            TypeError,
            title="INVALID LIMIT TYPE",
            problem=(
                f"`{name}` must be a positive integer; received "
                f"`{type(value).__name__}`."
            ),
            consequence=(
                "The conversion did not start, and no output or manifest was created."
            ),
            hint=f"Pass an integer byte or item count, such as {name}={spec[0]}.",
        )
    if value <= 0:
        raise argument_error(
            ValueError,
            title="INVALID LIMIT VALUE",
            problem=f"`{name}` must be at least 1; received {value}.",
            consequence=(
                "The conversion did not start, and no output or manifest was created."
            ),
            hint="Every limit is a positive integer; zero never disables one.",
        )
    _, cap = spec
    if cap is not None and value > cap:
        raise argument_error(
            ValueError,
            title="LIMIT EXCEEDS ITS HARD CAP",
            problem=f"`{name}` is capped at {cap}; received {value}.",
            consequence=(
                "The conversion did not start, and no output or manifest was created."
            ),
            hint=(
                f"Choose a value from 1 through {cap}; larger values cannot "
                "fit the engine's bounded state."
            ),
        )
    upper = (1 << 32) - 1 if name in _U32_FIELDS else (1 << 64) - 1
    if value > upper:
        raise argument_error(
            ValueError,
            title="LIMIT EXCEEDS ITS FIELD WIDTH",
            problem=f"`{name}` must fit {upper}; received {value}.",
            consequence=(
                "The conversion did not start, and no output or manifest was created."
            ),
            hint=f"Choose a value no larger than {upper}.",
        )
