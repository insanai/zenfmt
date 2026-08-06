#!/bin/sh
# Downloads the benchmark corpus: real-world documents from public sample
# repositories (filesamples.com, Apache POI and LibreOffice test data,
# Project Gutenberg, W3C). The corpus is not committed; run this script once
# before `zig build benchmark`. Every file is fetched only when absent.
set -eu

corpus="$(dirname "$0")/corpus"
mkdir -p "$corpus"

fetch() {
    name="$1"
    url="$2"
    out="$corpus/$name"
    if [ -s "$out" ]; then
        echo "have    $name"
        return 0
    fi
    if curl -fsSL --retry 2 --max-time 120 -A "Mozilla/5.0 (zenfmt-bench)" \
        -o "$out.part" "$url"; then
        mv "$out.part" "$out"
        echo "fetched $name"
    else
        rm -f "$out.part"
        echo "MISSING $name ($url)" >&2
    fi
}

# --- OOXML / OpenDocument -------------------------------------------------
fetch report.docx "https://filesamples.com/samples/document/docx/sample3.docx"
fetch sheet.xlsx "https://filesamples.com/samples/document/xlsx/sample3.xlsx"
fetch slides.pptx "https://raw.githubusercontent.com/apache/poi/trunk/test-data/slideshow/2411-Performance_Up.pptx"
fetch letter.odt "https://filesamples.com/samples/document/odt/sample3.odt"
fetch sheet.ods "https://filesamples.com/samples/document/ods/sample2.ods"
# A text-rich ODP: derived from the real Apache deck via LibreOffice when
# installed, else LibreOffice's own (table-only) test file.
soffice="/Applications/LibreOffice.app/Contents/MacOS/soffice"
if [ ! -s "$corpus/slides.odp" ] && [ -x "$soffice" ] && [ -s "$corpus/slides.pptx" ]; then
    cp "$corpus/slides.pptx" "$corpus/deck-src.pptx"
    "$soffice" --headless --convert-to odp "$corpus/deck-src.pptx" \
        --outdir "$corpus" >/dev/null 2>&1 || true
    [ -s "$corpus/deck-src.odp" ] && mv "$corpus/deck-src.odp" "$corpus/slides.odp"
    rm -f "$corpus/deck-src.pptx"
    [ -s "$corpus/slides.odp" ] && echo "derived slides.odp"
fi
fetch slides.odp "https://raw.githubusercontent.com/LibreOffice/core/master/sd/qa/unit/data/odp/Table_with_Cell_Fill.odp"

# --- legacy binary --------------------------------------------------------
fetch memo.doc "https://filesamples.com/samples/document/doc/sample2.doc"
fetch table.xls "https://filesamples.com/samples/document/xls/sample3.xls"
fetch deck.ppt "https://raw.githubusercontent.com/apache/poi/trunk/test-data/slideshow/23884_defense_FINAL_OOimport_edit.ppt"
fetch grid.xlsb "https://raw.githubusercontent.com/apache/poi/trunk/test-data/spreadsheet/Simple.xlsb"

# --- portable / text ------------------------------------------------------
fetch book.epub "https://www.gutenberg.org/ebooks/1342.epub.noimages"
fetch spec.pdf "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"
fetch article.pdf "https://pdfobject.com/pdf/sample.pdf"
fetch notes.rtf "https://filesamples.com/samples/document/rtf/sample3.rtf"
fetch data.csv "https://people.sc.fsu.edu/~jburkardt/data/csv/hw_25000.csv"
fetch page.html "https://www.gutenberg.org/cache/epub/1342/pg1342-images.html"

echo
echo "corpus contents:"
ls -la "$corpus" | tail -n +2
