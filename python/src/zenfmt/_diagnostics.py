"""The Python-side diagnostic catalog (ZDS 0014).

Every failure the Python layer itself originates is built here, with a
stable ``python.``-namespaced code and at least one concrete direction —
never an ad hoc string at a ``raise`` site. Conversion failures are *not*
in this catalog: they derive from the primary native report.
"""

from __future__ import annotations

from typing import Any

from ._errors import (
    ConversionError,
    DestinationExistsError,
    Direction,
    InputReadError,
    LimitExceededError,
    NativeLibraryError,
    UnknownFormatError,
    UnsupportedPlatformError,
    render_message,
)

_NOT_STARTED = "The conversion did not start, and no output or manifest was created."


def argument_error(
    exc_type: type[Exception],
    *,
    title: str,
    problem: str,
    consequence: str,
    hint: str,
) -> Exception:
    """An ordinary :class:`TypeError`/:class:`ValueError` carrying the same
    five-part rendered message as :class:`ZenfmtError`, without a stable
    application-control-flow code."""
    return exc_type(
        render_message(
            title=title,
            problem=problem,
            consequence=consequence,
            directions=(Direction(title="Next", explanation=hint),),
        )
    )


def invalid_source_type(value: object) -> TypeError:
    return argument_error(  # type: ignore[return-value]
        TypeError,
        title="INVALID SOURCE TYPE",
        problem=(
            "`source` must be a path, bytes-like object, or binary reader; "
            f"received `{type(value).__name__}`."
        ),
        consequence=_NOT_STARTED,
        hint='Pass a path such as `Path("report.docx")` or document bytes.',
    )


def invalid_name(name: str, reason: str) -> ValueError:
    return argument_error(  # type: ignore[return-value]
        ValueError,
        title="INVALID DISPLAY NAME",
        problem=f"`name` {reason}; received {name!r}.",
        consequence=_NOT_STARTED,
        hint=(
            'Pass a plain basename such as `name="upload.docx"` with no '
            "directory separator or control character."
        ),
    )


def name_with_path_source() -> ValueError:
    return argument_error(  # type: ignore[return-value]
        ValueError,
        title="NAME IS ONLY FOR IN-MEMORY SOURCES",
        problem=(
            "`name` was supplied together with a filesystem path source, "
            "whose basename already names the document."
        ),
        consequence=_NOT_STARTED,
        hint="Drop the `name` argument, or pass bytes or a binary reader.",
    )


def invalid_strict(value: object) -> ValueError:
    return argument_error(  # type: ignore[return-value]
        ValueError,
        title="INVALID STRICTNESS",
        problem=(
            "`strict` must be False, True, a Strictness, or one of "
            f"'off', 'content', 'structure', 'exact'; received {value!r}."
        ),
        consequence=_NOT_STARTED,
        hint='Pass `strict="structure"` or `strict=zenfmt.Strictness.EXACT`.',
    )


def invalid_format_argument(argument: str, value: object) -> TypeError:
    return argument_error(  # type: ignore[return-value]
        TypeError,
        title="INVALID FORMAT ARGUMENT",
        problem=(
            f"`{argument}` must be a format name string or zenfmt.Format; "
            f"received `{type(value).__name__}`."
        ),
        consequence=_NOT_STARTED,
        hint='Pass a canonical id such as "markdown" or an entry from '
        "zenfmt.formats().",
    )


def invalid_limits_argument(value: object) -> TypeError:
    return argument_error(  # type: ignore[return-value]
        TypeError,
        title="INVALID LIMITS ARGUMENT",
        problem=(
            "`limits` must be a zenfmt.Limits value or None; received "
            f"`{type(value).__name__}`."
        ),
        consequence=_NOT_STARTED,
        hint="Pass zenfmt.Limits(max_input_bytes=...) or leave it None.",
    )


def invalid_output_argument(value: object) -> TypeError:
    return argument_error(  # type: ignore[return-value]
        TypeError,
        title="INVALID OUTPUT ARGUMENT",
        problem=(
            "`output` must be a path-like value or None; received "
            f"`{type(value).__name__}`. Output streams are not accepted "
            "because they cannot promise rollback."
        ),
        consequence=_NOT_STARTED,
        hint=(
            'Pass an output path such as `output="build/report.md"`, or '
            "leave it None and write `conversion.content` yourself."
        ),
    )


