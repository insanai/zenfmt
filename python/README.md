# zenfmt

Universal document conversion as a typed, dependency-free Python library.
zenfmt reads 19 formats—DOCX, DOC, ODT, RTF, XLSX, XLS, XLSB, ODS, CSV, PPTX,
PPT, ODP, EPUB, PDF, HTML, Markdown, AsciiDoc, reStructuredText, and plain
text—and writes clean Markdown through a native engine written in Zig. The
wheel bundles the engine: no runtime dependencies, subprocesses, or network
downloads are required, and the GIL is released during conversion.

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

Every library error includes structured facts and an actionable hint. Handle
stable codes in application logic and render the message for people:

```python
try:
    zenfmt.convert(uploaded_bytes, name="upload.docx")
except zenfmt.ConversionError as error:
    log.info("conversion failed", extra={"code": error.code})
    print(error.hint)
```

## Security and authority

A string is always a path. Passing a path explicitly authorizes zenfmt to read
that file and, when present, its adjacent digest-bound `.zenfmt.json` manifest.
Passing bytes or a binary reader grants no filesystem authority: `name` is
display-only, is never opened, and no adjacent file is inspected. External
resource references are reported in `conversion.resources` but are never
fetched. The runtime does not read configuration from the environment, follow
includes, resolve external entities, discover plugins, or use the network.

Conversion is bounded by `zenfmt.Limits`; the defaults cap input, decoded
text, archive expansion, document structure, reports, embedded resources, and
artifact output. Services handling large or untrusted documents should lower
those limits and publish path output inside a per-job directory with suitable
permissions and quotas. Path publication is transactional and refuses to
replace an existing artifact ensemble unless `overwrite=True`.

The native engine runs inside the Python process with that process's
authority. A wheel is not a sandbox. Workloads that need a stronger isolation
boundary should perform conversion in a restricted worker process or
container. Independent calls are thread-safe; create worker processes before
starting conversion threads, or use the multiprocessing `spawn` start method.

Wheels are published for Linux (manylinux and musl, x86_64 and aarch64),
macOS 12+ (x86_64 and arm64), and Windows x86_64, for CPython 3.10–3.14.
Building from the source distribution requires only a
[Zig](https://ziglang.org/) toolchain — the sdist carries the complete engine
source under `engine/`.

CLI archives and Python wheels are attached to each
[GitHub release](https://github.com/insanai/zenfmt/releases). This package is
the Python surface of the [zenfmt monorepo](https://github.com/insanai/zenfmt);
the engine, design records (ZDS 0014 covers this library), and development
workflow live there.

zenfmt is authored by Vikrant Rathore with assistance from Ronak Rathore.
