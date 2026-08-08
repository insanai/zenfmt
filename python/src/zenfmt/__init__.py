"""zenfmt: universal document conversion for Python (ZDS 0014).

The common operation is one call::

    import zenfmt

    conversion = zenfmt.convert("report.docx")
    print(conversion.text)
    for report in conversion.reports:
        print(report.code, report.problem)

Importing this package defines Python objects only; the bundled native
engine loads and verifies itself on the first capability query or
conversion. There is no global configuration, no environment lookup, and
no network access.
"""

from __future__ import annotations

import importlib.metadata as _metadata

from ._convert import Converter, convert, formats
from ._errors import (
    ConversionError,
    DestinationExistsError,
    Direction,
    InputReadError,
    LimitExceededError,
    NativeLibraryError,
    UnknownFormatError,
    UnsupportedPlatformError,
    ZenfmtError,
)
from ._limits import Limits
from ._models import (
    Context,
    Conversion,
    Format,
    Manifest,
    Report,
    Resource,
    Strictness,
)

try:
    __version__ = _metadata.version("zenfmt")
except _metadata.PackageNotFoundError:  # not installed; source tree use
    __version__ = "0.0.0"

__all__ = (
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
