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
  <p class="eyebrow">Your document. Clean Markdown.</p>
  <h1>Drop it. zenfmt it.</h1>
  <p class="lede">Private browser conversion powered by Zig and WebAssembly.</p>
  <p class="promise">No upload · no account · no waiting</p>
</section>

<section class="workspace" aria-label="Convert a document">
  <div class="pane pane-input">
    <h2 class="pane-title">1 · Source document</h2>
    <label class="drop" for="source" data-drop>
      <input type="file" id="source" name="source" data-source
             accept="{_escape(accept)}">
      <span class="drop-headline">Drop a file here</span>
      <span class="drop-detail">or choose a file · try an example</span>
    </label>
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
    headline = benchmark.get("aggregates", {}).get("headline", {})
    return (
        '<section class="benchmark-summary">'
        "<h2>The conversion benchmark</h2>"
        f"<p>{_escape(headline.get('summary', 'Recorded results are available.'))}</p>"
        '<p><a href="{LINK:benchmark/}">Method and raw data</a></p>'
        "</section>"
    )


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
    body = f"""
<h1>Download zenfmt {_escape(version)}</h1>
<p class="lede">
  One engine, four ways to run it. All of them read the same {formats} formats
  and write the same Markdown.
</p>

<section class="target">
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
</section>

<section class="target">
  <h2>Command line</h2>
  <p>
    Native binaries for macOS (Apple Silicon and Intel), Linux (x86-64 and
    ARM64, glibc 2.17 or later and musl), and Windows (64-bit, a portable zip
    with no installer). Each archive names its exact target, and each is
    published with a SHA-256 checksum beside it rather than buried in the
    release notes.
  </p>
</section>

<section class="target">
  <h2>Python</h2>
  <p><code>uv add zenfmt</code></p>
  <p>
    CPython 3.10 through 3.14. The wheel carries the same engine as the
    command-line tool, so a conversion produces the same bytes either way.
  </p>
</section>

<section class="target">
  <h2>Source</h2>
  <p>
    The tagged repository archive. Building needs Zig 0.16 and, for the
    documents, Typst 0.15.1.
  </p>
</section>

<p>
  Release assets, checksums, and provenance are published with each tag on
  <a href="https://github.com/insanai/zenfmt/releases">the releases page</a>.
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
        state = (
            "<p>Recorded for this release.</p>"
            f"<pre>{_escape(json.dumps(aggregates, indent=2, sort_keys=True))}</pre>"
        )
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
