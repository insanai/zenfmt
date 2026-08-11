"""Localized pages for the public site.

English remains the canonical source for design records. These pages cover
the user-facing site and practical documentation in Simplified Chinese,
Japanese, and Korean without pretending that ZDS records were translated.
"""

from __future__ import annotations

import html
from dataclasses import dataclass

from .shell import Page


@dataclass(frozen=True)
class Words:
    code: str
    prefix: str
    title: str
    description: str
    hero: str
    lede: str
    local: str
    workspace: str
    source: str
    drop: str
    choose: str
    example: str
    advanced: str
    loss_policy: str
    report_loss: str
    refuse_content: str
    refuse_structure: str
    refuse_exact: str
    preserve: str
    detected: str
    loading: str
    output: str
    copy: str
    download: str
    wrap: str
    cancel: str
    reset: str
    reports: str
    server_eyebrow: str
    server_title: str
    server_body: str
    server_note: str
    server_link: str
    archive_link: str
    help_title: str
    help_links: tuple[str, str, str, str]
    benchmark_eyebrow: str
    benchmark_title: str
    benchmark_body: str
    benchmark_link: str
    book_title: str
    book_description: str
    security_title: str
    security_description: str
    security_sections: tuple[tuple[str, str], ...]
    download_title: str
    download_intro: str
    release_notes: str
    checksums: str
    provenance: str
    browser_title: str
    browser_body: str
    wasm_bundle: str
    module_only: str
    mac_body: str
    linux_body: str
    windows_body: str
    python_body: str
    source_title: str
    source_body: str
    pypi: str
    source_download: str
    verify: str
    benchmark_description: str
    benchmark_intro: str
    benchmark_scope: str
    benchmark_correctness: str
    benchmark_reproduce: str


