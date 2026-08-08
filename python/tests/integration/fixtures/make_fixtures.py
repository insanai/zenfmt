"""Regenerates the pure-Python integration fixtures (ZDS 0014).

One tiny checked-in document per reader id. The text-family and
container-format fixtures are generated here deterministically; the
legacy CFB fixtures (`tiny.doc`, `tiny.xls`, `tiny.ppt`) were produced
once with LibreOffice from the matching OpenDocument sources below and
are committed as binaries. `xlsb` has no generator (no open tool writes
it); its matrix case falls back to the benchmark corpus.

Run from the repository root::

    uv run python python/tests/integration/fixtures/make_fixtures.py
"""

from __future__ import annotations

import io
import zipfile
from pathlib import Path

HERE = Path(__file__).parent

TEXT_FIXTURES = {
    "note.txt": "Fixture paragraph.\n\nSecond paragraph.\n",
    "note.md": "# Fixture\n\nbody with *emphasis*\n",
    "table.csv": "name,value\nalpha,1\nbeta,2\n",
    "page.html": "<html><body><h1>Fixture</h1><p>body</p></body></html>\n",
    "doc.adoc": "= Fixture\n\nbody paragraph\n",
    "doc.rst": "Fixture\n=======\n\nbody paragraph\n",
    "doc.rtf": r"{\rtf1\ansi Fixture paragraph.}",
}


