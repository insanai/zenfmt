"""Pure ``ctypes`` declarations for the private bridge ABI (ZDS 0014).

No library is loaded here; :mod:`zenfmt._loader` owns that. Everything in
this module is testable without a native artifact: structure layouts,
prototype tables, and the numeric constants fixed by the ABI version.
"""

from __future__ import annotations

import ctypes
import sys

#: The ABI this Python layer speaks. Major must match exactly; the bridge
#: minor must be at least the minimum understood minor.
REQUIRED_ABI_MAJOR = 1
MINIMUM_ABI_MINOR = 0

#: The capability JSON schema this layer understands.
CAPABILITY_SCHEMA = 1

#: The options JSON schema this layer emits.
OPTIONS_SCHEMA = 1

STATUS_SUCCESS = 0
STATUS_FAILED = 1
STATUS_INVALID_REQUEST = 2

EXIT_CLASSES = ("conversion", "usage", "limit")

PATH_ENCODING_POSIX_BYTES = 1
PATH_ENCODING_UTF16LE = 2


class Slice(ctypes.Structure):
    _fields_ = (
        ("ptr", ctypes.POINTER(ctypes.c_ubyte)),
        ("len", ctypes.c_uint64),
    )


class PathSlice(ctypes.Structure):
    _fields_ = (
        ("ptr", ctypes.c_void_p),
        ("len", ctypes.c_uint64),
    )


class RuntimeInfo(ctypes.Structure):
    _fields_ = (
        ("abi_major", ctypes.c_uint32),
        ("abi_minor", ctypes.c_uint32),
        ("pointer_bits", ctypes.c_uint32),
        ("path_encoding", ctypes.c_uint32),
    )


class Request(ctypes.Structure):
    _fields_ = (
        ("options_json", Slice),
        ("input_bytes", Slice),
        ("input_path", PathSlice),
        ("output_path", PathSlice),
    )


class ResourceView(ctypes.Structure):
    _fields_ = (
        ("rel_path", Slice),
        ("bytes", Slice),
        ("digest_hex", Slice),
    )


_BYTES_PTR = ctypes.POINTER(ctypes.c_ubyte)
_LEN_PTR = ctypes.POINTER(ctypes.c_uint64)

#: symbol name -> (argtypes, restype). Complete prototypes: ctypes never
#: guesses a signature for any bridge call.
PROTOTYPES: dict[str, tuple[tuple, object]] = {
    "zenfmt_py_abi_version": ((), ctypes.c_uint32),
    "zenfmt_py_runtime_info": ((ctypes.POINTER(RuntimeInfo),), None),
    "zenfmt_py_zenfmt_version": ((_LEN_PTR,), _BYTES_PTR),
    "zenfmt_py_capabilities": ((_LEN_PTR,), _BYTES_PTR),
    "zenfmt_py_convert": ((ctypes.POINTER(Request),), ctypes.c_void_p),
    "zenfmt_py_result_status": ((ctypes.c_void_p,), ctypes.c_uint32),
    "zenfmt_py_result_exit_class": ((ctypes.c_void_p,), ctypes.c_uint32),
    "zenfmt_py_result_reports_json": (
        (ctypes.c_void_p, _LEN_PTR),
        _BYTES_PTR,
    ),
    "zenfmt_py_result_manifest_json": (
        (ctypes.c_void_p, _LEN_PTR),
        _BYTES_PTR,
    ),
    "zenfmt_py_result_source_format": (
        (ctypes.c_void_p, _LEN_PTR),
        _BYTES_PTR,
    ),
    "zenfmt_py_result_output_format": (
        (ctypes.c_void_p, _LEN_PTR),
        _BYTES_PTR,
    ),
    "zenfmt_py_result_artifact": ((ctypes.c_void_p, _LEN_PTR), _BYTES_PTR),
    "zenfmt_py_result_artifact_name": (
        (ctypes.c_void_p, _LEN_PTR),
        _BYTES_PTR,
    ),
    "zenfmt_py_result_resource_count": ((ctypes.c_void_p,), ctypes.c_uint64),
    "zenfmt_py_result_resource": (
        (ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ResourceView)),
        ctypes.c_uint32,
    ),
    "zenfmt_py_result_free": ((ctypes.c_void_p,), None),
}


def library_filename() -> str | None:
    """The exact packaged bridge filename for the running platform, or
    None when the platform is unsupported."""
    if sys.platform == "darwin":
        return "libzenfmt_py.dylib"
    if sys.platform == "win32":
        return "zenfmt_py.dll"
    if sys.platform.startswith("linux"):
        return "libzenfmt_py.so"
    return None


def expected_path_encoding() -> int:
    if sys.platform == "win32":
        return PATH_ENCODING_UTF16LE
    return PATH_ENCODING_POSIX_BYTES


def copy_bytes(ptr, length: int) -> bytes:
    """Copies a borrowed native slice into Python-owned bytes."""
    if length == 0:
        return b""
    return ctypes.string_at(ptr, length)
