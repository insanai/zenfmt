"""Native bridge loading and verification (ZDS 0014).

The loader opens exactly one artifact: the bridge packaged inside this
installed distribution, by absolute path. It never searches the current
directory, ``PATH``, a system library directory, ``zig-out``, or an
environment override, and it verifies the ABI, release version, runtime
contract, and capability schema before the first real operation. Failures
are :class:`NativeLibraryError`/:class:`UnsupportedPlatformError` with a
reinstall direction; there is no fallback library.
"""

from __future__ import annotations

import ctypes
import importlib.metadata
import importlib.resources
import json
import platform
import threading
from pathlib import Path
from typing import Any

from . import _diagnostics, _ffi


def distribution_version() -> str:
    try:
        return importlib.metadata.version("zenfmt")
    except importlib.metadata.PackageNotFoundError:
        return "0.0.0"


class NativeResult:
    """One opaque native result handle. Accessor payloads are copied into
    Python ownership immediately; :meth:`free` releases the native side
    exactly once and is safe to call again."""

    __slots__ = ("_handle", "_lib", "_limits")

    def __init__(
        self, lib: ctypes.CDLL, handle: int, copy_limits: dict[str, int]
    ) -> None:
        self._lib = lib
        self._handle = handle
        self._limits = copy_limits

    def _read_slice(self, symbol: str, limit: int, label: str) -> bytes | None:
        length = ctypes.c_uint64(0)
        ptr = getattr(self._lib, symbol)(self._handle, ctypes.byref(length))
        if not ptr:
            return None
        if length.value > limit:
            raise _diagnostics.corrupt_result(
                f"the native {label} length {length.value} exceeds its "
                f"Python copy limit {limit}"
            )
        return _ffi.copy_bytes(ptr, length.value)

    def status(self) -> int:
        return self._lib.zenfmt_py_result_status(self._handle)

    def exit_class(self) -> str:
        value = self._lib.zenfmt_py_result_exit_class(self._handle)
        if value >= len(_ffi.EXIT_CLASSES):
            raise _diagnostics.corrupt_result(
                f"exit class tag {value} is outside the ABI's fixed set"
            )
        return _ffi.EXIT_CLASSES[value]

    def reports_json(self) -> bytes:
        report_limit = max(
            self._limits["max_manifest_bytes"],
            self._limits["max_reports_total"] * 4096,
        )
        return (
            self._read_slice(
                "zenfmt_py_result_reports_json", report_limit, "reports JSON"
            )
            or b"[]"
        )

    def manifest_json(self) -> bytes | None:
        return self._read_slice(
            "zenfmt_py_result_manifest_json",
            max(
                self._limits["max_manifest_bytes"],
                self._limits["max_output_bytes"],
            ),
            "manifest",
        )

    def source_format(self) -> str | None:
        raw = self._read_slice("zenfmt_py_result_source_format", 1024, "source format")
        return raw.decode("utf-8") if raw is not None else None

    def output_format(self) -> str | None:
        raw = self._read_slice("zenfmt_py_result_output_format", 1024, "output format")
        return raw.decode("utf-8") if raw is not None else None

    def artifact(self) -> bytes | None:
        return self._read_slice(
            "zenfmt_py_result_artifact",
            self._limits["max_output_bytes"],
            "artifact",
        )

    def artifact_name(self) -> str | None:
        raw = self._read_slice(
            "zenfmt_py_result_artifact_name",
            self._limits["max_entry_name_bytes"],
            "artifact name",
        )
        return raw.decode("utf-8") if raw is not None else None

    def resources(self) -> list[tuple[str, bytes, str]]:
        """Every embedded resource as (relative path, bytes, digest hex),
        in deterministic bridge order."""
        count = self._lib.zenfmt_py_result_resource_count(self._handle)
        if count > self._limits["max_resources"]:
            raise _diagnostics.corrupt_result(
                f"the result carries {count} resources, above max_resources "
                f"({self._limits['max_resources']})"
            )
        entries: list[tuple[str, bytes, str]] = []
        remaining_bytes = self._limits["max_resource_bytes"]
        for index in range(count):
            view = _ffi.ResourceView()
            status = self._lib.zenfmt_py_result_resource(
                self._handle, index, ctypes.byref(view)
            )
            if status != 0:
                raise _diagnostics.corrupt_result(
                    f"resource {index} of {count} is unreadable"
                )
            if view.rel_path.len > 64 * 1024:
                raise _diagnostics.corrupt_result(
                    f"resource {index} has an overlong relative path"
                )
            if view.bytes.len > remaining_bytes:
                raise _diagnostics.corrupt_result(
                    f"resource {index} exceeds the remaining max_resource_bytes "
                    f"budget ({remaining_bytes})"
                )
            if view.digest_hex.len > 128:
                raise _diagnostics.corrupt_result(
                    f"resource {index} has an overlong digest"
                )
            entries.append(
                (
                    _ffi.copy_bytes(view.rel_path.ptr, view.rel_path.len).decode(
                        "utf-8"
                    ),
                    _ffi.copy_bytes(view.bytes.ptr, view.bytes.len),
                    _ffi.copy_bytes(view.digest_hex.ptr, view.digest_hex.len).decode(
                        "ascii"
                    ),
                )
            )
            remaining_bytes -= view.bytes.len
        return entries

    def free(self) -> None:
        handle, self._handle = self._handle, None
        if handle is not None:
            self._lib.zenfmt_py_result_free(handle)


