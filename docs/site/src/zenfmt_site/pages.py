"""The pages that are generated rather than authored in Typst (ZDS 0015).

The homepage, download, benchmark, security, and not-found routes are all
data-driven: they inject the capability document, the release manifest, and
the benchmark aggregates. Typst is the canonical source for the book and the
records and nothing else, so these are built here from the same data the
engine publishes — which is what keeps a format from appearing on one surface
and not another.

The converter markup below is server-rendered complete and usable before any
script runs. The engine is loaded afterwards and only ever changes the
converter panel: a page whose documentation stops working because WebAssembly
failed to load would be a worse page than one that never had a converter.
"""

from __future__ import annotations

import html
import json
import math
from pathlib import Path

from .shell import Page


def _escape(value: str) -> str:
    return html.escape(str(value), quote=True)


def homepage(capabilities: dict, benchmark: dict | None, baselines: dict) -> Page:
    extensions = sorted(
        {
            ext
            for entry in capabilities["formats"]
            if entry["read"]
            for ext in entry["extensions"]
        }
    )
    readable = sum(1 for entry in capabilities["formats"] if entry["read"])
    accept = ", ".join("." + ext for ext in extensions)

    body = f"""
<section class="hero">
  <p class="eyebrow">zenfmt {_escape(capabilities["version"])}</p>
  <h1>Convert documents to Markdown.</h1>
  <p class="lede">
    Pandoc showed how useful a universal document converter can be. zenfmt is
    a small attempt to explore that idea with an engine written in Zig.
  </p>
  <p class="promise">
    This page converts locally in your browser. It does not upload the file.
  </p>
</section>

<section class="workspace" aria-label="Convert a document">
  <div class="pane pane-input">
    <h2 class="pane-title">1 · Source document</h2>
    <label class="drop" for="source" data-drop>
      <input type="file" id="source" name="source" data-source
             accept="{_escape(accept)}">
      <span class="drop-headline">Drop a file here</span>
      <span class="drop-detail">or choose a file</span>
    </label>
    <button class="text-action" type="button" data-example>Try a safe example</button>
    <p class="file-meta" data-file-meta hidden></p>
    <details class="advanced">
      <summary>Advanced options</summary>
      <label for="strict">Loss policy</label>
      <select id="strict" data-strict>
        <option value="off">Convert and report loss</option>
        <option value="content">Refuse content loss</option>
        <option value="structure">Refuse structural loss</option>
        <option value="exact">Refuse any known loss</option>
      </select>
      <label><input type="checkbox" data-facets> Preserve facet details</label>
    </details>
    <p class="pane-note">
      Format is detected from the file's contents, not its name.
      {readable} formats are supported.
    </p>
    <p class="status" role="status" aria-live="polite" data-status>
      Loading the browser engine…
    </p>
  </div>

  <div class="pane pane-output">
    <h2 class="pane-title">2 · Markdown output · read only</h2>
    <div class="pane-actions">
      <button type="button" data-copy disabled>Copy</button>
      <button type="button" data-download disabled>Download</button>
      <button type="button" data-wrap aria-pressed="true">Wrap lines</button>
      <button type="button" data-cancel hidden>Cancel</button>
      <button type="button" data-reset disabled>Reset</button>
    </div>
    <pre class="output" tabindex="0" aria-label="Converted Markdown, read only"
         data-output></pre>
  </div>
</section>

<section class="reports" aria-label="Conversion reports" data-reports hidden></section>

{_server_homepage(capabilities["version"])}

<section class="help">
  <h2>Need help?</h2>
  <ul class="help-links">
    <li><a href="{{LINK:book/tour/}}">A first conversion</a></li>
    <li><a href="{{LINK:book/limits/}}">Supported formats and limits</a></li>
    <li><a href="{{LINK:book/}}">Read the book</a></li>
    <li><a href="{{LINK:zds/}}">Why this works (design records)</a></li>
  </ul>
</section>

{_benchmark_summary(benchmark, baselines, capabilities["version"])}

<noscript>
  <p class="notice">
    The converter needs JavaScript, because the conversion runs in your
    browser rather than on a server. Everything else on this site — the book,
    the design records, the benchmark method, and the downloads — works
    without it.
  </p>
</noscript>
"""
    return Page(
        route="",
        title="zenfmt — convert documents to Markdown in your browser",
        description=(
            "Convert Word, Excel, PowerPoint, OpenDocument, EPUB, PDF and more "
            "to Markdown entirely inside your browser. Nothing is uploaded."
        ),
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
    )


