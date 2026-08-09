"""Create a deterministic SPDX 2.3 inventory for the release asset set."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--epoch", type=int, required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    files = []
    relationships = []
    for index, path in enumerate(sorted(args.directory.iterdir()), start=1):
        if not path.is_file() or path.name == args.out:
            continue
        spdx_id = f"SPDXRef-File-{index}"
        files.append(
            {
                "SPDXID": spdx_id,
                "fileName": path.name,
                "checksums": [
                    {
                        "algorithm": "SHA256",
                        "checksumValue": hashlib.sha256(path.read_bytes()).hexdigest(),
                    }
                ],
            }
        )
        relationships.append(
            {
                "spdxElementId": "SPDXRef-Package-zenfmt",
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": spdx_id,
            }
        )

    created = datetime.fromtimestamp(args.epoch, tz=timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"zenfmt-{args.version}-release",
        "documentNamespace": (
            "https://github.com/insanai/zenfmt/releases/download/"
            f"v{args.version}/sbom/{args.revision}"
        ),
        "creationInfo": {
            "created": created,
            "creators": ["Organization: insanai", "Tool: zenfmt-release-sbom"],
        },
        "packages": [
            {
                "name": "zenfmt",
                "SPDXID": "SPDXRef-Package-zenfmt",
                "versionInfo": args.version,
                "downloadLocation": (
                    f"https://github.com/insanai/zenfmt/tree/v{args.version}"
                ),
                "filesAnalyzed": True,
                "licenseConcluded": "MIT",
                "licenseDeclared": "MIT",
                "copyrightText": ("Copyright 2026 Vikrant Rathore and Ronak Rathore"),
            }
        ],
        "files": files,
        "relationships": [
            {
                "spdxElementId": "SPDXRef-DOCUMENT",
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": "SPDXRef-Package-zenfmt",
            },
            *relationships,
        ],
    }
    (args.directory / args.out).write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
