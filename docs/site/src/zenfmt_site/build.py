"""Assembling the deployable site (ZDS 0015, Static assembly).

The assembler reads a declared set of inputs and writes one output tree. It
copies no arbitrary repository file: every path it reads is named here, so a
stray file cannot end up published, and a missing input is an error rather
than a page that quietly renders without it.
"""

from __future__ import annotations

import hashlib
import html
import json
import re
import shutil
from dataclasses import dataclass
from pathlib import Path

from . import pages, routes
from .document import ContractError, parse
from .shell import Page, render

LINK = re.compile(r"\{LINK:([^}]*)\}")
ASSET = re.compile(r"\{ASSET:([^}]*)\}")
TAGS = re.compile(r"<[^>]+>")


@dataclass
class Inputs:
    root: Path
    zds_site: Path
    book_site: Path
    capabilities: Path
    content_map: Path
    site_assets: Path
    book_pdf: Path
    zds_pdfs: Path
    benchmark: Path


def inputs_for(root: Path) -> Inputs:
    return Inputs(
        root=root,
        zds_site=root / "docs/build/zds-site",
        book_site=root / "docs/build/book-site",
        capabilities=root / "zig-out/share/zenfmt/capabilities.json",
        content_map=root / "docs/site/content_map.json",
        site_assets=root / "site/assets",
        book_pdf=root / "docs/build/zenfmt-book.pdf",
        zds_pdfs=root / "docs/build",
        benchmark=root / "benchmarks/results/site.json",
    )