def _server_homepage(version: str) -> str:
    return f"""
<section class="server-summary">
  <p class="eyebrow">Available in zenfmt {_escape(version)}</p>
  <h2>Use the same converter as a small HTTP service.</h2>
  <p class="lede">
    For workflows that need a shared endpoint, <code>zenfmt serve</code>
    exposes conversion, health, and metrics from the same executable. Open
    mode stays on loopback by default. Secure mode adds users, API keys, an
    audit log, and a small administration interface.
  </p>
  <pre class="command"><code>zenfmt serve
curl -s -T report.docx "http://127.0.0.1:8998/api/v1/convert?to=markdown"
zenfmt serve --secure --data-dir ./zenfmt-data</code></pre>
  <div class="metric-grid">
    <div class="metric"><span>Distribution</span><strong>1 file</strong><small>CLI, server, store migrations, and web assets</small></div>
    <div class="metric"><span>Interface</span><strong>3 themes</strong><small>System by default, with Light and Dark choices</small></div>
    <div class="metric"><span>Native releases</span><strong>7 targets</strong><small>Linux, macOS, and Windows archives</small></div>
  </div>
  <p>
    The release is intended to remain modest in its requirements. It does not
    bundle Java, Python, OCR, VLM, or model assets.
    <a href="{{LINK:book/server/}}">Read the server guide</a> or
    <a href="{{LINK:download/}}">choose a native archive</a>.
  </p>
</section>
"""


def _benchmark_summary(
    benchmark: dict | None, baselines: dict, current_version: str
) -> str:
    """Lead with the three native resource measures, then the server lens."""
    native = baselines.get("native") or {}
    server = baselines.get("server") or {}
    current = native.get("version") == current_version
    state = "Recorded for this release" if current else "Earlier reference run"
    complete = benchmark is not None
    note = (
        "The complete release benchmark is recorded."
        if complete
        else "The full release benchmark is incomplete."
    )
    return f"""
<section class="benchmark-summary">
  <p class="eyebrow">A small reference benchmark</p>
  <h2>The conversion benchmark</h2>
  <p>{note} {state}. Ratios divide the comparison tool by zenfmt, so a value
  above 1.0 means the comparison used more of that measure on shared files.</p>
  {_native_metric_grid(native, "AnyDoc")}
  {_server_metric_grid(server)}
  <p><a href="{{LINK:benchmark/}}">Explanation, method, and raw data</a></p>
</section>
"""


def _ratio(value: float | None) -> str:
    return "—" if value is None else f"{value:.1f}×"


def _size(value: int | None) -> str:
    return "—" if value is None else f"{value / (1024 * 1024):.2f} MiB"


def _paired_seconds(startup: dict) -> str:
    ours = startup.get("zenfmt_ms")
    tika = startup.get("tika_ms")
    if ours is None or tika is None:
        return "pending"
    return f"{ours / 1000:.2f} / {tika / 1000:.2f} s"


def _native_comparison(native: dict, tool: str) -> dict:
    ratios: dict[str, list[float]] = {
        "wall_ratio": [],
        "cpu_ratio": [],
        "rss_ratio": [],
    }
    converted = 0
    for file in native.get("files", []):
        rows = {row.get("tool"): row for row in file.get("tools", [])}
        ours = rows.get("zenfmt", {})
        other = rows.get(tool, {})
        if other.get("ok"):
            converted += 1
        if not ours.get("ok") or not other.get("ok"):
            continue
        for name, metric in (
            ("wall_ratio", "wall_ms"),
            ("cpu_ratio", "cpu_ms"),
            ("rss_ratio", "max_rss_mb"),
        ):
            if ours.get(metric, 0) > 0 and other.get(metric, 0) > 0:
                ratios[name].append(other[metric] / ours[metric])
    return {
        "converted": converted,
        "total": len(native.get("files", [])),
        "shared_files": len(ratios["wall_ratio"]),
        **{name: _geometric_mean(values) for name, values in ratios.items()},
    }


def _geometric_mean(values: list[float]) -> float | None:
    if not values:
        return None
    return math.exp(sum(math.log(value) for value in values) / len(values))


