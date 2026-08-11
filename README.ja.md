# zenfmt

[English](README.md) · [简体中文](README.zh-CN.md) · 日本語 ·
[한국어](README.ko.md)

zenfmt は Zig で書かれたドキュメント変換ツールです。ある形式を読み、共通の中間表現を通して別の形式へ書き出します。

[Pandoc](https://pandoc.org/) は、汎用ドキュメント変換ツールの便利さを示しました。zenfmt はその考え方を小さな Zig engine で探る試みです。Pandoc ほど幅広くはありませんが、compact な engine、明示的な conversion report、そして下記の形式に集中しています。

**現在の release は 0.3.2 です。** Architecture は [ZDS 0002](docs/zds/records/0002-zenfmt-architecture.typ)、IR v2、facets、writer lowering は [ZDS 0013](docs/zds/records/0013-layered-document-ir.typ) に記録されています。ZDS は設計記録なので英語のままです。

## できること

zenfmt は 19 種類の入力形式を読み、Markdown を書きます。writer を 1 つに絞ることで、多くの reader が同じ確認しやすい出力先を共有します。

| 分類 | 形式 |
|---|---|
| Word processing | `docx`/`docm`、旧 `doc`、`odt`、`rtf` |
| Spreadsheet | `xlsx`/`xlsm`、`xlsb`、旧 `xls`、`ods`、`csv`/`tsv` |
| Presentation | `pptx`/`pptm`/`ppsx`/`ppsm`、旧 `ppt`/`pps`/`pot`、`odp` |
| Publishing | `epub`、`pdf`（Zig による native text extraction）、`html` |
| Markup | `markdown`、`asciidoc`、`rst`、plain `text` |

形式は content signature から判定します。extension は最初の hint にすぎません。ZIP part name、OpenDocument と EPUB の `mimetype`、CFB stream、PDF と RTF の header も確認します。暗号化 document は明示的に拒否し、黙って読み飛ばしません。

```sh
zig build
zenfmt report.docx
zenfmt report.docx --stdout
zenfmt --list-formats
```

path 出力の隣には `*.zenfmt.json` manifest が作られます。source と artifact の digest、document metadata、diagnostic report、versioned plugin data、facet summary を canonical JSON で記録します。`--preserve-facets` で完全な facet rows も保存できます。

## Python

同じ engine を typed で dependency free の Python library として配布しています。wheel は native bridge を含み、変換中に GIL を解放します。返り値は bytes、embedded resources、canonical manifest、structured reports を含む完全な artifact ensemble です。

```python
import zenfmt

conversion = zenfmt.convert("report.docx")
print(conversion.text)
for report in conversion.reports:
    print(report.code, report.problem)

conversion = zenfmt.convert(
    uploaded_bytes,
    name="upload.docx",
    to="markdown",
)
```

`str` は常に path を表します。memory 上の内容は `bytes` で明示してください。`output` を指定すると artifact、manifest、media を transactionally に公開します。graded strictness は既知の損失を出力前に拒否できます。

```python
conversion = zenfmt.convert(
    "report.docx",
    output="build/report.md",
    strict="structure",
)
```

失敗は `ConversionError`、`LimitExceededError`、`UnknownFormatError` などの小さな exception hierarchy で表されます。message は CLI diagnostic と同じく、問題、結果、実行可能な次の手順を説明します。再利用する policy は immutable な `zenfmt.Converter` に保持され、global config、environment、network を読みません。

```sh
pip install zenfmt
```

## Browser と WebAssembly

first class の `wasm32-freestanding` distribution と静的 project site を提供します。browser module には host import がありません。変換は訪問者の端末にある dedicated worker で動き、file を upload せず、network service に fallback しません。

```sh
zig build wasm
zig build wasm-check
zig build site
zig build site-check
zig build site-browser-test
```

[日本語 project site](https://insanai.github.io/zenfmt/ja/) で直接変換できます。初回は browser language に応じて English、简体中文、日本語、한국어から interface を選びます。header の language selector でいつでも変更でき、明示した選択が browser 設定より優先されます。theme の既定値は system で、Light と Dark も選べます。

## Server

同じ native 実行ファイルに REST service と web interface が入っています。

```sh
zenfmt serve
curl -s -T report.docx \
  "http://127.0.0.1:8998/api/v1/convert?to=markdown"

zenfmt serve --secure --data-dir ./zenfmt-data
```

open mode は既定で loopback だけを listen します。secure mode は user、API key、audit log、administration UI を追加します。`http://127.0.0.1:8998/docs` は組み込み API reference、`/openapi.json` は OpenAPI 3.1 contract です。

release executable は converter、server、database migration、OpenAPI document、CSS、JavaScript bridge、HTML shell、interface WebAssembly を内蔵しています。隣接 bundle や Java、Python、npm、OCR、VLM、model runtime は必要ありません。

## 設計上の要点

- **本物の AST を flat に保存します。** Block と inline は nest でき、identifier、class、key value attributes を持ちます。preorder struct of arrays と `u32` index により node ごとの allocation を避けます。
- **Filter は Zig で書きます。** application が `visitBlock` と `visitInline` を実装し、自分の `build.zig` で pipeline に compile します。embedded scripting runtime や serialization boundary はありません。
- **engine は format を知りません。** file specification の identifier は core に入りません。format は独立 library で、conversion matrix は descriptor から compiler が作ります。
- **豊かな意味は sparse facets に載せます。** style、tracked revision、page と slide geometry、formula、provenance は typed stand off annotation で、存在しない場合の cost はありません。
- **損失には価格、report、refusal があります。** writer は compile time に capabilities を宣言します。すべての degradation は rule として manifest に残り、`--strict={content,structure,exact}` で commit 前に拒否できます。

## Repository 構成

```text
build.zig            build graph と統一入口
core/                format blind engine、AST、facets、limits、pipeline
support/             XML、OOXML、CFB の共有処理
formats/             各入力形式と Markdown plugin
src/                 標準 zenfmt bundle
cli/                 self contained CLI と serve subcommand
server/              HTTP API、secure store、embedded web UI
bindings/            Python と WebAssembly ABI
examples/filters/    application に filter を組み込む例
benchmarks/          corpus、runner、記録済み結果
tests/               conversion、round trip、fuzz、adversarial tests
docs/                英語 ZDS、英語 book、多言語 user documentation
```

通常の開発に必要なのは Zig 0.16 だけです。

```sh
zig build test
zig build fmt-check
```

## ドキュメント

- [日本語ドキュメント](https://insanai.github.io/zenfmt/ja/book/)
- [日本語 Typst source](docs/i18n/ja/)
- [英語の完全版](https://insanai.github.io/zenfmt/book/)
- [英語の設計記録](https://insanai.github.io/zenfmt/zds/)

すべての言語の PDF と HTML を build するには Typst 0.15.1 と Noto Sans CJK fonts が必要です。

```sh
zig build book-translations
zig build docs
```

## Benchmark

reference benchmark は 16 個の実在 document を変換し、speed、CPU use、peak memory を別々に報告します。ratio は、両方が正常に変換した shared files における comparison tool ÷ zenfmt です。

| Native CLI comparison | Shared files | Speed | CPU use | Peak memory |
|---|---:|---:|---:|---:|
| AnyDoc / zenfmt | 14 | 7.0x | 7.9x | 10.2x |
| Pandoc / zenfmt | 6 | 18.1x | 16.6x | 16.6x |
| Docling parser only / zenfmt | 5 | 195.9x | 209.1x | 47.6x |

これらは 1 台の一般的な Apple Silicon machine と小さな固定 corpus から得た geometric mean です。参考値であり、quality score やすべての document への約束ではありません。Docling は model free parser のみを使い、OCR、VLM、ASR、layout model、table model、enrichment、accelerator は無効です。

常駐 server benchmark は別に行い、同じ host と corpus で zenfmt と Apache Tika Server の warm HTTP conversion、sampled memory、startup、短い throughput run を比較します。[日本語 benchmark 説明](https://insanai.github.io/zenfmt/ja/benchmark/) と [英語の完全な表](https://insanai.github.io/zenfmt/benchmark/) で method と raw record を確認できます。

## License

MIT。Copyright 2026 Vikrant Rathore and Ronak Rathore.