class Builder:
    def __init__(self, inputs: Inputs, out: Path, *, base: str, version: str):
        self.inputs = inputs
        self.out = out
        self.base = base
        self.version = version
        self.assets: dict[str, str] = {}
        self.written: list[str] = []
        self.search_records: list[dict[str, str]] = []

    # -- assets ---------------------------------------------------------

    def fingerprint(self, source: Path, target: str) -> str:
        """Copies an asset under a content-addressed name.

        A fingerprinted name is what lets these be cached indefinitely without
        a stale one surviving a release; HTML routes are never fingerprinted,
        because those are the addresses people share.
        """
        return self.fingerprint_data(source.read_bytes(), target)

    def fingerprint_data(self, data: bytes, target: str) -> str:
        """Emits generated asset bytes under a content-addressed name."""
        digest = hashlib.sha256(data).hexdigest()[:12]
        stem, _, suffix = target.rpartition(".")
        name = f"{stem}.{digest}.{suffix}"
        self._write_bytes(name, data)
        self.assets[target] = name
        return name

    def copy_plain(self, source: Path, target: str) -> None:
        self._write_bytes(target, source.read_bytes())

    def _write_bytes(self, target: str, data: bytes) -> None:
        if target in self.written:
            raise ContractError(f"two site inputs resolve to the same output: {target}")
        path = self.out / target
        self._guard(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.written.append(target)

    def write_text(self, target: str, text: str) -> None:
        self._write_bytes(target, text.encode("utf-8"))

    def _guard(self, path: Path) -> None:
        """Output paths are confined below the destination. A generator that
        can be talked into writing outside its output directory is a
        generator that can overwrite the source tree it was built from."""
        resolved = path.resolve()
        if not resolved.is_relative_to(self.out.resolve()):
            raise ContractError(f"refusing to write outside the output tree: {path}")

    # -- pages ----------------------------------------------------------

    def emit(self, page: Page) -> None:
        page.stylesheets = [self.assets.get(s, s) for s in page.stylesheets]
        page.scripts = [self.assets.get(s, s) for s in (page.scripts or [])]
        if page.wasm_url is None and "assets/wasm/zenfmt.wasm" in self.assets:
            page.wasm_url = self.assets["assets/wasm/zenfmt.wasm"]
        if page.adapter_url is None and "assets/js/zenfmt.js" in self.assets:
            page.adapter_url = self.assets["assets/js/zenfmt.js"]
        if page.worker_url is None and "assets/js/zenfmt.worker.js" in self.assets:
            page.worker_url = self.assets["assets/js/zenfmt.worker.js"]
        if page.search_url is None:
            page.search_url = "assets/search.json"
        body = self._resolve(page.body, page)
        page.body = body
        self.search_records.append(
            {
                "route": routes.relative("", page.route),
                "title": page.title,
                "description": page.description,
                "text": " ".join(html.unescape(TAGS.sub(" ", body)).split())[:12000],
            }
        )
        self.write_text(
            routes.output_path(page.route), render(page, version=self.version)
        )

    def finish_search(self) -> None:
        self.write_text(
            "assets/search.json",
            json.dumps(
                self.search_records,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ),
        )

    def _resolve(self, body: str, page: Page) -> str:
        def link(match: re.Match[str]) -> str:
            target = match.group(1)
            if page.absolute_base is not None:
                return routes.absolute(page.absolute_base, target)
            return routes.relative(page.route, target)

        def asset(match: re.Match[str]) -> str:
            target = match.group(1)
            name = self.assets.get(target, target)
            if page.absolute_base is not None:
                return routes.absolute(page.absolute_base, f"assets/{name}")
            return routes.relative(page.route, f"assets/{name}")

        return ASSET.sub(asset, LINK.sub(link, body))

    # -- Typst documents ------------------------------------------------

    def emit_typst(
        self,
        source: Path,
        route: str,
        page_id: str,
        *,
        expect_figures: int | None = None,
    ) -> Page:
        doc = parse(source.read_text(encoding="utf-8"), page_id=page_id)
        if expect_figures is not None:
            from .document import assert_figures

            assert_figures(doc, expect_figures, page_id)

        for figure in doc.figures:
            self._write_bytes(f"assets/fig/{figure.name}", figure.svg.encode("utf-8"))

        # Typst's own stylesheet is byte-identical across pages that need it,
        # so it is emitted once and shared rather than inlined into each.
        sheets = ["assets/css/site.css"]
        for index, sheet in enumerate(doc.stylesheets):
            digest = hashlib.sha256(sheet.encode("utf-8")).hexdigest()[:12]
            name = f"assets/css/typst.{digest}.css"
            if name not in self.written:
                self._write_bytes(name, sheet.encode("utf-8"))
            sheets.append(name)
            del index

        page = Page(
            route=route,
            title=doc.title or page_id,
            description=doc.description,
            body=doc.body,
            stylesheets=sheets,
            scripts=["assets/js/main.js"],
            toc=doc.headings,
        )
        self.emit(page)
        return page


def build(
    root: Path, out: Path, *, base: str, version: str, clean: bool = True
) -> Builder:
    inputs = inputs_for(root)
    if clean and out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    capabilities = pages.load_json(inputs.capabilities)
    content_map = pages.load_json(inputs.content_map)
    benchmark = _fresh_benchmark(inputs.benchmark, version)

    builder = Builder(inputs, out, base=base, version=version)

    # Jekyll would otherwise drop any path beginning with an underscore.
    builder.write_text(".nojekyll", "")

    for name in ("css/site.css", "js/main.js", "js/zenfmt.js"):
        source = inputs.site_assets / name
        if source.exists():
            builder.fingerprint(source, f"assets/{name}")
    worker = inputs.site_assets / "js/zenfmt.worker.js"
    if worker.exists():
        adapter = Path(builder.assets["assets/js/zenfmt.js"]).name
        worker_text = worker.read_text(encoding="utf-8").replace(
            "./zenfmt.js", f"./{adapter}"
        )
        builder.fingerprint_data(
            worker_text.encode("utf-8"), "assets/js/zenfmt.worker.js"
        )
    for extra in ("js/zenfmt.d.ts",):
        source = inputs.site_assets / extra
        if source.exists():
            builder.copy_plain(source, f"assets/{extra}")

    wasm = root / "zig-out/wasm/zenfmt.wasm"
    if wasm.exists():
        builder.fingerprint(wasm, "assets/wasm/zenfmt.wasm")
    builder.write_text(
        "assets/capabilities.json",
        json.dumps(capabilities, sort_keys=True, separators=(",", ":")),
    )

    # Book chapters.
    book_entries = []
    for chapter in content_map["book"]:
        source = inputs.book_site / chapter["id"] / "index.html"
        if not source.exists():
            raise ContractError(
                f"the book bundle produced no {chapter['id']!r} chapter. The "
                "content map and docs/book/site.typ must name the same set."
            )
        builder.emit_typst(source, chapter["route"], chapter["id"])
        book_entries.append(
            {
                "route": chapter["route"],
                "title": chapter["title"],
                "summary": chapter["summary"],
            }
        )

    builder.emit(
        pages.index_page(
            "book/",
            "The zenfmt book",
            "How the converter works, and what it will and will not do to a document.",
            book_entries,
        )
    )

    # Records keep their published .html addresses.
    record_entries = []
    records_dir = inputs.zds_site / "zds"
    for source in sorted(records_dir.glob("*.html")):
        route = f"zds/{source.name}"
        page = builder.emit_typst(source, route, source.stem)
        record_entries.append(
            {"route": route, "title": page.title, "summary": page.description}
        )
    builder.emit(
        pages.index_page(
            "zds/",
            "Zen Discussions",
            "Every design decision, with the alternatives that lost.",
            record_entries,
        )
    )

    # PDFs, at the addresses that are already published.
    pdf_dir = inputs.zds_site / "pdf"
    if pdf_dir.exists():
        for pdf in sorted(pdf_dir.glob("*.pdf")):
            builder.copy_plain(pdf, f"pdf/{pdf.name}")
    if inputs.book_pdf.exists():
        builder.copy_plain(inputs.book_pdf, "pdf/zenfmt-book.pdf")

    builder.emit(pages.homepage(capabilities, benchmark))
    builder.emit(pages.download_page(capabilities, version))
    builder.emit(pages.benchmark_page(benchmark))
    builder.emit(pages.security_page())
    builder.emit(pages.not_found_page(base))
    builder.finish_search()

    return builder


def _fresh_benchmark(path: Path, version: str) -> dict | None:
    """Benchmark data is used only when it belongs to this release.

    Stale numbers under a new heading are worse than no numbers: they read as
    a measurement of the thing being released. So a mismatch yields None and
    the dashboard says the benchmark is pending.
    """
    if not path.exists():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("zenfmt_version") != version:
        return None
    return data