def _native_metric_grid(native: dict, comparison: str) -> str:
    stats = _native_comparison(native, comparison.lower())
    shared = stats["shared_files"]
    return f"""
<div class="benchmark-lens">
  <h3>Native CLI</h3>
  <p>Geometric means over the {shared} files converted by zenfmt and
  {_escape(comparison)}.</p>
  <div class="metric-grid">
    <div class="metric"><span>Speed ratio</span><strong>{_ratio(stats["wall_ratio"])}</strong><small>{_escape(comparison)} wall time / zenfmt</small></div>
    <div class="metric"><span>CPU ratio</span><strong>{_ratio(stats["cpu_ratio"])}</strong><small>{_escape(comparison)} CPU time / zenfmt</small></div>
    <div class="metric"><span>Peak memory ratio</span><strong>{_ratio(stats["rss_ratio"])}</strong><small>{_escape(comparison)} peak RSS / zenfmt</small></div>
  </div>
</div>
"""


def _server_comparison(server: dict) -> dict:
    ratios = [
        row["tika"]["wall_ms"] / row["zenfmt"]["wall_ms"]
        for row in server.get("files", [])
        if row["zenfmt"].get("ok")
        and row["tika"].get("ok")
        and row["zenfmt"].get("wall_ms", 0) > 0
    ]
    throughput = (server.get("throughput") or [{}])[0]
    return {
        "shared_files": len(ratios),
        "wall_ratio": _geometric_mean(ratios),
        "throughput": throughput,
    }


def _server_metric_grid(server: dict) -> str:
    if not server:
        return ""
    stats = _server_comparison(server)
    rss = server.get("peak_rss_mb", {})
    rss_ratio = None
    if rss.get("zenfmt", 0) > 0 and rss.get("tika", 0) > 0:
        rss_ratio = rss["tika"] / rss["zenfmt"]
    throughput = stats["throughput"]
    return f"""
<div class="benchmark-lens">
  <h3>Long-running server, measured separately</h3>
  <p>Warm HTTP conversion against Apache Tika Server on the same host and
  corpus. These values are not mixed into the native CLI ratios.</p>
  <div class="metric-grid">
    <div class="metric"><span>Warm latency ratio</span><strong>{_ratio(stats["wall_ratio"])}</strong><small>Tika / zenfmt over {stats["shared_files"]} shared files</small></div>
    <div class="metric"><span>Peak memory ratio</span><strong>{_ratio(rss_ratio)}</strong><small>Tika / zenfmt sampled RSS</small></div>
    <div class="metric"><span>Throughput at 1 client</span><strong>{_escape(throughput.get("zenfmt_docs_per_s", "pending"))} / {_escape(throughput.get("tika_docs_per_s", "pending"))}</strong><small>zenfmt / Tika documents per second</small></div>
  </div>
</div>
"""


def security_page() -> Page:
    body = """
<h1>Security and privacy</h1>

<h2>Your documents stay on your device</h2>
<p>
  Conversion runs inside your browser as WebAssembly. The document is read by
  the page, handed to a worker, and converted there. It is never sent
  anywhere, and there is no server that could receive it: this site is static
  files.
</p>

<h2>What the engine can do</h2>
<p>
  The browser module is built for a target with no host interface at all. It
  imports nothing — no filesystem, no network, no clock, no randomness, no
  threads — and a release build is checked against that claim by parsing the
  compiled module's import table, not by reading a tool's summary of it. A
  conversion cannot follow a link, fetch an image, or read a file beside the
  one you chose.
</p>

<h2>What this site does not do</h2>
<p>
  There is no analytics, no advertising, no session replay, no remote font, no
  tag manager, and no account. The only thing stored on your device is your
  colour theme preference.
</p>

<h2>What we cannot protect against here</h2>
<p>
  This site is served by GitHub Pages, which does not let us set response
  headers. Our content policy therefore travels in the page, and a policy
  delivered that way cannot stop the site being embedded in a frame by another
  site. We record that as a known gap rather than implying protection we do
  not have. It is tolerable only because this site holds no credential, no
  session, and no action another site could induce you to take.
</p>

<h2>Reporting a problem</h2>
<p>
  Report a vulnerability through the repository's security policy. Please do
  not include a document you cannot share publicly.
</p>
"""
    return Page(
        route="security/",
        title="Security and privacy — zenfmt",
        description=(
            "How zenfmt converts documents without uploading them, what the "
            "browser engine can and cannot do, and what this hosting cannot "
            "protect against."
        ),
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
    )


