# zenfmt

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) ·
한국어

zenfmt는 Zig로 작성한 문서 변환기입니다. 한 형식의 문서를 읽고 공통 중간 표현을 거쳐 다른 형식으로 씁니다.

[Pandoc](https://pandoc.org/)은 범용 문서 변환기가 얼마나 유용한지 보여 주었습니다. zenfmt는 그 아이디어를 작은 Zig engine으로 살펴보는 시도입니다. Pandoc만큼 넓은 범위를 제공하지는 않으며 compact한 engine, 명확한 conversion report, 아래에 적은 형식에 집중합니다.

**현재 release는 0.3.7입니다.** Architecture는 [ZDS 0002](docs/zds/records/0002-zenfmt-architecture.typ), IR v2와 facets, writer lowering은 [ZDS 0013](docs/zds/records/0013-layered-document-ir.typ)에 기록되어 있습니다. ZDS는 설계 기록이므로 영어로 유지합니다.

## 주요 기능

zenfmt는 19가지 입력 형식을 읽고 Markdown을 씁니다. writer를 하나로 한정해 여러 reader가 확인하기 쉬운 같은 출력을 공유합니다.

| 분류 | 형식 |
|---|---|
| Word processing | `docx`/`docm`, 예전 `doc`, `odt`, `rtf` |
| Spreadsheet | `xlsx`/`xlsm`, `xlsb`, 예전 `xls`, `ods`, `csv`/`tsv` |
| Presentation | `pptx`/`pptm`/`ppsx`/`ppsm`, 예전 `ppt`/`pps`/`pot`, `odp` |
| Publishing | `epub`, `pdf` (Zig native text extraction), `html` |
| Markup | `markdown`, `asciidoc`, `rst`, plain `text` |

형식은 content signature로 판별합니다. 확장자는 첫 hint일 뿐입니다. ZIP part name, OpenDocument와 EPUB의 `mimetype`, CFB stream, PDF와 RTF header도 확인합니다. 암호화된 문서는 분명하게 거부하고 조용히 건너뛰지 않습니다.

```sh
zig build
zenfmt report.docx
zenfmt report.docx --stdout
zenfmt --list-formats
```

path 출력 옆에는 `*.zenfmt.json` manifest가 생깁니다. source와 artifact digest, document metadata, diagnostic reports, versioned plugin data, facet summary를 canonical JSON으로 기록합니다. `--preserve-facets`를 사용하면 전체 facet rows도 저장할 수 있습니다.

## Python

같은 engine을 typed dependency free Python library로 배포합니다. wheel에는 native bridge가 들어 있으며 변환 중 GIL을 해제합니다. 반환값은 bytes, embedded resources, canonical manifest, structured reports를 포함한 전체 artifact ensemble입니다.

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

`str`은 항상 path입니다. memory의 내용은 `bytes`로 명확히 전달하세요. `output`을 지정하면 artifact, manifest, media를 transaction 방식으로 게시합니다. graded strictness는 알려진 손실을 출력 전에 거부할 수 있습니다.

```python
conversion = zenfmt.convert(
    "report.docx",
    output="build/report.md",
    strict="structure",
)
```

실패는 `ConversionError`, `LimitExceededError`, `UnknownFormatError` 같은 작은 exception hierarchy로 나타납니다. message는 CLI diagnostic처럼 문제, 결과, 실행할 수 있는 다음 단계를 설명합니다. 재사용 policy는 immutable `zenfmt.Converter`에 보관되며 global config, environment, network를 읽지 않습니다.

```sh
pip install zenfmt
```

macOS에서는 repository가 제공하는 Homebrew cask도 사용할 수 있습니다. 현재 architecture에 맞는 self contained CLI와 server archive를 GitHub Releases에서 직접 받습니다.

```sh
brew install --cask \
  https://raw.githubusercontent.com/insanai/zenfmt/main/packaging/homebrew/Casks/zenfmt.rb
```

## 브라우저와 WebAssembly

first class `wasm32-freestanding` distribution과 정적 project site를 제공합니다. browser module에는 host import가 없습니다. 변환은 방문자의 기기에 있는 dedicated worker에서 실행되고 파일을 upload하거나 network service로 fallback하지 않습니다.

```sh
zig build wasm
zig build wasm-check
zig build site
zig build site-check
zig build site-browser-test
```

[한국어 project site](https://insanai.github.io/zenfmt/ko/)에서 바로 변환할 수 있습니다. 첫 방문에는 browser language에 따라 English, 简体中文, 日本語, 한국어 중 기본 interface를 고릅니다. header의 language selector에서 언제든 바꿀 수 있으며 명시적으로 고른 언어가 browser 설정보다 우선합니다. theme 기본값은 system이고 Light와 Dark도 선택할 수 있습니다.

Web application은 같은 browser distribution을 npm으로 설치할 수 있습니다.

```sh
npm install @insanai/zenfmt
```

이 dependency free package에는 검사한 WASM module, ES module adapter, worker, TypeScript declarations, capability contract가 들어 있습니다. npm은 browser distribution을 받는 한 가지 방법일 뿐이며 native CLI와 server에는 Node나 npm이 필요하지 않습니다.

## Server

같은 native 실행 파일에 REST service와 web interface가 들어 있습니다.

```sh
zenfmt serve
curl -s -T report.docx \
  "http://127.0.0.1:8998/api/v1/convert?to=markdown"

zenfmt serve --secure --data-dir ./zenfmt-data
```

open mode는 기본적으로 loopback에서만 listen합니다. secure mode는 user, API key, audit log, administration UI를 추가합니다. `http://127.0.0.1:8998/docs`에서 내장 API reference를 볼 수 있고 `/openapi.json`은 OpenAPI 3.1 contract를 제공합니다.

release executable에는 converter, server, database migration, OpenAPI document, CSS, JavaScript bridge, HTML shell, interface WebAssembly가 내장되어 있습니다. 인접 bundle이나 Java, Python, npm, OCR, VLM, model runtime은 필요하지 않습니다.

## 설계의 핵심

- **실제 AST를 flat하게 저장합니다.** Block과 inline은 중첩되고 identifier, class, key value attributes를 가집니다. preorder struct of arrays와 `u32` index로 node별 allocation을 피합니다.
- **Filter는 Zig로 작성합니다.** application이 `visitBlock`과 `visitInline`을 구현하고 자기 `build.zig`에서 pipeline에 compile합니다. embedded scripting runtime이나 serialization boundary가 없습니다.
- **engine은 format을 모릅니다.** file specification의 identifier가 core에 들어가지 않습니다. format은 독립 library이며 compiler가 descriptor에서 conversion matrix를 만듭니다.
- **풍부한 의미는 sparse facets에 둡니다.** style, tracked revision, page와 slide geometry, formula, provenance는 typed stand off annotation이며 없을 때는 공간을 쓰지 않습니다.
- **손실은 가격을 매기고 보고하며 거부할 수 있습니다.** writer는 compile time에 capabilities를 선언합니다. 모든 degradation은 rule로 manifest에 기록되고 `--strict={content,structure,exact}`가 commit 전에 거부할 수 있습니다.

## Repository 구조

```text
build.zig            build graph와 통합 entry point
core/                format blind engine, AST, facets, limits, pipeline
support/             XML, OOXML, CFB 공통 처리
formats/             각 입력 형식과 Markdown plugin
src/                 기본 zenfmt bundle
cli/                 self contained CLI와 serve subcommand
server/              HTTP API, secure store, embedded web UI
bindings/            Python과 WebAssembly ABI
packages/wasm/       npm package metadata와 entry point
packaging/homebrew/  따로 옮길 수 있는 Homebrew tap과 cask
examples/filters/    application에 filter를 compile하는 예제
benchmarks/          corpus, runner, 기록된 결과
tests/               conversion, round trip, fuzz, adversarial tests
docs/                영어 ZDS와 book, 다국어 사용자 문서
```

일반 개발에는 Zig 0.16만 필요합니다.

```sh
zig build test
zig build fmt-check
```

## 문서

- [한국어 문서](https://insanai.github.io/zenfmt/ko/book/)
- [한국어 Typst source](docs/i18n/ko/)
- [영어 전체 문서](https://insanai.github.io/zenfmt/book/)
- [영어 설계 기록](https://insanai.github.io/zenfmt/zds/)

모든 언어의 PDF와 HTML을 build하려면 Typst 0.15.1과 Noto Sans CJK fonts가 필요합니다.

```sh
zig build book-translations
zig build docs
```

## Benchmark

reference benchmark는 실제 문서 16개를 변환하고 speed, CPU use, peak memory를 따로 보고합니다. ratio는 두 도구가 모두 성공한 shared files에서 comparison tool을 zenfmt로 나눈 값입니다.

| Native CLI comparison | Shared files | Speed | CPU use | Peak memory |
|---|---:|---:|---:|---:|
| AnyDoc / zenfmt | 14 | 6.9x | 7.9x | 10.1x |
| Pandoc / zenfmt | 6 | 18.2x | 16.5x | 16.6x |
| Docling parser only / zenfmt | 5 | 190.4x | 205.5x | 47.5x |

이 값은 보통 사양의 Apple Silicon machine 한 대와 작은 고정 corpus에서 구한 geometric mean입니다. 참고 값일 뿐 quality score나 모든 문서에 대한 약속이 아닙니다. Docling은 model free parser만 사용하며 OCR, VLM, ASR, layout model, table model, enrichment, accelerator를 모두 끕니다.

장기 실행 server benchmark는 따로 수행하며 같은 host와 corpus에서 zenfmt와 Apache Tika Server의 warm HTTP conversion, sampled memory, startup, 짧은 throughput run을 비교합니다. [한국어 benchmark 설명](https://insanai.github.io/zenfmt/ko/benchmark/)과 [영어 전체 표](https://insanai.github.io/zenfmt/benchmark/)에서 method와 raw record를 확인할 수 있습니다.

## License

MIT. Copyright 2026 Vikrant Rathore and Ronak Rathore.
