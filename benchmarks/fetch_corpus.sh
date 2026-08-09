#!/bin/sh
# Fetches the benchmark corpus described by benchmarks/corpus.json: real-world
# documents from public sample repositories (filesamples.com, Apache POI and
# LibreOffice test data, Project Gutenberg, W3C). The corpus is not committed;
# run this script once before `zig build benchmark`. Pass one or more manifest
# filenames to fetch and verify only those entries.
#
# Every file is verified against the SHA-256 recorded in the manifest. A
# published benchmark number is only meaningful if the bytes it was measured
# on are known, so a digest mismatch and a failed download are both errors
# here, not warnings: a partial or drifted corpus produces numbers that look
# fine and are not comparable to anything.
set -eu

root="$(dirname "$0")"
corpus="$root/corpus"
manifest="$root/corpus.json"
mkdir -p "$corpus"

if [ ! -s "$manifest" ]; then
    echo "missing corpus manifest: $manifest" >&2
    exit 1
fi

digest() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

# The manifest is the single source of names, URLs, and digests. Reading it
# with python keeps that true rather than restating the list in shell.
entries="$(python3 - "$manifest" "$@" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
selected = set(sys.argv[2:])
known = {entry["name"] for entry in manifest["files"]}
unknown = selected - known
if unknown:
    raise SystemExit("unknown corpus file: " + ", ".join(sorted(unknown)))
for entry in manifest["files"]:
    if selected and entry["name"] not in selected:
        continue
    source = entry["source"]
    if not source.startswith("http"):
        source = "-"
    print(entry["name"], entry["sha256"], source)
PY
)"

# The verification loop reads from a pipe, so it runs in a subshell and any
# variable it sets is lost. Failures are recorded in a file instead, which is
# the difference between this script reporting a drifted corpus and exiting
# zero while printing errors nobody reads.
failures="$(mktemp)"
trap 'rm -f "$failures"' EXIT

# A text-rich ODP: derived from the real Apache deck via LibreOffice when
# installed. Its digest pins one specific conversion, so a different
# LibreOffice version is a corpus change and is reported as a mismatch rather
# than quietly measured.
soffice="/Applications/LibreOffice.app/Contents/MacOS/soffice"
derive_odp() {
    [ -s "$corpus/slides.odp" ] && return 0
    [ -x "$soffice" ] || return 1
    [ -s "$corpus/slides.pptx" ] || return 1
    cp "$corpus/slides.pptx" "$corpus/deck-src.pptx"
    "$soffice" --headless --convert-to odp "$corpus/deck-src.pptx" \
        --outdir "$corpus" >/dev/null 2>&1 || true
    rm -f "$corpus/deck-src.pptx"
    [ -s "$corpus/deck-src.odp" ] || return 1
    mv "$corpus/deck-src.odp" "$corpus/slides.odp"
    return 0
}

echo "$entries" | while read -r name want url; do
    out="$corpus/$name"
    if [ ! -s "$out" ]; then
        if [ "$url" = "-" ]; then
            if ! derive_odp; then
                echo "MISSING $name (derived locally; LibreOffice is required)" >&2
                echo "$name" >>"$failures"
                continue
            fi
        elif ! curl -fsSL --retry 2 --max-time 120 \
            -A "Mozilla/5.0 (zenfmt-bench)" -o "$out.part" "$url"; then
            rm -f "$out.part"
            echo "MISSING $name ($url)" >&2
            echo "$name" >>"$failures"
            continue
        else
            mv "$out.part" "$out"
        fi
    fi

    got="$(digest "$out")"
    if [ "$got" != "$want" ]; then
        echo "MISMATCH $name" >&2
        echo "  expected $want" >&2
        echo "  actual   $got" >&2
        echo "  The source changed, or the file is truncated. Update" >&2
        echo "  benchmarks/corpus.json deliberately and regenerate every" >&2
        echo "  affected result; do not benchmark against it as it is." >&2
        echo "$name" >>"$failures"
        continue
    fi
    echo "ok      $name"
done

if [ -s "$failures" ]; then
    echo >&2
    echo "corpus is incomplete or has drifted; benchmark numbers from it" >&2
    echo "would not be reproducible" >&2
    exit 1
fi

echo
if [ "$#" -eq 0 ]; then
    echo "corpus verified against $manifest"
else
    echo "selected corpus files verified against $manifest"
fi