def not_found_page(base: str) -> Page:
    body = """
<h1>That page is not here</h1>
<p>
  The link may be old, or the address may have a typo. These are the places
  worth trying.
</p>
<ul>
  <li><a href="{LINK:}">Convert a document</a></li>
  <li><a href="{LINK:book/}">The zenfmt book</a></li>
  <li><a href="{LINK:zds/}">The design records</a></li>
  <li><a href="{LINK:download/}">Downloads</a></li>
</ul>
"""
    return Page(
        route="404.html",
        title="Page not found — zenfmt",
        description="The requested page does not exist on this site.",
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
        absolute_base=base,
    )


def index_page(route: str, title: str, intro: str, entries: list[dict]) -> Page:
    """A listing page: the book's chapter tree or the record registry."""
    items = []
    for entry in entries:
        summary = f"<p>{_escape(entry['summary'])}</p>" if entry.get("summary") else ""
        meta = ""
        if entry.get("state"):
            meta = f'<p class="entry-meta">{_escape(entry["state"])}</p>'
        items.append(
            f'<li class="entry"><h2><a href="{{LINK:{entry["route"]}}}">'
            f"{_escape(entry['title'])}</a></h2>{summary}{meta}</li>"
        )
    body = (
        f'<h1>{_escape(title)}</h1><p class="lede">{_escape(intro)}</p>'
        f'<ul class="entries">{"".join(items)}</ul>'
    )
    return Page(
        route=route,
        title=f"{title} — zenfmt",
        description=intro,
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
    )


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def download_page(capabilities: dict, version: str) -> Page:
    """The download page.

    Every target names what it is, what it needs, and how to verify it before
    the visitor commits to a download. There is no single opaque button: a
    page that guesses an architecture and hands over a binary without saying
    which one is a page that cannot be checked.
    """
    formats = sum(1 for entry in capabilities["formats"] if entry["read"])
    release = f"https://github.com/insanai/zenfmt/releases/download/v{version}"

    def asset(name: str, label: str) -> str:
        return (
            f'<a class="download-button" href="{release}/{name}">{_escape(label)}</a>'
        )

    body = f"""
<h1>Download zenfmt {_escape(version)}</h1>
<p class="lede">
  zenfmt {_escape(version)} is built for the targets below. Each uses the same
  conversion engine, reads the same {formats} formats, and writes Markdown.
</p>
<p>
  <a href="https://github.com/insanai/zenfmt/releases/tag/v{_escape(version)}">Release notes</a>
  · <a href="{release}/SHA256SUMS">SHA-256 checksums</a>
  · <a href="https://github.com/insanai/zenfmt/attestations">Provenance</a>
</p>

<div class="targets">
<section class="target target-featured">
  <h2>Browser · WebAssembly</h2>
  <p>
    The complete engine as a WebAssembly module plus a standards-based
    JavaScript adapter and a worker. Serve the files from any static origin or
    install the same dependency-free distribution from npm.
  </p>
  <p>
    Requires a browser with WebAssembly, modules, workers, and the file APIs.
    The module imports nothing from its host — no filesystem, no network — and
    a release build is checked against that claim.
  </p>
  <p class="target-meta">
    wasm32-freestanding · ReleaseSafe · module and ES adapter bundle
  </p>
  <p class="download-actions">
    {asset(f"zenfmt-{version}-wasm32-freestanding.tar.gz", "Download WASM bundle")}
    {asset(f"zenfmt-{version}-wasm32-freestanding.wasm", "Download module only")}
    <a href="https://www.npmjs.com/package/@insnai/zenfmt/v/{_escape(version)}">Open npm</a>
  </p>
</section>

<section class="target">
  <h2>macOS</h2>
  <p>
    Native command-line archives for Apple Silicon and Intel Macs. Requires
    macOS 12 or later.
  </p>
  <p class="download-actions">
    {asset(f"zenfmt-{version}-aarch64-macos.tar.gz", "Apple Silicon")}
    {asset(f"zenfmt-{version}-x86_64-macos.tar.gz", "Intel")}
    <a href="https://github.com/insanai/zenfmt/tree/main/packaging/homebrew">Install with Homebrew</a>
  </p>
</section>

<section class="target">
  <h2>Linux</h2>
  <p>Choose architecture and C library explicitly. glibc builds require 2.17 or later.</p>
  <p class="download-actions">
    {asset(f"zenfmt-{version}-x86_64-linux-gnu.tar.gz", "x86-64 · glibc")}
    {asset(f"zenfmt-{version}-aarch64-linux-gnu.tar.gz", "ARM64 · glibc")}
    {asset(f"zenfmt-{version}-x86_64-linux-musl.tar.gz", "x86-64 · musl")}
    {asset(f"zenfmt-{version}-aarch64-linux-musl.tar.gz", "ARM64 · musl")}
  </p>
</section>

<section class="target">
  <h2>Windows</h2>
  <p>Portable 64-bit command-line archive. No installer and no administrator access.</p>
  <p class="download-actions">
    {asset(f"zenfmt-{version}-x86_64-windows.zip", "Windows x86-64")}
  </p>
</section>

<section class="target">
  <h2>Python</h2>
  <p><code>uv add zenfmt</code></p>
  <p>
    CPython 3.10 through 3.14. The wheel carries the same engine as the
    command-line tool, so a conversion produces the same bytes either way.
  </p>
  <p class="download-actions">
    <a class="download-button" href="https://pypi.org/project/zenfmt/{_escape(version)}/">Open PyPI</a>
    <a href="https://pypi.org/project/zenfmt/{_escape(version)}/#files">Browse wheels and source distribution</a>
  </p>
</section>

<section class="target">
  <h2>Source</h2>
  <p>
    The tagged repository archive. Building needs Zig 0.16 and, for the
    documents, Typst 0.15.1.
  </p>
  <p class="download-actions">
    <a class="download-button" href="https://github.com/insanai/zenfmt/archive/refs/tags/v{_escape(version)}.tar.gz">Download source</a>
  </p>
</section>
</div>

<p>
  Every filename identifies its target. Verify the downloaded bytes against
  <a href="{release}/SHA256SUMS">the release checksum manifest</a> before use
  in a controlled build or deployment.
</p>
"""
    return Page(
        route="download/",
        title=f"Download zenfmt {version}",
        description=(
            "Download zenfmt as a browser WebAssembly module, a native "
            "command-line tool, an npm or Python package, or source."
        ),
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
    )