LOCALES = (
    Words(
        code="zh-Hans",
        prefix="zh-hans/",
        title="zenfmt · 在浏览器中把文档转换为 Markdown",
        description="在浏览器本地把 Word、Excel、PowerPoint、OpenDocument、EPUB、PDF 等格式转换为 Markdown，文件不会上传。",
        hero="把文档转换为 Markdown。",
        lede="Pandoc 让我们看到通用文档转换器有多实用。zenfmt 是一次较小的尝试：用 Zig 编写一个紧凑、可解释的转换引擎。",
        local="转换完全在当前浏览器中进行，文件不会上传。",
        workspace="转换文档",
        source="1 · 源文档",
        drop="把文件拖到这里",
        choose="或选择文件",
        example="使用安全示例试一试",
        advanced="高级选项",
        loss_policy="信息损失策略",
        report_loss="转换并报告信息损失",
        refuse_content="拒绝内容损失",
        refuse_structure="拒绝结构损失",
        refuse_exact="拒绝任何已知损失",
        preserve="保留 facet 详细信息",
        detected="格式根据文件内容识别，而不是只看文件名。目前支持 {count} 种格式。",
        loading="正在加载浏览器转换引擎…",
        output="2 · Markdown 输出 · 只读",
        copy="复制",
        download="下载",
        wrap="自动换行",
        cancel="取消",
        reset="重置",
        reports="转换报告",
        server_eyebrow="zenfmt {version} 已提供",
        server_title="也可以把同一个转换器作为轻量 HTTP 服务使用。",
        server_body="如果工作流需要共享端点，zenfmt serve 可从同一个可执行文件提供转换、健康检查和 metrics。开放模式默认只监听本机回环地址；安全模式增加用户、API key、审计日志和管理界面。",
        server_note="发布包仍尽量保持轻量，不包含 Java、Python、OCR、VLM 或模型文件。",
        server_link="阅读服务器指南",
        archive_link="选择原生程序包",
        help_title="需要帮助？",
        help_links=(
            "第一次转换",
            "支持的格式与限制",
            "阅读中文文档",
            "了解设计取舍（英文 ZDS）",
        ),
        benchmark_eyebrow="一组小型参考测试",
        benchmark_title="转换性能测试",
        benchmark_body="测试把速度、CPU 使用量和峰值内存分开呈现，也把 CLI 与长期运行的 server 分开。结果只描述记录它们的那台普通机器，不代表所有环境。",
        benchmark_link="查看说明、方法与原始数据",
        book_title="zenfmt 中文文档",
        book_description="从第一次转换到 CLI、Python、浏览器、server、限制和性能测试的实用指南。",
        security_title="安全与隐私",
        security_description="zenfmt 如何在不上传文档的情况下完成转换，以及浏览器版本能做什么、不能做什么。",
        security_sections=(
            (
                "文档留在设备上",
                "转换以 WebAssembly 的形式在浏览器 worker 中运行。页面读取你选择的文件并把它交给 worker；本站是静态网站，没有接收文件的转换服务器。",
            ),
            (
                "浏览器引擎的权限",
                "浏览器模块没有 host import。它不能访问文件系统、网络、时钟、随机数或线程，也不能跟随文档中的链接去获取其他资源。发布构建会直接检查编译后模块的 import table。",
            ),
            (
                "本站不会做的事",
                "本站没有分析统计、广告、session replay、远程字体、tag manager 或账户。设备上只保存你主动选择的主题和语言。",
            ),
            (
                "托管方式的限制",
                "GitHub Pages 不允许本站设置响应头，因此内容安全策略只能放在页面中。这样无法阻止其他网站把页面嵌入 frame。我们把它列为已知限制；本站不保存凭据和 session，也没有可被第三方诱导执行的账户操作。",
            ),
            ("报告问题", "请通过仓库的安全政策报告漏洞，不要附上不能公开分享的文档。"),
        ),
        download_title="下载 zenfmt {version}",
        download_intro="下面的目标平台使用同一个转换引擎，读取相同的 {count} 种格式并输出 Markdown。原生 CLI 与 server 位于同一个自包含可执行文件中。",
        release_notes="发布说明",
        checksums="SHA-256 校验值",
        provenance="构建来源证明",
        browser_title="浏览器 · WebAssembly",
        browser_body="完整引擎、标准 JavaScript adapter 和 worker。可从任意静态站点提供，不依赖 package manager，也不需要额外构建。",
        wasm_bundle="下载 WASM bundle",
        module_only="只下载 module",
        mac_body="适用于 Apple Silicon 和 Intel Mac 的原生命令行程序，需要 macOS 12 或更高版本。",
        linux_body="请明确选择 CPU 架构和 C library。glibc 构建需要 2.17 或更高版本。",
        windows_body="便携式 64 位命令行程序，无需安装或管理员权限。",
        python_body="支持 CPython 3.10 至 3.14。wheel 包含与命令行程序相同的引擎，不需要额外 runtime 依赖。",
        source_title="源代码",
        source_body="带版本 tag 的仓库源码。构建程序需要 Zig 0.16；构建文档还需要 Typst 0.15.1。",
        pypi="打开 PyPI",
        source_download="下载源码",
        verify="用于受控构建或部署前，请用发布页中的 SHA-256 清单核对下载文件。",
        benchmark_description="zenfmt 与其他转换器在覆盖率、速度、CPU、内存、server 运行和输出保真度方面的测试方法。",
        benchmark_intro="这些数字是参考值，不是对所有机器或所有文档的承诺。比较只使用双方都成功转换的文件，并保留每次测试的版本和 revision。",
        benchmark_scope="我们把三个问题分开：覆盖率说明工具实际能转换哪些文件；性能包括启动、转换耗时、CPU 时间和峰值内存；输出保真度按格式检查，不压缩成一个模糊的总分。CLI、浏览器 WebAssembly 和长期运行的 HTTP server 也分别测试。",
        benchmark_correctness="原生 CLI 和浏览器测试只有在输出检查通过后才记录时间。server 测试目前只要求响应成功且正文非空，因此它的时间数据不能代替语义质量检查。Docling 只启用 parser backend，不启用 OCR、VLM、ASR、layout model、table model、enrichment 或 accelerator。",
        benchmark_reproduce="语料库来自许可条件不同的第三方文档，因此仓库不重新分发。manifest 记录来源、格式、大小和 SHA-256。benchmarks/fetch_corpus.sh 会取得相同文件并验证每个 digest。",
    ),
    Words(
        code="ja",
        prefix="ja/",
        title="zenfmt · ブラウザでドキュメントを Markdown に変換",
        description="Word、Excel、PowerPoint、OpenDocument、EPUB、PDF などをブラウザ内で Markdown に変換します。ファイルはアップロードされません。",
        hero="ドキュメントを Markdown に変換。",
        lede="Pandoc は、汎用ドキュメント変換ツールの便利さを示しました。zenfmt は、その考え方を Zig 製の小さく説明しやすいエンジンで探る試みです。",
        local="変換はこのブラウザ内だけで行われ、ファイルはアップロードされません。",
        workspace="ドキュメントを変換",
        source="1 · 入力ドキュメント",
        drop="ここにファイルをドロップ",
        choose="またはファイルを選択",
        example="安全なサンプルを試す",
        advanced="詳細オプション",
        loss_policy="情報損失の扱い",
        report_loss="変換して損失を報告",
        refuse_content="内容の損失を拒否",
        refuse_structure="構造の損失を拒否",
        refuse_exact="既知の損失をすべて拒否",
        preserve="facet の詳細を保持",
        detected="形式はファイル名だけでなく内容から判定します。{count} 形式に対応しています。",
        loading="ブラウザ用エンジンを読み込んでいます…",
        output="2 · Markdown 出力 · 読み取り専用",
        copy="コピー",
        download="ダウンロード",
        wrap="行を折り返す",
        cancel="キャンセル",
        reset="リセット",
        reports="変換レポート",
        server_eyebrow="zenfmt {version} で利用できます",
        server_title="同じ変換エンジンを小さな HTTP サービスとして使えます。",
        server_body="共有 endpoint が必要な場合は、同じ実行ファイルの zenfmt serve が変換、health check、metrics を提供します。open mode は既定で loopback のみに接続し、secure mode はユーザー、API key、監査ログ、管理画面を追加します。",
        server_note="配布物は控えめな要件を保ち、Java、Python、OCR、VLM、モデルファイルを同梱しません。",
        server_link="server ガイドを読む",
        archive_link="ネイティブ版を選ぶ",
        help_title="お困りですか？",
        help_links=(
            "最初の変換",
            "対応形式と上限",
            "日本語ドキュメントを読む",
            "設計判断を読む（英語 ZDS）",
        ),
        benchmark_eyebrow="小規模な参考ベンチマーク",
        benchmark_title="変換ベンチマーク",
        benchmark_body="速度、CPU 使用量、ピークメモリを別々に示し、CLI と常駐 server も分けて測ります。数値は記録に使った一般的な 1 台のマシンを表すもので、すべての環境を保証するものではありません。",
        benchmark_link="説明、測定方法、生データを見る",
        book_title="zenfmt 日本語ドキュメント",
        book_description="最初の変換から CLI、Python、ブラウザ、server、上限、ベンチマークまでを扱う実用ガイド。",
        security_title="セキュリティとプライバシー",
        security_description="zenfmt がファイルをアップロードせずに変換する仕組みと、ブラウザ版で可能なこと、できないこと。",
        security_sections=(
            (
                "ドキュメントは端末内に残ります",
                "変換は WebAssembly としてブラウザの worker 内で動きます。ページが選択したファイルを読み、worker に渡します。このサイトは静的ファイルだけで構成され、アップロードを受け取る変換 server はありません。",
            ),
            (
                "ブラウザエンジンの権限",
                "ブラウザ module には host import がありません。ファイルシステム、ネットワーク、時計、乱数、thread を利用できず、文書内のリンク先から別の resource を取得することもできません。release build では、コンパイル済み module の import table を直接検査します。",
            ),
            (
                "このサイトが行わないこと",
                "analytics、広告、session replay、外部 font、tag manager、account はありません。端末に保存するのは、利用者が選んだ theme と language だけです。",
            ),
            (
                "ホスティング上の制限",
                "GitHub Pages では任意の response header を設定できないため、content security policy はページ内に置かれます。この方法では、別サイトによる frame 埋め込みを防げません。既知の制限として明記していますが、サイトは credential や session を持たず、第三者が誘導できる account 操作もありません。",
            ),
            (
                "問題を報告する",
                "脆弱性は repository の security policy に沿って報告してください。公開できないドキュメントは添付しないでください。",
            ),
        ),
        download_title="zenfmt {version} をダウンロード",
        download_intro="以下の target は同じ変換エンジンで同じ {count} 形式を読み、Markdown を出力します。ネイティブ CLI と server は 1 つの自己完結した実行ファイルです。",
        release_notes="リリースノート",
        checksums="SHA-256 チェックサム",
        provenance="ビルド provenance",
        browser_title="ブラウザ · WebAssembly",
        browser_body="完全なエンジン、標準的な JavaScript adapter、worker のセットです。任意の静的サイトから配信でき、package manager や追加の build step は不要です。",
        wasm_bundle="WASM bundle をダウンロード",
        module_only="module のみダウンロード",
        mac_body="Apple Silicon および Intel Mac 用のネイティブ CLI です。macOS 12 以降が必要です。",
        linux_body="CPU architecture と C library を明示して選びます。glibc build は 2.17 以降が必要です。",
        windows_body="portable な 64 bit CLI です。installer や管理者権限は不要です。",
        python_body="CPython 3.10 から 3.14 に対応します。wheel は CLI と同じエンジンを含み、追加の runtime dependency はありません。",
        source_title="ソースコード",
        source_body="version tag 付きの repository source です。build には Zig 0.16、ドキュメントには Typst 0.15.1 が必要です。",
        pypi="PyPI を開く",
        source_download="source をダウンロード",
        verify="管理された build や deployment で使う前に、release の SHA-256 manifest とダウンロードしたファイルを照合してください。",
        benchmark_description="zenfmt と他の変換ツールを coverage、速度、CPU、memory、server 運用、出力保持の観点で測る方法。",
        benchmark_intro="これらは参考値であり、すべての machine や document に対する約束ではありません。比較は両方が正常に変換できた file だけを使い、各測定の version と revision を残します。",
        benchmark_scope="3 つの問いを混ぜません。coverage は実際に変換できる file、performance は起動、変換時間、CPU 時間、peak memory、output preservation は形式ごとの検査です。曖昧な総合 score にはまとめません。CLI、browser WebAssembly、常駐 HTTP server も別々に測ります。",
        benchmark_correctness="native CLI と browser は output check を通過した結果だけを timing に含めます。server は現在、成功 response と空でない body だけを確認するため、その timing は意味上の品質検査の代わりにはなりません。Docling は parser backend のみを使い、OCR、VLM、ASR、layout model、table model、enrichment、accelerator は無効です。",
        benchmark_reproduce="corpus は license の異なる第三者文書から成るため再配布しません。manifest に source、format、size、SHA-256 を記録しています。benchmarks/fetch_corpus.sh は同じ file を取得し、すべての digest を検証します。",
    ),
    Words(
        code="ko",
        prefix="ko/",
        title="zenfmt · 브라우저에서 문서를 Markdown으로 변환",
        description="Word, Excel, PowerPoint, OpenDocument, EPUB, PDF 등을 브라우저 안에서 Markdown으로 변환합니다. 파일은 업로드되지 않습니다.",
        hero="문서를 Markdown으로 변환하세요.",
        lede="Pandoc은 범용 문서 변환기가 얼마나 유용한지 보여 주었습니다. zenfmt는 그 아이디어를 Zig로 작성한 작고 설명하기 쉬운 엔진으로 살펴보는 시도입니다.",
        local="변환은 이 브라우저 안에서만 실행되며 파일은 업로드되지 않습니다.",
        workspace="문서 변환",
        source="1 · 원본 문서",
        drop="파일을 여기에 놓으세요",
        choose="또는 파일 선택",
        example="안전한 예제로 시험하기",
        advanced="고급 옵션",
        loss_policy="정보 손실 정책",
        report_loss="변환하고 손실 보고",
        refuse_content="내용 손실 거부",
        refuse_structure="구조 손실 거부",
        refuse_exact="알려진 모든 손실 거부",
        preserve="facet 세부 정보 보존",
        detected="파일 이름뿐 아니라 내용을 보고 형식을 판별합니다. {count}개 형식을 지원합니다.",
        loading="브라우저 엔진을 불러오는 중…",
        output="2 · Markdown 결과 · 읽기 전용",
        copy="복사",
        download="다운로드",
        wrap="줄 바꿈",
        cancel="취소",
        reset="초기화",
        reports="변환 보고서",
        server_eyebrow="zenfmt {version}에서 제공",
        server_title="같은 변환기를 작은 HTTP 서비스로 사용할 수도 있습니다.",
        server_body="공유 endpoint가 필요한 workflow에서는 같은 실행 파일의 zenfmt serve가 변환, health check, metrics를 제공합니다. open mode는 기본적으로 loopback에서만 실행되고, secure mode는 사용자, API key, 감사 로그, 관리 화면을 추가합니다.",
        server_note="배포 파일은 필요한 환경을 작게 유지하며 Java, Python, OCR, VLM, model 파일을 포함하지 않습니다.",
        server_link="server 안내서 읽기",
        archive_link="네이티브 압축 파일 선택",
        help_title="도움이 필요하신가요?",
        help_links=(
            "첫 번째 변환",
            "지원 형식과 제한",
            "한국어 문서 읽기",
            "설계 판단 살펴보기 (영어 ZDS)",
        ),
        benchmark_eyebrow="작은 참고 벤치마크",
        benchmark_title="변환 벤치마크",
        benchmark_body="속도, CPU 사용량, 최대 메모리를 따로 보여 주고 CLI와 장기 실행 server도 분리해 측정합니다. 수치는 기록에 사용한 보통 사양의 한 컴퓨터를 설명할 뿐, 모든 환경을 보장하지 않습니다.",
        benchmark_link="설명, 측정 방법, 원본 데이터 보기",
        book_title="zenfmt 한국어 문서",
        book_description="첫 변환부터 CLI, Python, 브라우저, server, 제한, 벤치마크까지 다루는 실용 안내서입니다.",
        security_title="보안과 개인정보 보호",
        security_description="zenfmt가 문서를 업로드하지 않고 변환하는 방식과 브라우저 엔진이 할 수 있는 일과 할 수 없는 일을 설명합니다.",
        security_sections=(
            (
                "문서는 기기에 남습니다",
                "변환은 WebAssembly로 브라우저 worker 안에서 실행됩니다. 페이지는 사용자가 고른 파일을 읽어 worker에 전달합니다. 이 사이트는 정적 파일로만 구성되며 업로드를 받는 변환 server가 없습니다.",
            ),
            (
                "브라우저 엔진의 권한",
                "브라우저 module에는 host import가 없습니다. 파일 시스템, 네트워크, 시계, 난수, thread를 사용할 수 없고 문서 속 link를 따라 다른 resource를 가져올 수도 없습니다. release build에서는 컴파일된 module의 import table을 직접 검사합니다.",
            ),
            (
                "이 사이트가 하지 않는 일",
                "analytics, 광고, session replay, 외부 font, tag manager, account가 없습니다. 기기에는 사용자가 선택한 theme와 language만 저장합니다.",
            ),
            (
                "호스팅의 한계",
                "GitHub Pages에서는 원하는 response header를 설정할 수 없어 content security policy를 페이지 안에 둡니다. 이 방법으로는 다른 사이트의 frame 삽입을 막을 수 없습니다. 이를 알려진 한계로 기록하며, 사이트에는 credential, session, 제삼자가 유도할 account 작업이 없습니다.",
            ),
            (
                "문제 신고",
                "취약점은 repository의 security policy를 따라 신고해 주세요. 공개할 수 없는 문서는 첨부하지 마세요.",
            ),
        ),
        download_title="zenfmt {version} 다운로드",
        download_intro="아래 target은 같은 변환 엔진으로 같은 {count}개 형식을 읽고 Markdown을 출력합니다. 네이티브 CLI와 server는 하나의 독립 실행 파일에 들어 있습니다.",
        release_notes="release note",
        checksums="SHA-256 checksum",
        provenance="build provenance",
        browser_title="브라우저 · WebAssembly",
        browser_body="전체 엔진, 표준 JavaScript adapter, worker를 제공합니다. 어떤 정적 사이트에서도 배포할 수 있으며 package manager나 추가 build step이 필요하지 않습니다.",
        wasm_bundle="WASM bundle 다운로드",
        module_only="module만 다운로드",
        mac_body="Apple Silicon과 Intel Mac용 네이티브 CLI입니다. macOS 12 이상이 필요합니다.",
        linux_body="CPU architecture와 C library를 명확히 선택하세요. glibc build는 2.17 이상이 필요합니다.",
        windows_body="portable 64 bit CLI입니다. installer나 관리자 권한이 필요하지 않습니다.",
        python_body="CPython 3.10부터 3.14까지 지원합니다. wheel에는 CLI와 같은 엔진이 들어 있으며 추가 runtime dependency가 없습니다.",
        source_title="소스 코드",
        source_body="version tag가 붙은 repository source입니다. build에는 Zig 0.16이 필요하고 문서에는 Typst 0.15.1도 필요합니다.",
        pypi="PyPI 열기",
        source_download="source 다운로드",
        verify="통제된 build나 deployment에 사용하기 전에 release의 SHA-256 manifest와 받은 파일을 대조해 주세요.",
        benchmark_description="zenfmt와 다른 변환기를 coverage, 속도, CPU, memory, server 운영, 출력 보존 측면에서 측정하는 방법입니다.",
        benchmark_intro="이 수치는 참고 자료이며 모든 컴퓨터나 문서에 대한 약속이 아닙니다. 두 도구가 모두 성공한 파일만 비교하고 각 측정의 version과 revision을 함께 기록합니다.",
        benchmark_scope="세 가지 질문을 섞지 않습니다. coverage는 실제로 변환한 파일, performance는 시작 시간, 변환 시간, CPU 시간, peak memory, output preservation은 형식별 검사입니다. 이를 모호한 종합 점수로 합치지 않습니다. CLI, browser WebAssembly, 장기 실행 HTTP server도 따로 측정합니다.",
        benchmark_correctness="native CLI와 browser는 output check를 통과한 결과만 timing에 포함합니다. server는 현재 성공 response와 비어 있지 않은 body만 확인하므로 그 timing이 의미 품질 검사를 대신하지는 못합니다. Docling은 parser backend만 사용하며 OCR, VLM, ASR, layout model, table model, enrichment, accelerator를 모두 끕니다.",
        benchmark_reproduce="corpus는 license가 서로 다른 제삼자 문서로 구성되어 다시 배포하지 않습니다. manifest에 source, format, size, SHA-256을 기록합니다. benchmarks/fetch_corpus.sh는 같은 파일을 가져와 모든 digest를 확인합니다.",
    ),
)

