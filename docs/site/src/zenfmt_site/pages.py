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
from pathlib import Path

from .shell import Page


def _escape(value: str) -> str:
    return html.escape(str(value), quote=True)


def homepage(capabilities: dict, benchmark: dict | None) -> Page:
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

<section class="help">
  <h2>Need help?</h2>
  <ul class="help-links">
    <li><a href="{{LINK:book/tour/}}">A first conversion</a></li>
    <li><a href="{{LINK:book/limits/}}">Supported formats and limits</a></li>
    <li><a href="{{LINK:book/}}">Read the book</a></li>
    <li><a href="{{LINK:zds/}}">Why this works (design records)</a></li>
  </ul>
</section>

{_benchmark_summary(benchmark)}

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


def _benchmark_summary(benchmark: dict | None) -> str:
    """The homepage may show only figures that came from a result file for
    this same release. With none, it says so rather than showing a number
    whose provenance it cannot state."""
    if not benchmark:
        return (
            '<section class="benchmark-summary">'
            "<h2>The conversion benchmark</h2>"
            "<p>Benchmark pending for this release.</p>"
            '<p><a href="{LINK:benchmark/}">Method and raw data</a></p>'
            "</section>"
        )
    aggregates = benchmark.get("aggregates", {})
    headline = aggregates.get("headline", {})
    native = aggregates.get("native", {})
    browser = aggregates.get("browser", {})
    coverage = native.get("coverage", [])
    ours = next((row for row in coverage if row.get("tool") == "zenfmt"), {})
    anydoc = native.get("comparisons", {}).get("anydoc", {})
    wasm = browser.get("artifact", {})
    return (
        '<section class="benchmark-summary">'
        '<p class="eyebrow">A small reference benchmark</p>'
        "<h2>The conversion benchmark</h2>"
        f"<p>{_escape(headline.get('summary', 'Recorded results are available.'))}</p>"
        '<div class="metric-grid">'
        '<div class="metric"><span>Format corpus</span>'
        f"<strong>{_escape(ours.get('converted', '—'))}/{_escape(ours.get('total', '—'))}</strong>"
        "<small>zenfmt successful</small></div>"
        '<div class="metric"><span>Native vs AnyDoc</span>'
        f"<strong>{_escape(_ratio(anydoc.get('wall_ratio')))}</strong>"
        f"<small>{_escape(anydoc.get('shared_files', 0))} shared files</small></div>"
        '<div class="metric"><span>Browser module</span>'
        f"<strong>{_escape(_size(wasm.get('raw_bytes')))}</strong>"
        "<small>ReleaseSafe · zero imports</small></div>"
        "</div>"
        '<p><a href="{LINK:benchmark/}">Method and raw data</a></p>'
        "</section>"
    )


def _ratio(value: float | None) -> str:
    return "—" if value is None else f"{value:.1f}×"


def _size(value: int | None) -> str:
    return "—" if value is None else f"{value / (1024 * 1024):.2f} MiB"


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
        scripts=[],
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
    JavaScript adapter and a worker. Serve the files from any static origin;
    there is no package manager assumption and no build step.
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
            "command-line tool, a Python package, or source."
        ),
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
    )


