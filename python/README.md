# zenfmt

Universal document conversion as a typed, dependency-free Python library:
19 input formats (DOCX, PDF, EPUB, ODT, XLSX, PPTX, HTML, LaTeX, and more)
converted to clean Markdown by a native engine written in Zig. The wheel
bundles the engine — no runtime dependencies, no subprocesses, no network —
and the GIL is released for the duration of every conversion.

```sh
pip install zenfmt
```

```python
import zenfmt

# A str is always a path; the result is the whole in-memory ensemble:
# artifact bytes, embedded resources, the canonical manifest, and reports.
conversion = zenfmt.convert("report.docx")
print(conversion.text)
for report in conversion.reports:
    print(report.code, report.problem)

# Bytes are explicit; the source format is named or sniffed.
conversion = zenfmt.convert(uploaded_bytes, name="upload.docx", to="markdown")

# An output path selects transactional publication: the artifact, its media,
# and a manifest land together or not at all. Graded strictness refuses
# priced fidelity loss before anything is written.
conversion = zenfmt.convert(
    "report.docx", output="build/report.md", strict="structure"
)
```

Failures raise a compact exception tree (`ConversionError`,
`LimitExceededError`, `UnknownFormatError`, …) whose messages answer the same
four questions as the engine's CLI diagnostics — what happened, where, what it
costs, and what you can do. Reusable policy lives in immutable
`zenfmt.Converter` values; there is no global configuration or environment
lookup. `zenfmt.formats()` enumerates the compiled-in format capabilities.

Wheels are published for Linux (manylinux and musl, x86_64 and aarch64),
macOS 12+ (x86_64 and arm64), and Windows x86_64, for CPython 3.10–3.14.
Building from the source distribution requires only a
[Zig](https://ziglang.org/) toolchain — the sdist carries the complete engine
source under `engine/`.

This package is the Python surface of the
[zenfmt monorepo](https://github.com/insan-ai/zenfmt); the engine, design
records (ZDS 0014 covers this library), and development workflow live there.