BENCHMARK_LABELS = {
    "zh-Hans": (
        "分别衡量覆盖率、性能与输出保真度",
        "先验证正确性，再记录时间",
        "复现性能测试",
        "查看英文完整表格和原始数据",
    ),
    "ja": (
        "Coverage、performance、output preservation を分ける",
        "正しさを確認してから時間を測る",
        "ベンチマークを再現する",
        "英語の完全な表と生データを見る",
    ),
    "ko": (
        "Coverage, performance, output preservation을 나누어 측정",
        "정확성을 확인한 뒤 시간 측정",
        "벤치마크 재현",
        "영어 전체 표와 원본 데이터 보기",
    ),
}

HELP_ANCHORS = {
    "zh-Hans": ("section-2", "section-8"),
    "ja": ("section-2", "data"),
    "ko": ("section-2", "data"),
}


def _e(value: object) -> str:
    return html.escape(str(value), quote=True)


def homepage(words: Words, capabilities: dict) -> Page:
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
    version = capabilities["version"]
    body = _converter(words, accept, readable, version) + _home_support(words, version)
    return Page(
        route=words.prefix,
        title=words.title,
        description=words.description,
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
        locale=words.code,
    )


def _converter(words: Words, accept: str, readable: int, version: str) -> str:
    return f"""
<section class="hero">
  <p class="eyebrow">zenfmt {_e(version)}</p>
  <h1>{words.hero}</h1>
  <p class="lede">{words.lede}</p>
  <p class="promise">{words.local}</p>
</section>
<section class="workspace" aria-label="{words.workspace}">
  <div class="pane pane-input">
    <h2 class="pane-title">{words.source}</h2>
    <label class="drop" for="source" data-drop>
      <input type="file" id="source" name="source" data-source accept="{_e(accept)}">
      <span class="drop-headline">{words.drop}</span>
      <span class="drop-detail">{words.choose}</span>
    </label>
    <button class="text-action" type="button" data-example>{words.example}</button>
    <p class="file-meta" data-file-meta hidden></p>
    <details class="advanced"><summary>{words.advanced}</summary>
      <label for="strict">{words.loss_policy}</label>
      <select id="strict" data-strict>
        <option value="off">{words.report_loss}</option>
        <option value="content">{words.refuse_content}</option>
        <option value="structure">{words.refuse_structure}</option>
        <option value="exact">{words.refuse_exact}</option>
      </select>
      <label><input type="checkbox" data-facets> {words.preserve}</label>
    </details>
    <p class="pane-note">{words.detected.format(count=readable)}</p>
    <p class="status" role="status" aria-live="polite" data-status>{words.loading}</p>
  </div>
  <div class="pane pane-output">
    <h2 class="pane-title">{words.output}</h2>
    <div class="pane-actions">
      <button type="button" data-copy disabled>{words.copy}</button>
      <button type="button" data-download disabled>{words.download}</button>
      <button type="button" data-wrap aria-pressed="true">{words.wrap}</button>
      <button type="button" data-cancel hidden>{words.cancel}</button>
      <button type="button" data-reset disabled>{words.reset}</button>
    </div>
    <pre class="output" tabindex="0" aria-label="{words.output}" data-output></pre>
  </div>
</section>
<section class="reports" aria-label="{words.reports}" data-reports hidden></section>
"""