class Bridge:
    """The verified native bridge: a loaded, prototyped ``ctypes.CDLL``
    plus its validated identity and raw capability JSON."""

    __slots__ = (
        "_lib",
        "abi_major",
        "abi_minor",
        "capability_json",
        "native_version",
    )

    def __init__(
        self,
        lib: ctypes.CDLL,
        *,
        abi_major: int,
        abi_minor: int,
        native_version: str,
        capability_json: bytes,
    ) -> None:
        self._lib = lib
        self.abi_major = abi_major
        self.abi_minor = abi_minor
        self.native_version = native_version
        self.capability_json = capability_json

    def convert(
        self,
        *,
        options_json: bytes,
        input_bytes: bytes | None,
        input_path: bytes | None,
        output_path: bytes | None,
        copy_limits: dict[str, int],
    ) -> NativeResult:
        """One native conversion. The GIL is released for the duration of
        the foreign call by ``ctypes`` itself."""
        request = _ffi.Request()
        keepalive: list[Any] = []

        def as_slice(data: bytes | None) -> _ffi.Slice:
            if not data:
                return _ffi.Slice(None, len(data or b""))
            buffer = ctypes.create_string_buffer(data, len(data))
            keepalive.append(buffer)
            return _ffi.Slice(
                ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)), len(data)
            )

        def as_path(data: bytes | None) -> _ffi.PathSlice:
            if data is None:
                return _ffi.PathSlice(None, 0)
            buffer = ctypes.create_string_buffer(data, len(data))
            keepalive.append(buffer)
            units = (
                len(data) // 2
                if _ffi.expected_path_encoding() == _ffi.PATH_ENCODING_UTF16LE
                else len(data)
            )
            return _ffi.PathSlice(ctypes.cast(buffer, ctypes.c_void_p), units)

        request.options_json = as_slice(options_json)
        request.input_bytes = as_slice(input_bytes)
        request.input_path = as_path(input_path)
        request.output_path = as_path(output_path)

        # `keepalive` pins every buffer for the duration of the call; the
        # bridge retains no pointer afterwards.
        handle = self._lib.zenfmt_py_convert(ctypes.byref(request))
        if not handle:
            raise _diagnostics.out_of_memory()
        return NativeResult(self._lib, handle, copy_limits)


_lock = threading.Lock()
_bridge: Bridge | None = None


def bridge() -> Bridge:
    """The lazily loaded, verified bridge singleton. Thread-safe; a
    failure is re-raised fresh on every call rather than cached."""
    global _bridge
    loaded = _bridge
    if loaded is not None:
        return loaded
    with _lock:
        if _bridge is None:
            _bridge = _load_and_verify()
        return _bridge


def _bridge_path() -> Path:
    filename = _ffi.library_filename()
    if filename is None:
        raise _diagnostics.unsupported_platform(platform.system(), platform.machine())
    resource = importlib.resources.files("zenfmt") / "_native" / filename
    # The bridge must be a real on-disk file: zip and namespace installs
    # cannot be loaded and are never extracted to a predictable path.
    try:
        if not isinstance(resource, Path):
            raise _diagnostics.bridge_missing(str(resource))
        if not resource.is_file():
            raise _diagnostics.bridge_missing(str(resource))
        return resource.resolve(strict=True)
    except (KeyboardInterrupt, SystemExit, GeneratorExit):
        raise
    except OSError as error:
        raise _diagnostics.bridge_load_failed(str(resource), error) from error