def benchmark_page(benchmark: dict | None) -> Page:
    """The benchmark dashboard.

    It shows figures only from a result file belonging to this release. With
    none, it says the benchmark is pending rather than showing older numbers
    under a newer heading — a stale figure reads as a measurement of the thing
    being released, which is worse than no figure at all.
    """
    if benchmark:
        aggregates = benchmark.get("aggregates", {})
        native = aggregates["native"]
        browser = aggregates["browser"]
        quality = aggregates["quality"]
        coverage_rows = "".join(
            "<tr>"
            f'<th scope="row">{_escape(row["tool"])}</th>'
            f"<td>{_escape(row['converted'])}</td><td>{_escape(row['total'])}</td>"
            "</tr>"
            for row in native["coverage"]
        )
        comparison_rows = "".join(
            "<tr>"
            f'<th scope="row">zenfmt vs {_escape(tool)}</th>'
            f"<td>{_escape(values['shared_files'])}</td>"
            f"<td>{_escape(_ratio(values['wall_ratio']))}</td>"
            "</tr>"
            for tool, values in native["comparisons"].items()
        )
        competitor_rows = "".join(
            f"<li><strong>{_escape(row['tool'])}:</strong> "
            f"{_escape(row['state'].replace('_', ' '))} — {_escape(row['reason'])}</li>"
            for row in browser["competitors"]
        )
        cold = browser["cold"]
        artifact = browser["artifact"]
        state = f"""
<p class="notice">Recorded for zenfmt {benchmark["zenfmt_version"]} at
<code>{_escape(benchmark["git_revision"])}</code>. Tool order remains zenfmt,
AnyDoc, Pandoc.</p>
<div class="metric-grid">
  <div class="metric"><span>WASM raw</span><strong>{_escape(_size(artifact["raw_bytes"]))}</strong><small>{_escape(artifact["gzip_bytes"])} bytes gzip</small></div>
  <div class="metric"><span>Cold ready</span><strong>{cold["first_ready_ms"]:.1f} ms</strong><small>fetch + compile + instantiate</small></div>
  <div class="metric"><span>Parity</span><strong>{quality["passed"]}/{quality["total"]}</strong><small>browser artifacts equal native</small></div>
</div>
<h2>Native coverage</h2>
<table><thead><tr><th>Tool</th><th>Converted</th><th>Corpus</th></tr></thead><tbody>{coverage_rows}</tbody></table>
<h2>Native shared-file latency</h2>
<p>Ratio is the other tool's median wall time divided by zenfmt's. A value above 1.0× means the other tool took longer on the shared files in this run.</p>
<table><thead><tr><th>Comparison</th><th>Shared files</th><th>Wall ratio</th></tr></thead><tbody>{comparison_rows}</tbody></table>
<h2>Browser lens</h2>
<p>zenfmt converted {browser["coverage"][0]["converted"]} of {browser["coverage"][0]["total"]} files through the released WASM adapter. Warm rows use three warm-ups and fifteen measured samples per file; raw samples, p95 and median absolute deviation are in <code>wasm.json</code>.</p>
<ul>{competitor_rows}</ul>
<h2>Output preservation gate</h2>
<p>{_escape(quality["rule"])}. {quality["passed"]} of {quality["total"]} browser files passed before their timing was admitted.</p>
<h2>Provenance</h2>
<table><thead><tr><th>Input</th><th>SHA-256</th></tr></thead><tbody>{"".join(f'<tr><th scope="row">{_escape(name)}</th><td><code>{_escape(source["sha256"])}</code></td></tr>' for name, source in benchmark["sources"].items())}</tbody></table>
"""
    else:
        state = (
            '<p class="notice">Benchmark pending for this release.</p>'
            "<p>"
            "  No result file recorded against this version was found, so no "
            "  figures are shown. The alternative — displaying the previous "
            "  release's numbers under this one's heading — would read as a "
            "  measurement of something that was never measured."
            "</p>"
        )

    body = f"""
<h1>The conversion benchmark</h1>
{state}

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
  A tool is timed on a file only after its output for that file has passed the
  correctness gate. Timing a conversion that produced nothing useful would
  reward the wrong thing, and a head-to-head comparison uses only files both
  tools converted successfully.
</p>

<h2>Two lenses, never blended</h2>
<p>
  Native process startup, warm library calls, WebAssembly download and
  compile, and warm WebAssembly execution answer different questions, so the
  native and browser lenses are reported separately with cold and warm clearly
  labelled. A file a tool does not support is shown as unsupported, never as
  infinitely slow.
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
    return Page(
        route="benchmark/",
        title="Benchmark — zenfmt",
        description=(
            "How zenfmt is measured against other converters: coverage, "
            "performance, and output preservation, with the method and the "
            "raw data."
        ),
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
    )