def _home_support(words: Words, version: str) -> str:
    first_conversion, limits = HELP_ANCHORS[words.code]
    return f"""
<section class="server-summary">
  <p class="eyebrow">{words.server_eyebrow.format(version=_e(version))}</p>
  <h2>{words.server_title}</h2><p class="lede">{words.server_body}</p>
  <pre class="command"><code>zenfmt serve
curl -s -T report.docx "http://127.0.0.1:8998/api/v1/convert?to=markdown"
zenfmt serve --secure --data-dir ./zenfmt-data</code></pre>
  <p>{words.server_note} <a href="{{LINK:{words.prefix}book/}}">{words.server_link}</a>
  · <a href="{{LINK:{words.prefix}download/}}">{words.archive_link}</a></p>
</section>
<section class="help"><h2>{words.help_title}</h2><ul class="help-links">
  <li><a href="{{LINK:{words.prefix}book/#{first_conversion}}}">{words.help_links[0]}</a></li>
  <li><a href="{{LINK:{words.prefix}book/#{limits}}}">{words.help_links[1]}</a></li>
  <li><a href="{{LINK:{words.prefix}book/}}">{words.help_links[2]}</a></li>
  <li><a href="{{LINK:zds/}}">{words.help_links[3]}</a></li>
</ul></section>
<section class="benchmark-summary"><p class="eyebrow">{words.benchmark_eyebrow}</p>
  <h2>{words.benchmark_title}</h2><p>{words.benchmark_body}</p>
  <p><a href="{{LINK:{words.prefix}benchmark/}}">{words.benchmark_link}</a></p>
</section>
"""