def _native_result_tables(native: dict) -> tuple[str, str]:
    tools = (
        ("zenfmt", "zenfmt"),
        ("docling", "Docling parser only"),
        ("anydoc", "AnyDoc"),
        ("pandoc", "Pandoc"),
    )
    native_rows = []
    comparison_rows = []
    for tool, label in tools:
        stats = _native_comparison(native, tool)
        native_rows.append(
            f'<tr><th scope="row">{_escape(label)}</th><td>{stats["converted"]}</td>'
            f"<td>{stats['total']}</td></tr>"
        )
        if tool != "zenfmt":
            comparison_rows.append(
                f'<tr><th scope="row">{_escape(label)} / zenfmt</th>'
                f"<td>{stats['shared_files']}</td>"
                f"<td>{_escape(_ratio(stats['wall_ratio']))}</td>"
                f"<td>{_escape(_ratio(stats['cpu_ratio']))}</td>"
                f"<td>{_escape(_ratio(stats['rss_ratio']))}</td></tr>"
            )
    return "".join(native_rows), "".join(comparison_rows)


def _server_result_rows(server: dict) -> tuple[str, str]:
    server_rows = "".join(
        f'<tr><th scope="row">{_escape(row["name"])}</th>'
        f"<td>{row['zenfmt']['wall_ms']:.2f}</td>"
        f"<td>{row['tika']['wall_ms']:.2f}</td>"
        f"<td>{row['zenfmt']['p95_ms']:.2f}</td>"
        f"<td>{row['tika']['p95_ms']:.2f}</td></tr>"
        for row in server.get("files", [])
    )
    throughput_rows = "".join(
        f'<tr><th scope="row">{row["concurrency"]}</th>'
        f"<td>{row['zenfmt_docs_per_s']:.1f}</td>"
        f"<td>{row['tika_docs_per_s']:.1f}</td></tr>"
        for row in server.get("throughput", [])
    )
    return server_rows, throughput_rows


