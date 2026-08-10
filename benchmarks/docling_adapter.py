"""Docling conversion adapter for the native benchmark (ZDS 0016).

Converts one document to Markdown through Docling's model-free backends and
consumes the result, so the timed harness measures a real conversion. The
adapter refuses anything that would load a model: the format allowlist below
carries only the simple backends (Office Open XML, HTML, CSV, Markdown,
AsciiDoc), and every model download is disabled, so a slip into the PDF or
OCR pipeline fails the sample rather than silently pulling weights.

This mirrors the benchmark record: the row is labelled "Docling parser only"
and does not measure Docling's AI features. The Zig harness gates which
corpus files reach this adapter; the guards here are the second line.
"""

from __future__ import annotations

import argparse
import os
import sys

# Deny every network path before Docling is imported: an attempted model
# fetch during a timed run must fail the sample, never reach the network.
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

from docling.datamodel.base_models import InputFormat  # noqa: E402
from docling.document_converter import DocumentConverter  # noqa: E402

# The model-free formats: these backends parse the document structure
# directly and load no layout, OCR, table, or enrichment model.
ALLOWED_FORMATS = [
    InputFormat.DOCX,
    InputFormat.XLSX,
    InputFormat.PPTX,
    InputFormat.HTML,
    InputFormat.CSV,
    InputFormat.MD,
    InputFormat.ASCIIDOC,
]

# The corpus extensions those formats cover.
ALLOWED_EXTENSIONS = frozenset(
    {"docx", "xlsx", "pptx", "html", "htm", "csv", "md", "markdown", "adoc"}
)


def convert(path: str) -> int:
    extension = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if extension not in ALLOWED_EXTENSIONS:
        print(f"docling-adapter: {extension} is not a model-free format", file=sys.stderr)
        return 3

    converter = DocumentConverter(allowed_formats=ALLOWED_FORMATS)
    result = converter.convert(path)
    markdown = result.document.export_to_markdown()
    # Consume the result so the conversion is not optimised away.
    if not markdown:
        print("docling-adapter: empty Markdown output", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Docling model-free benchmark adapter")
    parser.add_argument("--convert", metavar="PATH", required=True)
    args = parser.parse_args()
    try:
        return convert(args.convert)
    except Exception as error:  # noqa: BLE001 — a failed sample must exit non-zero
        print(f"docling-adapter: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