def opc(entries: dict[str, str]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, content in entries.items():
            archive.writestr(name, content)
    return buf.getvalue()


def odf(mimetype: str, content: str) -> bytes:
    manifest = (
        '<?xml version="1.0"?><manifest:manifest '
        'xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" '
        'manifest:version="1.2"><manifest:file-entry '
        f'manifest:full-path="/" manifest:media-type="{mimetype}"/>'
        '<manifest:file-entry manifest:full-path="content.xml" '
        'manifest:media-type="text/xml"/></manifest:manifest>'
    )
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as archive:
        archive.writestr("mimetype", mimetype)
        archive.writestr("META-INF/manifest.xml", manifest)
        archive.writestr("content.xml", content)
    return buf.getvalue()


def make_docx() -> bytes:
    return opc(
        {
            "[Content_Types].xml": (
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxml'
                'formats.org/package/2006/content-types"><Default Extension='
                '"rels" ContentType="application/vnd.openxmlformats-package'
                '.relationships+xml"/><Default Extension="xml" ContentType='
                '"application/vnd.openxmlformats-officedocument.wordprocessi'
                'ngml.document.main+xml"/></Types>'
            ),
            "_rels/.rels": (
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.'
                'openxmlformats.org/package/2006/relationships"><Relationship'
                ' Id="rId1" Type="http://schemas.openxmlformats.org/officeDoc'
                'ument/2006/relationships/officeDocument" Target="word/docume'
                'nt.xml"/></Relationships>'
            ),
            "word/document.xml": (
                '<?xml version="1.0"?><w:document xmlns:w="http://schemas.op'
                'enxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w'
                ":r><w:t>Fixture paragraph.</w:t></w:r></w:p></w:body></w:doc"
                "ument>"
            ),
        }
    )


def make_xlsx() -> bytes:
    return opc(
        {
            "[Content_Types].xml": (
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlfo'
                'rmats.org/package/2006/content-types"><Default Extension="re'
                'ls" ContentType="application/vnd.openxmlformats-package.rela'
                'tionships+xml"/><Default Extension="xml" ContentType="applic'
                'ation/xml"/><Override PartName="/xl/workbook.xml" ContentTyp'
                'e="application/vnd.openxmlformats-officedocument.spreadsheet'
                'ml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet'
                '1.xml" ContentType="application/vnd.openxmlformats-officedoc'
                'ument.spreadsheetml.worksheet+xml"/></Types>'
            ),
            "_rels/.rels": (
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.o'
                'penxmlformats.org/package/2006/relationships"><Relationship '
                'Id="rId1" Type="http://schemas.openxmlformats.org/officeDocu'
                'ment/2006/relationships/officeDocument" Target="xl/workbook.'
                'xml"/></Relationships>'
            ),
            "xl/workbook.xml": (
                '<?xml version="1.0"?><workbook xmlns="http://schemas.openxm'
                'lformats.org/spreadsheetml/2006/main" xmlns:r="http://schema'
                's.openxmlformats.org/officeDocument/2006/relationships"><she'
                'ets><sheet name="S1" sheetId="1" r:id="rId1"/></sheets></wor'
                "kbook>"
            ),
            "xl/_rels/workbook.xml.rels": (
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.o'
                'penxmlformats.org/package/2006/relationships"><Relationship '
                'Id="rId1" Type="http://schemas.openxmlformats.org/officeDocu'
                'ment/2006/relationships/worksheet" Target="worksheets/sheet1'
                '.xml"/></Relationships>'
            ),
            "xl/worksheets/sheet1.xml": (
                '<?xml version="1.0"?><worksheet xmlns="http://schemas.openx'
                'mlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"'
                '><c r="A1" t="inlineStr"><is><t>cell</t></is></c></row></she'
                "etData></worksheet>"
            ),
        }
    )


def make_pptx() -> bytes:
    return opc(
        {
            "[Content_Types].xml": (
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlfo'
                'rmats.org/package/2006/content-types"><Default Extension="re'
                'ls" ContentType="application/vnd.openxmlformats-package.rela'
                'tionships+xml"/><Override PartName="/ppt/presentation.xml" C'
                'ontentType="application/vnd.openxmlformats-officedocument.pr'
                'esentationml.presentation.main+xml"/><Override PartName="/pp'
                't/slides/slide1.xml" ContentType="application/vnd.openxmlfor'
                'mats-officedocument.presentationml.slide+xml"/></Types>'
            ),
            "_rels/.rels": (
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.o'
                'penxmlformats.org/package/2006/relationships"><Relationship '
                'Id="rId1" Type="http://schemas.openxmlformats.org/officeDocu'
                'ment/2006/relationships/officeDocument" Target="ppt/presenta'
                'tion.xml"/></Relationships>'
            ),
            "ppt/presentation.xml": (
                '<?xml version="1.0"?><p:presentation xmlns:p="http://schema'
                's.openxmlformats.org/presentationml/2006/main" xmlns:r="http'
                "://schemas.openxmlformats.org/officeDocument/2006/relationsh"
                'ips"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst'
                "></p:presentation>"
            ),
            "ppt/_rels/presentation.xml.rels": (
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.o'
                'penxmlformats.org/package/2006/relationships"><Relationship '
                'Id="rId1" Type="http://schemas.openxmlformats.org/officeDocu'
                'ment/2006/relationships/slide" Target="slides/slide1.xml"/><'
                "/Relationships>"
            ),
            "ppt/slides/slide1.xml": (
                '<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxml'
                'formats.org/presentationml/2006/main" xmlns:a="http://schema'
                's.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree>'
                '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr'
                '/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" '
                'name="Title"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:tx'
                "Body><a:bodyPr/><a:p><a:r><a:t>Fixture slide.</a:t></a:r></a"
                ":p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
            ),
        }
    )


def make_epub() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip")
        archive.writestr(
            "META-INF/container.xml",
            '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:'
            'names:tc:opendocument:xmlns:container"><rootfiles><rootfile ful'
            'l-path="content.opf" media-type="application/oebps-package+xml"'
            "/></rootfiles></container>",
        )
        archive.writestr(
            "content.opf",
            '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/o'
            'pf" version="3.0" unique-identifier="id"><metadata xmlns:dc="ht'
            'tp://purl.org/dc/elements/1.1/"><dc:identifier id="id">fixture<'
            "/dc:identifier><dc:title>Fixture</dc:title><dc:language>en</dc:"
            'language></metadata><manifest><item id="c" href="ch.xhtml" medi'
            'a-type="application/xhtml+xml"/></manifest><spine><itemref idre'
            'f="c"/></spine></package>',
        )
        archive.writestr(
            "ch.xhtml",
            '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"'
            "><head><title>F</title></head><body><p>Fixture paragraph.</p></"
            "body></html>",
        )
    return buf.getvalue()


def make_pdf() -> bytes:
    objects = [
        b"<</Type/Catalog/Pages 2 0 R>>",
        b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
        b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R"
        b"/Resources<</Font<</F1 5 0 R>>>>>>",
        None,
        b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>",
    ]
    stream = b"BT /F1 12 Tf 72 720 Td (Fixture text.) Tj ET"
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets = []
    for index, body in enumerate(objects, 1):
        offsets.append(out.tell())
        if body is None:
            out.write(b"4 0 obj\n<</Length %d>>\nstream\n" % len(stream))
            out.write(stream)
            out.write(b"\nendstream\nendobj\n")
        else:
            out.write(b"%d 0 obj\n" % index + body + b"\nendobj\n")
    xref = out.tell()
    out.write(b"xref\n0 6\n0000000000 65535 f \n")
    for offset in offsets:
        out.write(b"%010d 00000 n \n" % offset)
    out.write(b"trailer\n<</Size 6/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n" % xref)
    return out.getvalue()


ODT_CONTENT = (
    '<?xml version="1.0"?><office:document-content xmlns:office="urn:oasis:'
    'names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc'
    ':opendocument:xmlns:text:1.0"><office:body><office:text><text:p>Fixtur'
    "e paragraph.</text:p></office:text></office:body></office:document-con"
    "tent>"
)
ODS_CONTENT = (
    '<?xml version="1.0"?><office:document-content xmlns:office="urn:oasis:'
    'names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:t'
    'c:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendoc'
    'ument:xmlns:text:1.0"><office:body><office:spreadsheet><table:table ta'
    'ble:name="S1"><table:table-row><table:table-cell><text:p>cell</text:p>'
    "</table:table-cell></table:table-row></table:table></office:spreadshee"
    "t></office:body></office:document-content>"
)
ODP_CONTENT = (
    '<?xml version="1.0"?><office:document-content xmlns:office="urn:oasis:'
    'names:tc:opendocument:xmlns:office:1.0" xmlns:draw="urn:oasis:names:tc'
    ':opendocument:xmlns:drawing:1.0" xmlns:text="urn:oasis:names:tc:opendo'
    'cument:xmlns:text:1.0"><office:body><office:presentation><draw:page dr'
    'aw:name="page1"><draw:frame><draw:text-box><text:p>Fixture slide.</tex'
    "t:p></draw:text-box></draw:frame></draw:page></office:presentation></o"
    "ffice:body></office:document-content>"
)


def main() -> None:
    for name, content in TEXT_FIXTURES.items():
        (HERE / name).write_text(content, encoding="utf-8")
    (HERE / "min.docx").write_bytes(make_docx())
    (HERE / "min.xlsx").write_bytes(make_xlsx())
    (HERE / "min.pptx").write_bytes(make_pptx())
    (HERE / "min.epub").write_bytes(make_epub())
    (HERE / "min.pdf").write_bytes(make_pdf())
    (HERE / "min.odt").write_bytes(
        odf("application/vnd.oasis.opendocument.text", ODT_CONTENT)
    )
    (HERE / "min.ods").write_bytes(
        odf("application/vnd.oasis.opendocument.spreadsheet", ODS_CONTENT)
    )
    (HERE / "min.odp").write_bytes(
        odf("application/vnd.oasis.opendocument.presentation", ODP_CONTENT)
    )
    print(f"fixtures written to {HERE}")


if __name__ == "__main__":
    main()
