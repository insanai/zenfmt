"""Hatchling adapters for the zenfmt monorepo (ZDS 0014).

Two small pieces: ``PROJECT_VERSION`` (evaluated by hatchling's ``code``
version source) translating the canonical ``build.zig.zon`` version to
PEP 440, and a wheel build hook that asks the root Zig build graph for
the native bridge and packages it under ``zenfmt/_native`` with the
matching platform tag. Native compilation is owned by ``zig build``; this
file never duplicates target logic beyond the closed table below, and it
is a no-op for editable installs (development staging is
``zig build python-sync``).
"""

from __future__ import annotations

import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

#: Zig target triple -> (wheel platform tag, bridge filename). The seven
#: supported wheel targets, exactly (ZDS 0014). Unknown triples are a hard
#: error, never a guessed tag.
WHEEL_TARGETS: dict[str, tuple[str, str]] = {
    "x86_64-linux-gnu.2.17": ("manylinux_2_17_x86_64", "libzenfmt_py.so"),
    "aarch64-linux-gnu.2.17": ("manylinux_2_17_aarch64", "libzenfmt_py.so"),
    "x86_64-linux-musl": ("musllinux_1_2_x86_64", "libzenfmt_py.so"),
    "aarch64-linux-musl": ("musllinux_1_2_aarch64", "libzenfmt_py.so"),
    "x86_64-macos.12.0": ("macosx_12_0_x86_64", "libzenfmt_py.dylib"),
    "aarch64-macos.12.0": ("macosx_12_0_arm64", "libzenfmt_py.dylib"),
    "x86_64-windows-gnu": ("win_amd64", "zenfmt_py.dll"),
}


def read_zon_version(root: Path) -> str:
    """The canonical SemVer version from ``build.zig.zon``."""
    zon = (root / "build.zig.zon").read_text(encoding="utf-8")
    match = re.search(r'\.version\s*=\s*"([^"]+)"', zon)
    if match is None:
        raise RuntimeError("build.zig.zon carries no .version field")
    return match.group(1)


def read_minimum_zig_version(root: Path) -> str:
    zon = (root / "build.zig.zon").read_text(encoding="utf-8")
    match = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon)
    return match.group(1) if match else "unknown"


def semver_to_pep440(semver: str) -> str:
    """The deterministic SemVer -> PEP 440 mapping (ZDS 0014).

    Stable versions map unchanged; ``-rc.N``/``-alpha.N``/``-beta.N``
    prereleases map to ``rcN``/``aN``/``bN``; other prerelease or build
    identifiers are refused because they must never reach a distributable
    artifact.
    """
    if "+" in semver:
        raise RuntimeError(
            f"version {semver!r} carries build metadata and is not "
            "distributable; release from a clean tagged version"
        )
    base, sep, pre = semver.partition("-")
    if not re.fullmatch(r"\d+\.\d+\.\d+", base):
        raise RuntimeError(f"version {semver!r} is not MAJOR.MINOR.PATCH")
    if not sep:
        return base
    pre_match = re.fullmatch(r"(rc|alpha|beta)\.(\d+)", pre)
    if pre_match is None:
        raise RuntimeError(
            f"prerelease identifier {pre!r} has no defined PEP 440 mapping"
        )
    spelling = {"rc": "rc", "alpha": "a", "beta": "b"}[pre_match.group(1)]
    return f"{base}{spelling}{pre_match.group(2)}"


def host_triple() -> str:
    machine = platform.machine().lower()
    arch = {
        "x86_64": "x86_64",
        "amd64": "x86_64",
        "arm64": "aarch64",
        "aarch64": "aarch64",
    }.get(machine)
    if arch is None:
        raise RuntimeError(f"unsupported build machine {machine!r}")
    if sys.platform == "darwin":
        return f"{arch}-macos.12.0"
    if sys.platform == "win32":
        if arch != "x86_64":
            raise RuntimeError("only x86_64 Windows wheels are supported")
        return "x86_64-windows-gnu"
    if sys.platform.startswith("linux"):
        # A musl interpreter builds the musl wheel; glibc builds manylinux.
        libc = platform.libc_ver()[0]
        if libc == "glibc":
            return f"{arch}-linux-gnu.2.17"
        return f"{arch}-linux-musl"
    raise RuntimeError(f"unsupported build platform {sys.platform!r}")


#: Evaluated by hatchling's ``code`` version source (pyproject.toml).
PROJECT_VERSION = semver_to_pep440(read_zon_version(Path(__file__).parent))


class NativeBridgeHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict) -> None:
        if self.target_name != "wheel":
            return
        if version == "editable":
            # Development staging is `zig build python-sync`; the editable
            # install maps `zenfmt` to python/src/zenfmt where that step
            # places the host bridge.
            return

        root = Path(self.root)
        triple = os.environ.get("ZENFMT_WHEEL_TARGET") or host_triple()
        if triple not in WHEEL_TARGETS:
            known = "\n  ".join(sorted(WHEEL_TARGETS))
            raise RuntimeError(
                f"ZENFMT_WHEEL_TARGET={triple!r} is not a supported wheel "
                f"target. Supported targets:\n  {known}"
            )
        tag, filename = WHEEL_TARGETS[triple]

        prefix = root / "zig-out" / "python" / triple
        self._build_bridge(root, triple, prefix)

        artifact = prefix / "lib" / filename
        if not artifact.is_file():
            raise RuntimeError(
                f"zig build python-native completed but {artifact} does not "
                "exist; the build graph and this hook disagree about the "
                "bridge artifact name"
            )

        build_data["pure_python"] = False
        build_data["infer_tag"] = False
        build_data["tag"] = f"py3-none-{tag}"
        build_data["force_include"][str(artifact)] = f"zenfmt/_native/{filename}"

    def _build_bridge(self, root: Path, triple: str, prefix: Path) -> None:
        zig = os.environ.get("ZENFMT_ZIG") or shutil.which("zig")
        if zig is None:
            needed = read_minimum_zig_version(root)
            raise RuntimeError(
                "BUILDING zenfmt FROM SOURCE NEEDS ZIG\n\n"
                f"No `zig` executable was found on PATH, and building the "
                f"native bridge requires Zig {needed}.\n\n"
                "No wheel was produced.\n\n"
                "What you can do:\n\n"
                f"    Install Zig {needed} from https://ziglang.org/download "
                "and retry, or install an official zenfmt wheel for your "
                "platform instead of building from source."
            )
        argv = [
            zig,
            "build",
            "python-native",
            "-Doptimize=ReleaseSafe",
            f"-Dtarget={triple}",
            "--prefix",
            str(prefix),
        ]
        completed = subprocess.run(
            argv,
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            needed = read_minimum_zig_version(root)
            raise RuntimeError(
                "THE NATIVE BRIDGE FAILED TO BUILD\n\n"
                f"`{' '.join(argv)}` exited with "
                f"{completed.returncode}.\n\n{completed.stderr}\n\n"
                "No wheel was produced.\n\n"
                "What you can do:\n\n"
                f"    Confirm Zig {needed} is installed, then retry; or "
                "install an official zenfmt wheel for your platform."
            )