def security_page(words: Words) -> Page:
    sections = "".join(
        f"<h2>{title}</h2><p>{body}</p>" for title, body in words.security_sections
    )
    return Page(
        route=f"{words.prefix}security/",
        title=f"{words.security_title} · zenfmt",
        description=words.security_description,
        body=f"<h1>{words.security_title}</h1>{sections}",
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
        locale=words.code,
    )


def download_page(words: Words, capabilities: dict, version: str) -> Page:
    count = sum(1 for entry in capabilities["formats"] if entry["read"])
    release = f"https://github.com/insanai/zenfmt/releases/download/v{version}"

    def asset(name: str, label: str) -> str:
        return f'<a class="download-button" href="{release}/{name}">{label}</a>'

    body = f"""
<h1>{words.download_title.format(version=_e(version))}</h1>
<p class="lede">{words.download_intro.format(count=count)}</p>
<p><a href="https://github.com/insanai/zenfmt/releases/tag/v{_e(version)}">{words.release_notes}</a>
· <a href="{release}/SHA256SUMS">{words.checksums}</a>
· <a href="https://github.com/insanai/zenfmt/attestations">{words.provenance}</a></p>
<div class="targets">
<section class="target target-featured"><h2>{words.browser_title}</h2><p>{words.browser_body}</p>
<p class="download-actions">{asset(f"zenfmt-{version}-wasm32-freestanding.tar.gz", words.wasm_bundle)}
{asset(f"zenfmt-{version}-wasm32-freestanding.wasm", words.module_only)}</p></section>
<section class="target"><h2>macOS</h2><p>{words.mac_body}</p><p class="download-actions">
{asset(f"zenfmt-{version}-aarch64-macos.tar.gz", "Apple Silicon")}
{asset(f"zenfmt-{version}-x86_64-macos.tar.gz", "Intel")}</p></section>
<section class="target"><h2>Linux</h2><p>{words.linux_body}</p><p class="download-actions">
{asset(f"zenfmt-{version}-x86_64-linux-gnu.tar.gz", "x86-64 · glibc")}
{asset(f"zenfmt-{version}-aarch64-linux-gnu.tar.gz", "ARM64 · glibc")}
{asset(f"zenfmt-{version}-x86_64-linux-musl.tar.gz", "x86-64 · musl")}
{asset(f"zenfmt-{version}-aarch64-linux-musl.tar.gz", "ARM64 · musl")}</p></section>
<section class="target"><h2>Windows</h2><p>{words.windows_body}</p><p class="download-actions">
{asset(f"zenfmt-{version}-x86_64-windows.zip", "Windows x86-64")}</p></section>
<section class="target"><h2>Python</h2><p><code>uv add zenfmt</code></p><p>{words.python_body}</p>
<p><a class="download-button" href="https://pypi.org/project/zenfmt/{_e(version)}/">{words.pypi}</a></p></section>
<section class="target"><h2>{words.source_title}</h2><p>{words.source_body}</p><p>
<a class="download-button" href="https://github.com/insanai/zenfmt/archive/refs/tags/v{_e(version)}.tar.gz">{words.source_download}</a></p></section>
</div><p>{words.verify}</p>
"""
    return Page(
        route=f"{words.prefix}download/",
        title=words.download_title.format(version=version),
        description=words.download_intro.format(count=count),
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
        locale=words.code,
    )


def benchmark_page(words: Words) -> Page:
    scope, correctness, reproduce, tables = BENCHMARK_LABELS[words.code]
    body = f"""
<h1>{words.benchmark_title}</h1><p class="lede">{words.benchmark_intro}</p>
<h2>{scope}</h2><p>{words.benchmark_scope}</p>
<h2>{correctness}</h2><p>{words.benchmark_correctness}</p>
<h2>{reproduce}</h2><p>{words.benchmark_reproduce}</p>
<p><a href="{{LINK:book/benchmark/}}">{tables}</a></p>
"""
    return Page(
        route=f"{words.prefix}benchmark/",
        title=f"{words.benchmark_title} · zenfmt",
        description=words.benchmark_description,
        body=body,
        stylesheets=["assets/css/site.css"],
        scripts=["assets/js/main.js"],
        locale=words.code,
    )
