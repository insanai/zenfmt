# zenfmt

[English](README.md) · 简体中文 · [日本語](README.ja.md) ·
[한국어](README.ko.md)

zenfmt 是一个用 Zig 编写的文档转换器。它读取一种格式的文档，通过统一的中间表示，再输出另一种格式。

[Pandoc](https://pandoc.org/) 让我们看到通用文档转换器有多实用。zenfmt 是一次较小的探索。它没有 Pandoc 那么广的覆盖范围，而是专注于紧凑的引擎、明确的转换报告，以及下面列出的格式。

**当前版本：0.3.2。** 架构记录在 [ZDS 0002](docs/zds/records/0002-zenfmt-architecture.typ)，IR v2、facets 和 writer lowering 记录在 [ZDS 0013](docs/zds/records/0013-layered-document-ir.typ)。ZDS 是设计记录，因此保持英文。

## 功能概览

zenfmt 读取 19 种输入格式并输出 Markdown。当前只提供一个 writer，这让许多 reader 可以共享一个容易检查的目标。

| 类别 | 格式 |
|---|---|
| 文字处理 | `docx`/`docm`、旧版 `doc`、`odt`、`rtf` |
| 电子表格 | `xlsx`/`xlsm`、`xlsb`、旧版 `xls`、`ods`、`csv`/`tsv` |
| 演示文稿 | `pptx`/`pptm`/`ppsx`/`ppsm`、旧版 `ppt`/`pps`/`pot`、`odp` |
| 出版与页面 | `epub`、`pdf`（原生 Zig 文本提取）、`html` |
| Markup | `markdown`、`asciidoc`、`rst`、纯 `text` |

格式根据内容 signature 识别。扩展名只是第一条提示。zenfmt 还会检查 ZIP part name、OpenDocument 与 EPUB 的 `mimetype`、CFB stream、PDF 和 RTF header。加密文档会被明确拒绝，不会静默跳过。

```sh
zig build
zenfmt report.docx
zenfmt report.docx --stdout
zenfmt --list-formats
```

路径输出旁会创建 `*.zenfmt.json` manifest。它以 canonical JSON 保存 source 与 artifact digest、document metadata、diagnostic reports、versioned plugin data 和 facet 摘要。使用 `--preserve-facets` 可保留完整 facet rows。

## Python

同一个 engine 也作为 typed、dependency free 的 Python library 发布。wheel 包含 native bridge，转换时会释放 GIL，并返回完整 artifact ensemble，包括 bytes、embedded resources、canonical manifest 和 structured reports。

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

`str` 始终表示 path。内存内容应显式传 `bytes`。指定 `output` 会 transactionally 发布 artifact、manifest 和媒体文件。graded strictness 可在写入前拒绝已知损失。

```python
conversion = zenfmt.convert(
    "report.docx",
    output="build/report.md",
    strict="structure",
)
```

失败会抛出紧凑的 exception hierarchy，例如 `ConversionError`、`LimitExceededError` 和 `UnknownFormatError`。消息像 CLI diagnostic 一样说明问题、后果和可执行的下一步。可复用 policy 保存在 immutable `zenfmt.Converter` 中，不读取 global config、environment 或 network。

安装方式：

```sh
pip install zenfmt
```

## 浏览器与 WebAssembly

项目提供 first class `wasm32-freestanding` distribution 和静态网站。browser module 没有 host import。转换在访问者设备上的 dedicated worker 中运行，不上传文件，也不会回退到 network service。

```sh
zig build wasm
zig build wasm-check
zig build site
zig build site-check
zig build site-browser-test
```

可以直接在 [项目网站](https://insanai.github.io/zenfmt/zh-hans/) 中转换文档。网站会根据 browser language 在 English、简体中文、日本語和 한국어之间选择默认界面，也可以随时手动更改。系统 theme 是默认值，同时提供浅色与深色选项。

## Server

同一个原生可执行文件包含 REST service 和 web interface。

```sh
zenfmt serve
curl -s -T report.docx \
  "http://127.0.0.1:8998/api/v1/convert?to=markdown"

zenfmt serve --secure --data-dir ./zenfmt-data
```

open mode 默认只监听 loopback。secure mode 增加 user、API key、audit log 和 administration UI。访问 `http://127.0.0.1:8998/docs` 可查看内置 API reference，`/openapi.json` 提供 OpenAPI 3.1 contract。

发布的 executable 内嵌 converter、server、database migration、OpenAPI document、CSS、JavaScript bridge、HTML shell 和 interface WebAssembly，不需要相邻 bundle，也不需要 Java、Python、npm、OCR、VLM 或 model runtime。

## 设计重点

- **真正的 AST，使用扁平存储。** Block 和 inline 可以 nesting，并带有 identifier、class 和 key value attributes。preorder struct of arrays 与 `u32` index 避免每个 node 单独 allocation。
- **用 Zig 编写 filter。** 应用实现 `visitBlock` 与 `visitInline`，在自己的 `build.zig` 中编译进 pipeline。没有内嵌 scripting runtime 和 serialization boundary。
- **engine 不知道具体格式。** 文件规范中的 identifier 不会进入 core。format 是独立 library，conversion matrix 由 compiler 根据 descriptor 生成。
- **丰富信息放在 sparse facets 中。** style、tracked revision、page 与 slide geometry、formula 和 provenance 作为 typed stand off annotation 附在 node 上，不存在时不占空间。
- **损失有等级、有报告，也可以拒绝。** writer 在 compile time 声明 capabilities。每个降级都有明确 rule 并进入 manifest，`--strict={content,structure,exact}` 可在 commit 前拒绝。

## 仓库结构

```text
build.zig            build graph 与统一入口
core/                format blind engine、AST、facets、limits、pipeline
support/             XML、OOXML 与 CFB 等共享组件
formats/             各输入格式与 Markdown plugin
src/                 默认 zenfmt bundle
cli/                 自包含命令行程序与 serve subcommand
server/              HTTP API、secure store 与内嵌 web UI
bindings/            Python 与 WebAssembly ABI
examples/filters/    在应用中编译 filter 的示例
benchmarks/          语料库、runner 与记录结果
tests/               conversion、round trip、fuzz 与 adversarial tests
docs/                英文 ZDS、英文书与多语言用户文档
```

普通开发只需要 Zig 0.16。

```sh
zig build test
zig build fmt-check
```

## 文档

- [中文文档网站](https://insanai.github.io/zenfmt/zh-hans/book/)
- [中文 Typst 源码](docs/i18n/zh-Hans/)
- [英文完整文档](https://insanai.github.io/zenfmt/book/)
- [英文设计记录](https://insanai.github.io/zenfmt/zds/)

构建所有语言的 PDF 与 HTML 文档需要 Typst 0.15.1 和 Noto Sans CJK fonts。

```sh
zig build book-translations
zig build docs
```

## Benchmark

reference benchmark 转换 16 个真实文档，分别报告 speed、CPU use 和 peak memory。ratio 使用 comparison tool 除以 zenfmt，只计算双方都成功转换的 shared files。

| Native CLI comparison | Shared files | Speed | CPU use | Peak memory |
|---|---:|---:|---:|---:|
| AnyDoc / zenfmt | 14 | 7.0x | 7.9x | 10.2x |
| Pandoc / zenfmt | 6 | 18.1x | 16.6x | 16.6x |
| Docling parser only / zenfmt | 5 | 195.9x | 209.1x | 47.6x |

这些 geometric means 来自一台普通 Apple Silicon machine 和一个固定的小型 corpus。它们是参考值，不是质量分数，也不保证所有文档都得到相同结果。Docling 只使用 model free parser。OCR、VLM、ASR、layout model、table model、enrichment 和 accelerator 都已关闭。

长期运行的 server benchmark 单独比较 zenfmt 与 Apache Tika Server 的 warm HTTP conversion、sampled memory、startup 和短时间 throughput。详细方法和 raw records 请看[多语言 benchmark 页面](https://insanai.github.io/zenfmt/zh-hans/benchmark/)或[英文完整表格](https://insanai.github.io/zenfmt/benchmark/)。

## License

MIT。Copyright 2026 Vikrant Rathore and Ronak Rathore。