def _load_and_verify() -> Bridge:
    path = _bridge_path()
    try:
        lib = ctypes.CDLL(str(path))
    except OSError as error:
        raise _diagnostics.bridge_load_failed(str(path), error) from error

    for symbol, (argtypes, restype) in _ffi.PROTOTYPES.items():
        try:
            function = getattr(lib, symbol)
        except AttributeError as error:
            raise _diagnostics.bridge_symbol_missing(symbol, error) from error
        try:
            function.argtypes = list(argtypes)
            function.restype = restype
        except (TypeError, ValueError) as error:
            raise _diagnostics.runtime_mismatch(
                f"the bridge symbol `{symbol}` rejected its required ctypes prototype"
            ) from error

    packed = lib.zenfmt_py_abi_version()
    major, minor = packed >> 16, packed & 0xFFFF
    if major != _ffi.REQUIRED_ABI_MAJOR or minor < _ffi.MINIMUM_ABI_MINOR:
        raise _diagnostics.abi_mismatch(
            major,
            minor,
            required_major=_ffi.REQUIRED_ABI_MAJOR,
            minimum_minor=_ffi.MINIMUM_ABI_MINOR,
        )

    info = _ffi.RuntimeInfo()
    lib.zenfmt_py_runtime_info(ctypes.byref(info))
    if info.pointer_bits != ctypes.sizeof(ctypes.c_void_p) * 8:
        raise _diagnostics.runtime_mismatch(
            f"the bridge is {info.pointer_bits}-bit but this interpreter "
            f"is {ctypes.sizeof(ctypes.c_void_p) * 8}-bit"
        )
    if info.path_encoding != _ffi.expected_path_encoding():
        raise _diagnostics.runtime_mismatch(
            "the bridge and interpreter disagree about the native path encoding"
        )

    length = ctypes.c_uint64(0)
    version_ptr = lib.zenfmt_py_zenfmt_version(ctypes.byref(length))
    if not version_ptr:
        raise _diagnostics.corrupt_result("the bridge returned no version")
    if length.value > 1024:
        raise _diagnostics.corrupt_result("the bridge version is over 1024 bytes")
    try:
        native_version = _ffi.copy_bytes(version_ptr, length.value).decode("utf-8")
    except UnicodeError as error:
        raise _diagnostics.corrupt_result(
            "the bridge version is not valid UTF-8"
        ) from error
    installed = distribution_version()
    if _pep440(native_version) != installed:
        raise _diagnostics.version_mismatch(native_version, installed)

    capability_ptr = lib.zenfmt_py_capabilities(ctypes.byref(length))
    if not capability_ptr:
        raise _diagnostics.capabilities_invalid("the bridge returned none")
    if length.value > 16 * 1024 * 1024:
        raise _diagnostics.capabilities_invalid(
            "the capability JSON exceeds the 16 MiB loader limit"
        )
    capability_json = _ffi.copy_bytes(capability_ptr, length.value)
    try:
        capability_document = json.loads(capability_json)
        if not isinstance(capability_document, dict):
            raise TypeError("the top-level value is not an object")
        schema = capability_document.get("schema")
    except (TypeError, UnicodeError, ValueError) as error:
        raise _diagnostics.capabilities_invalid(
            f"the capability JSON is invalid ({type(error).__name__})"
        ) from error
    if schema != _ffi.CAPABILITY_SCHEMA:
        raise _diagnostics.capabilities_invalid(
            f"capability schema {schema} is not the supported {_ffi.CAPABILITY_SCHEMA}"
        )

    return Bridge(
        lib,
        abi_major=major,
        abi_minor=minor,
        native_version=native_version,
        capability_json=capability_json,
    )


def _pep440(semver: str) -> str:
    """The documented SemVer -> PEP 440 mapping; must agree with the
    packaging hook's translation (parity-tested)."""
    base, sep, pre = semver.partition("-")
    if not sep:
        return base
    kind, _, number = pre.partition(".")
    spelling = {"rc": "rc", "alpha": "a", "beta": "b"}.get(kind)
    if spelling is None or not number.isdigit():
        return semver
    return f"{base}{spelling}{number}"