def reader_failed(cause: BaseException) -> InputReadError:
    error = InputReadError(
        code="python.reader-failed",
        title="THE SOURCE READER FAILED",
        problem=(
            "The supplied binary reader raised "
            f"{type(cause).__name__} while being consumed."
        ),
        consequence=_NOT_STARTED,
        directions=(
            Direction(
                title="Check the reader",
                explanation=(
                    "Ensure the object is an open binary reader whose "
                    "read() returns bytes, then retry; the original "
                    "exception is chained as __cause__."
                ),
            ),
        ),
    )
    error.__cause__ = cause
    return error


def reader_returned_non_bytes(value: object) -> InputReadError:
    return InputReadError(
        code="python.reader-returned-non-bytes",
        title="THE SOURCE READER RETURNED NON-BYTES",
        problem=(
            "The supplied reader's read() returned "
            f"`{type(value).__name__}`, not bytes."
        ),
        consequence=_NOT_STARTED,
        directions=(
            Direction(
                title="Open the source in binary mode",
                explanation=(
                    'Use open(path, "rb") or an io.BytesIO, not a text-mode reader.'
                ),
            ),
        ),
    )


def unsupported_platform(system: str, machine: str) -> UnsupportedPlatformError:
    return UnsupportedPlatformError(
        code="python.unsupported-platform",
        title="THIS PLATFORM HAS NO NATIVE BRIDGE",
        problem=(
            f"No zenfmt bridge is built for {system}/{machine} in this distribution."
        ),
        consequence=_NOT_STARTED,
        directions=(
            Direction(
                title="Check the supported platforms",
                explanation=(
                    "zenfmt ships wheels for Linux (glibc and musl, x86_64 "
                    "and aarch64), macOS 12+ (x86_64 and arm64), and 64-bit "
                    "Windows. Build from the source distribution for other "
                    "platforms."
                ),
            ),
        ),
        details={"system": system, "machine": machine},
    )


def _reinstall_direction() -> Direction:
    return Direction(
        title="Reinstall the package",
        explanation="Reinstall so the Python layer and bridge come from one release:",
        command=(
            "pip",
            "install",
            "--force-reinstall",
            "--only-binary",
            ":all:",
            "zenfmt",
        ),
    )


def bridge_missing(path: str) -> NativeLibraryError:
    return NativeLibraryError(
        code="python.bridge-missing",
        title="THE NATIVE BRIDGE IS MISSING",
        problem=f"The packaged bridge library does not exist at `{path}`.",
        consequence=_NOT_STARTED,
        directions=(_reinstall_direction(),),
        details={"path": path},
    )


def bridge_load_failed(path: str, cause: BaseException) -> NativeLibraryError:
    error = NativeLibraryError(
        code="python.bridge-load-failed",
        title="THE NATIVE BRIDGE FAILED TO LOAD",
        problem=(f"Loading `{path}` failed with {type(cause).__name__}: {cause}."),
        consequence=_NOT_STARTED,
        directions=(_reinstall_direction(),),
        details={"path": path},
    )
    error.__cause__ = cause
    return error


def bridge_symbol_missing(symbol: str, cause: BaseException) -> NativeLibraryError:
    error = NativeLibraryError(
        code="python.bridge-symbol-missing",
        title="THE NATIVE BRIDGE IS INCOMPLETE",
        problem=f"The bridge library does not export `{symbol}`.",
        consequence=_NOT_STARTED,
        directions=(_reinstall_direction(),),
        details={"symbol": symbol},
    )
    error.__cause__ = cause
    return error


