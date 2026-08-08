"""Loader behavior and FFI declarations: lazy loading, platform map,
structure layouts, and prototype completeness."""

from __future__ import annotations

import ctypes
import subprocess
import sys
from pathlib import Path

import pytest

import zenfmt
from zenfmt import _ffi
from zenfmt import _loader as loader_module
from zenfmt._limits import LIMIT_TABLE


def test_import_does_not_load_the_native_library() -> None:
    # A fresh interpreter importing zenfmt must not touch ctypes.CDLL.
    script = (
        "import sys\n"
        "import zenfmt\n"
        "assert zenfmt.__version__\n"
        "assert zenfmt._loader._bridge is None\n"
        "print('lazy-ok')\n"
    )
    completed = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        check=False,
        cwd=str(Path(__file__).resolve().parents[2] / "src"),
    )
    assert completed.returncode == 0, completed.stderr
    assert "lazy-ok" in completed.stdout


def test_platform_filename_map() -> None:
    name = _ffi.library_filename()
    if sys.platform == "darwin":
        assert name == "libzenfmt_py.dylib"
    elif sys.platform == "win32":
        assert name == "zenfmt_py.dll"
    else:
        assert name == "libzenfmt_py.so"


def test_missing_bridge_is_a_focused_native_library_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(loader_module, "_bridge", None)
    monkeypatch.setattr(
        loader_module,
        "_bridge_path",
        lambda: (_ for _ in ()).throw(
            loader_module._diagnostics.bridge_missing("/pkg/_native/lib.so")
        ),
    )
    with pytest.raises(zenfmt.NativeLibraryError) as info:
        loader_module.bridge()
    assert info.value.code == "python.bridge-missing"
    assert "reinstall" in str(info.value).lower()
    # Failures are not cached: the next call re-attempts.
    with pytest.raises(zenfmt.NativeLibraryError):
        loader_module.bridge()


def test_structure_layouts_match_the_abi() -> None:
    assert ctypes.sizeof(_ffi.Slice) == 16
    assert ctypes.sizeof(_ffi.PathSlice) == 16
    assert ctypes.sizeof(_ffi.RuntimeInfo) == 16
    assert ctypes.sizeof(_ffi.Request) == 64
    assert ctypes.sizeof(_ffi.ResourceView) == 48
    assert [name for name, _ in _ffi.Request._fields_] == [
        "options_json",
        "input_bytes",
        "input_path",
        "output_path",
    ]


def test_prototype_table_is_complete_and_typed() -> None:
    expected = {
        "zenfmt_py_abi_version",
        "zenfmt_py_runtime_info",
        "zenfmt_py_zenfmt_version",
        "zenfmt_py_capabilities",
        "zenfmt_py_convert",
        "zenfmt_py_result_status",
        "zenfmt_py_result_exit_class",
        "zenfmt_py_result_reports_json",
        "zenfmt_py_result_manifest_json",
        "zenfmt_py_result_source_format",
        "zenfmt_py_result_output_format",
        "zenfmt_py_result_artifact",
        "zenfmt_py_result_artifact_name",
        "zenfmt_py_result_resource_count",
        "zenfmt_py_result_resource",
        "zenfmt_py_result_free",
    }
    assert set(_ffi.PROTOTYPES) == expected
    for name, (argtypes, _) in _ffi.PROTOTYPES.items():
        assert isinstance(argtypes, tuple), name


def test_abi_constants_are_pinned() -> None:
    assert _ffi.REQUIRED_ABI_MAJOR == 1
    assert _ffi.MINIMUM_ABI_MINOR == 0
    assert (_ffi.STATUS_SUCCESS, _ffi.STATUS_FAILED, _ffi.STATUS_INVALID_REQUEST) == (
        0,
        1,
        2,
    )
    assert _ffi.EXIT_CLASSES == ("conversion", "usage", "limit")


def test_native_lengths_are_refused_before_copying(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    limits = {name: default for name, (default, _) in LIMIT_TABLE.items()}

    class OversizeLib:
        def zenfmt_py_result_artifact(self, handle: int, out_length: object) -> int:
            out_length._obj.value = limits["max_output_bytes"] + 1  # type: ignore[attr-defined]
            return 1

        def zenfmt_py_result_resource_count(self, handle: int) -> int:
            return limits["max_resources"] + 1

        def zenfmt_py_result_free(self, handle: int) -> None:
            pass

    monkeypatch.setattr(
        _ffi,
        "copy_bytes",
        lambda *args: pytest.fail("oversized native data reached ctypes.string_at"),
    )
    result = loader_module.NativeResult(OversizeLib(), 1, limits)  # type: ignore[arg-type]
    with pytest.raises(zenfmt.NativeLibraryError, match="copy limit"):
        result.artifact()
    with pytest.raises(zenfmt.NativeLibraryError, match="max_resources"):
        result.resources()


def test_pep440_mapping_matches_the_packaging_hook() -> None:
    import importlib.util

    project = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location(
        "hatch_build", project / "hatch_build.py"
    )
    assert spec is not None
    assert spec.loader is not None
    hatch_build = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hatch_build)
    for semver in ("0.1.0", "1.2.3", "0.2.0-rc.1", "1.0.0-alpha.2", "1.0.0-beta.3"):
        assert loader_module._pep440(semver) == hatch_build.semver_to_pep440(semver), (
            semver
        )
