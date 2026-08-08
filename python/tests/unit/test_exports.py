"""The public surface: exports, typing marker, and signatures."""

from __future__ import annotations

import inspect
from pathlib import Path

import zenfmt


def test_all_is_exactly_the_documented_surface() -> None:
    assert zenfmt.__all__ == (
        "Context",
        "Conversion",
        "ConversionError",
        "Converter",
        "DestinationExistsError",
        "Direction",
        "Format",
        "InputReadError",
        "LimitExceededError",
        "Limits",
        "Manifest",
        "NativeLibraryError",
        "Report",
        "Resource",
        "Strictness",
        "UnknownFormatError",
        "UnsupportedPlatformError",
        "ZenfmtError",
        "__version__",
        "convert",
        "formats",
    )
    for name in zenfmt.__all__:
        assert hasattr(zenfmt, name), name


def test_py_typed_marker_ships_with_the_package() -> None:
    package_dir = Path(zenfmt.__file__).parent
    assert (package_dir / "py.typed").is_file()


def test_convert_signature_is_keyword_only() -> None:
    signature = inspect.signature(zenfmt.convert)
    parameters = list(signature.parameters.values())
    assert parameters[0].name == "source"
    assert parameters[0].kind is inspect.Parameter.POSITIONAL_OR_KEYWORD
    for parameter in parameters[1:]:
        assert parameter.kind is inspect.Parameter.KEYWORD_ONLY, parameter.name
    assert [p.name for p in parameters[1:]] == [
        "to",
        "from_",
        "output",
        "name",
        "strict",
        "limits",
        "overwrite",
        "preserve_facets",
    ]


def test_public_names_have_docstrings() -> None:
    for name in ("convert", "formats", "Converter", "Conversion", "Limits"):
        assert (getattr(zenfmt, name).__doc__ or "").strip(), name


def test_underscore_modules_are_private() -> None:
    public = [name for name in zenfmt.__all__ if not name.startswith("_")]
    assert "convert" in public
    assert all(not name.startswith("_ffi") for name in zenfmt.__all__)