def abi_mismatch(
    found_major: int, found_minor: int, *, required_major: int, minimum_minor: int
) -> NativeLibraryError:
    return NativeLibraryError(
        code="python.abi-mismatch",
        title="THE NATIVE BRIDGE ABI DOES NOT MATCH",
        problem=(
            f"The bridge speaks ABI {found_major}.{found_minor}, but this "
            f"Python layer requires major {required_major} and minor >= "
            f"{minimum_minor}."
        ),
        consequence=_NOT_STARTED,
        directions=(_reinstall_direction(),),
        details={
            "found_major": found_major,
            "found_minor": found_minor,
            "required_major": required_major,
            "minimum_minor": minimum_minor,
        },
    )


def version_mismatch(native: str, distribution: str) -> NativeLibraryError:
    return NativeLibraryError(
        code="python.version-mismatch",
        title="THE BRIDGE AND PACKAGE VERSIONS DIFFER",
        problem=(
            f"The native bridge is zenfmt {native}, but the installed "
            f"Python distribution is {distribution}."
        ),
        consequence=_NOT_STARTED,
        directions=(_reinstall_direction(),),
        details={"native": native, "distribution": distribution},
    )


def runtime_mismatch(reason: str) -> NativeLibraryError:
    return NativeLibraryError(
        code="python.runtime-mismatch",
        title="THE BRIDGE RUNTIME CONTRACT DOES NOT MATCH",
        problem=reason,
        consequence=_NOT_STARTED,
        directions=(_reinstall_direction(),),
    )


def capabilities_invalid(reason: str) -> NativeLibraryError:
    return NativeLibraryError(
        code="python.capabilities-invalid",
        title="THE BRIDGE CAPABILITY METADATA IS INVALID",
        problem=f"The bridge's capability JSON is unusable: {reason}.",
        consequence=_NOT_STARTED,
        directions=(_reinstall_direction(),),
    )


def corrupt_result(reason: str) -> NativeLibraryError:
    return NativeLibraryError(
        code="python.corrupt-result",
        title="THE NATIVE RESULT IS INTERNALLY INCONSISTENT",
        problem=f"The bridge returned an impossible result: {reason}.",
        consequence=(
            "The conversion result was discarded; no partial data is exposed."
        ),
        directions=(_reinstall_direction(),),
    )


def invalid_request() -> NativeLibraryError:
    return NativeLibraryError(
        code="python.invalid-request",
        title="THE BRIDGE REJECTED THE REQUEST",
        problem=(
            "The native bridge rejected a request this Python layer "
            "built, which means the two disagree about the ABI schema."
        ),
        consequence=_NOT_STARTED,
        directions=(_reinstall_direction(),),
    )


def out_of_memory() -> MemoryError:
    # A preallocated minimal message: no formatting work on this path.
    return MemoryError(_OOM_MESSAGE)


_OOM_MESSAGE = render_message(
    title="OUT OF MEMORY",
    problem="Memory was exhausted while preparing or copying a conversion.",
    consequence="No completed result was returned.",
    directions=(
        Direction(
            title="Reduce the working set",
            explanation=(
                "Lower max_input_bytes/max_output_bytes, convert to a path "
                "instead of memory, or free memory in the process."
            ),
        ),
    ),
)

#: Native report codes that map to dedicated exception classes.
_CODE_CLASSES: dict[str, type[ConversionError]] = {
    "core.unknown-input-format": UnknownFormatError,
    "core.unknown-output-format": UnknownFormatError,
    "core.undetectable-input-format": UnknownFormatError,
    "core.destination-exists": DestinationExistsError,
}


def conversion_error(reports: tuple[Any, ...]) -> ConversionError:
    """Builds the typed conversion failure from canonical native reports.

    The primary report is the first error-severity report; the exception
    class follows its stable code or limit exit class. All other native
    failures use plain :class:`ConversionError` — there is no class per
    report code.
    """
    primary = next(
        (report for report in reports if report.severity == "error"),
        reports[0] if reports else None,
    )
    if primary is None:
        return corrupt_result("a failed conversion carried no reports")  # type: ignore[return-value]
    exc_type = _CODE_CLASSES.get(primary.code)
    if exc_type is None and primary.exit_class == "limit":
        exc_type = LimitExceededError
    if exc_type is None:
        exc_type = ConversionError
    return exc_type(reports=reports, primary_report=primary)
