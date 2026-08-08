"""`Limits` validation: names, types, ranges, hard caps, immutability."""

from __future__ import annotations

import pytest

import zenfmt
from zenfmt._limits import LIMIT_TABLE


def test_defaults_match_the_documented_engine_table() -> None:
    limits = zenfmt.Limits()
    assert limits.max_input_bytes == 512 * 1024 * 1024
    assert limits.max_output_bytes == 512 * 1024 * 1024
    assert limits.max_depth == 256
    assert limits.max_lowering_alternatives == 8
    assert len(LIMIT_TABLE) == 22


def test_overrides_apply_and_repr_shows_only_overrides() -> None:
    limits = zenfmt.Limits(max_input_bytes=1024)
    assert limits.max_input_bytes == 1024
    assert "max_input_bytes=1024" in repr(limits)
    assert "max_depth" not in repr(limits)


def test_unknown_field_is_a_value_error_with_directions() -> None:
    with pytest.raises(ValueError, match="UNKNOWN LIMIT NAME") as info:
        zenfmt.Limits(max_zip_bombs=1)
    assert "What you can do:" in str(info.value)


@pytest.mark.parametrize("value", [0, -1])
def test_zero_and_negative_are_rejected(value: int) -> None:
    with pytest.raises(ValueError, match="INVALID LIMIT VALUE"):
        zenfmt.Limits(max_depth=value)


@pytest.mark.parametrize("value", [True, False, 1.5, "16", None])
def test_non_integer_values_are_rejected(value: object) -> None:
    with pytest.raises(TypeError, match="INVALID LIMIT TYPE"):
        zenfmt.Limits(max_depth=value)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("name", "cap"),
    [("max_depth", 4096), ("max_xml_depth", 4096), ("max_lowering_alternatives", 64)],
)
def test_hard_caps_are_enforced(name: str, cap: int) -> None:
    zenfmt.Limits(**{name: cap})
    with pytest.raises(ValueError, match="HARD CAP"):
        zenfmt.Limits(**{name: cap + 1})


def test_u32_fields_reject_wider_values() -> None:
    with pytest.raises(ValueError, match="FIELD WIDTH"):
        zenfmt.Limits(max_archive_entries=1 << 32)


def test_immutable_and_hashable() -> None:
    limits = zenfmt.Limits()
    with pytest.raises(AttributeError):
        limits.max_depth = 1  # type: ignore[misc]
    assert hash(zenfmt.Limits()) == hash(zenfmt.Limits())
    assert zenfmt.Limits() == zenfmt.Limits()
    assert zenfmt.Limits(max_depth=1) != zenfmt.Limits()


def test_replace_returns_a_new_value() -> None:
    base = zenfmt.Limits()
    changed = base.replace(max_input_bytes=1)
    assert changed.max_input_bytes == 1
    assert base.max_input_bytes == 512 * 1024 * 1024
    assert changed.to_dict()["max_depth"] == 256