def _lens_identity(data: dict, current_version: str, label: str) -> str:
    version = data.get("version", "unknown")
    revision = data.get("git_revision", "unknown")
    state = "Current release" if version == current_version else "Earlier reference"
    return (
        f"{state} {label}: zenfmt {_escape(version)} at "
        f"<code>{_escape(revision)}</code>. These values describe one modest "
        "reference machine."
    )


def _native_recorded_details(native: dict, current_version: str) -> str:
    if not native:
        return ""
    native_rows, comparison_rows = _native_result_tables(native)
    return f"""
<div class="recorded-lens">
<h2>Native CLI benchmark</h2>
<p class="notice">{_lens_identity(native, current_version, "native lens")}</p>
{_native_metric_grid(native, "AnyDoc")}
<p>Docling uses parser-only backends. OCR, VLM, ASR, layout models, table
models, enrichment, and accelerators are disabled. Unsupported files remain
visible rather than switching to an AI pipeline.</p>
<table><thead><tr><th>Tool</th><th>Converted</th><th>Corpus</th></tr></thead>
<tbody>{native_rows}</tbody></table>
<p>Each ratio divides the comparison tool by zenfmt over shared successful
files. Speed is elapsed wall time, CPU is user plus system processor time,
and peak memory is resident set size. Above 1.0 means the comparison used
more of that measure in this run. These ratios are context, not quality
scores.</p>
<table><thead><tr><th>Comparison tool / zenfmt</th><th>Shared files</th>
<th>Speed</th><th>CPU use</th><th>Peak memory</th></tr></thead>
<tbody>{comparison_rows}</tbody></table>
</div>
"""


def _server_recorded_details(server: dict, current_version: str) -> str:
    if not server:
        return ""
    server_rows, throughput_rows = _server_result_rows(server)
    startup = server.get("startup", {})
    rss = server.get("peak_rss_mb", {})
    return f"""
<div class="recorded-lens">
<h2>Long-running server benchmark</h2>
<p class="notice">{_lens_identity(server, current_version, "server lens")}</p>
{_server_metric_grid(server)}
<div class="metric-grid">
<div class="metric"><span>Startup</span><strong>{_escape(_paired_seconds(startup))}</strong><small>zenfmt / Tika Server</small></div>
<div class="metric"><span>Peak RSS</span><strong>{_escape(rss.get("zenfmt", "pending"))} / {_escape(rss.get("tika", "pending"))} MiB</strong><small>parent and direct parser children</small></div>
<div class="metric"><span>Corpus</span><strong>{len(server.get("files", []))} files</strong><small>the same verified manifest</small></div>
</div>
<table><thead><tr><th>File</th><th>zenfmt median ms</th><th>Tika median ms</th><th>zenfmt p95 ms</th><th>Tika p95 ms</th></tr></thead>
<tbody>{server_rows}</tbody></table>
<h3>Server throughput</h3>
<table><thead><tr><th>Concurrent clients</th><th>zenfmt documents/s</th><th>Tika documents/s</th></tr></thead>
<tbody>{throughput_rows}</tbody></table>
</div>
"""


def _recorded_benchmark_details(baselines: dict, current_version: str) -> str:
    native = baselines.get("native") or {}
    server = baselines.get("server") or {}
    if not native and not server:
        return ""
    return f"""
<section class="reference-baseline">
<h2>Recorded benchmark lenses</h2>
<p>Each lens retains its own version and revision. Values from different
releases are shown for context but are not combined into one result.</p>
{_native_recorded_details(native, current_version)}
{_server_recorded_details(server, current_version)}
</section>
"""


