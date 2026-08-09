"""Write a deterministic size and SHA-256 manifest for release files."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--out", default="artifact-manifest.json")
    args = parser.parse_args()

    files = []
    for path in sorted(args.directory.iterdir(), key=lambda item: item.name):
        if not path.is_file() or path.name in {args.out, "SHA256SUMS"}:
            continue
        data = path.read_bytes()
        files.append(
            {
                "name": path.name,
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        )
    output = {
        "schema": 1,
        "version": args.version,
        "target": args.target,
        "files": files,
    }
    (args.directory / args.out).write_text(
        json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