def _browser_benchmark_details(benchmark: dict) -> str:
    aggregates = benchmark.get("aggregates", {})
    browser = aggregates["browser"]
    quality = aggregates["quality"]
    competitor_rows = "".join(
        f"<li><strong>{_escape(row['tool'])}:</strong> "
        f"{_escape(row['state'].replace('_', ' '))} — {_escape(row['reason'])}</li>"
        for row in browser["competitors"]
    )
    cold = browser["cold"]
    artifact = browser["artifact"]
    provenance = "".join(
        f'<tr><th scope="row">{_escape(name)}</th>'
        f"<td><code>{_escape(source['sha256'])}</code></td></tr>"
        for name, source in benchmark["sources"].items()
    )
    return f"""
<h2>Browser and WebAssembly benchmark</h2>
<div class="metric-grid">
  <div class="metric"><span>WASM raw</span><strong>{_escape(_size(artifact["raw_bytes"]))}</strong><small>{_escape(artifact["gzip_bytes"])} bytes gzip</small></div>
  <div class="metric"><span>Cold ready</span><strong>{cold["first_ready_ms"]:.1f} ms</strong><small>fetch + compile + instantiate</small></div>
  <div class="metric"><span>Parity</span><strong>{quality["passed"]}/{quality["total"]}</strong><small>browser artifacts equal native</small></div>
</div>
<p>zenfmt converted {browser["coverage"][0]["converted"]} of {browser["coverage"][0]["total"]} files through the released WASM adapter. Warm rows use three warm-ups and fifteen measured samples per file; raw samples, p95 and median absolute deviation are in <code>wasm.json</code>.</p>
<ul>{competitor_rows}</ul>
<h2>Output preservation gate</h2>
<p>{_escape(quality["rule"])}. {quality["passed"]} of {quality["total"]} browser files passed before their timing was admitted.</p>
<h2>Provenance</h2>
<table><thead><tr><th>Input</th><th>SHA-256</th></tr></thead><tbody>{provenance}</tbody></table>
"""


def _benchmark_state(benchmark: dict | None) -> tuple[str, str]:
    if benchmark:
        notice = f"""
<p class="notice">Recorded for zenfmt {benchmark["zenfmt_version"]} at
<code>{_escape(benchmark["git_revision"])}</code>. Tool order remains zenfmt,
Docling parser only, AnyDoc, Pandoc, and the zenfmt wheel.</p>
"""
        return notice, _browser_benchmark_details(benchmark)
    notice = (
        '<p class="notice">The full benchmark is incomplete for this release.</p>'
        "<p>"
        "  Completed lenses are shown below with their own identities. "
        "  Older lenses remain reference values and are not presented as "
        "  measurements of the current release."
        "</p>"
    )
    return notice, ""


def _benchmark_method() -> str:
    return """
<h2>What is measured, and separately</h2>
<p>
  Three questions are kept apart because they have different answers.
  <em>Coverage</em> is which files each tool claims and actually converts.
  <em>Performance</em> is cold startup and warm conversion latency, CPU time,
  and peak memory. <em>Output preservation</em> is checked per format against
  a tool-neutral fixture oracle, and is never collapsed into a single quality
  score.
</p>

<h2>Correctness before timing</h2>
<p>
  The native and browser lenses admit timing only after their output checks
  pass. Their head-to-head comparisons use only shared successful files. The
  server lens has a smaller gate: a successful response with a nonempty body.
  It does not yet prove semantic quality or direct-to-server byte parity, so
  its timings should be read with that limitation.
</p>

<h2>Three lenses, never blended</h2>
<p>
  Native process startup, warm library calls, WebAssembly download and
  compile, warm WebAssembly execution, and a long-running HTTP service answer
  different questions. The native, browser, and server lenses are therefore
  reported separately, with cold and warm measurements clearly labelled. A
  file a tool does not support is shown as unsupported, never as infinitely
  slow.
</p>

<h2>Reproducing it</h2>
<p>
  The corpus is not redistributed here: it is assembled from third-party
  documents whose licences differ, and a conversion of one is a derivative
  work. What is published is each file's identity, format, size, SHA-256, and
  source, which is what a reader needs to fetch the same bytes.
  <code>benchmarks/fetch_corpus.sh</code> verifies every digest and refuses to
  proceed on a mismatch.
</p>
"""


def benchmark_page(
    benchmark: dict | None, baselines: dict, current_version: str
) -> Page:
    """The benchmark dashboard.

    A complete aggregate gets the release heading. Independently recorded
    lenses retain their own version and revision so partial runs stay useful
    without presenting an older measurement as current.
    """
    notice, browser_details = _benchmark_state(benchmark)
    body = f"""
<h1>The conversion benchmark</h1>
{notice}
{
        _recorded_benchmark_details(
            baselines,
            current_version,
        )
    }
{browser_details}
{_benchmark_method()}
"""
    return Page(
        route="benchmark/",
        title="Benchmark — zenfmt",
        description=(
            "How zenfmt is measured against other converters: coverage, "
            "performance, server operation, and output preservation, with "
            "the method and the raw data."
        ),
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
    )
