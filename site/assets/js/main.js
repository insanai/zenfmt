// The zenfmt site's own script (ZDS 0015, Converter Interaction).
//
// Two jobs, in this order: apply the colour theme, and run the converter. The
// theme comes first because it is the only thing on the page that must happen
// before paint; the converter is deliberately last, because the book, the
// records, and the downloads must work whether or not the engine ever loads.
//
// The output window is populated through `textContent` only. Converted
// Markdown is untrusted text — it came from a document the visitor found
// somewhere — and rendering it would create a second security surface for no
// benefit, since what was asked for is the Markdown itself.

const root = document.documentElement;
const locale = root.dataset.locale ?? 'en';

const MESSAGES = {
  en: {
    searchFailed: 'Search could not be loaded. Browse the Book or ZDS instead.',
    noMatches: 'No matching Book chapter or design record.',
    ready: 'Ready. Choose a document.',
    exampleTitle: '# A first conversion',
    exampleBody: 'This document was created in your browser.',
    exampleLocal: 'It never leaves this device.',
    exampleMarkdown: 'The output remains plain Markdown.',
    wrapOff: 'Wrap lines: off',
    wrapOn: 'Wrap lines',
    copied: 'Copied',
    copy: 'Copy',
    copyBlocked: 'Copying was blocked by the browser. Select the text and copy it.',
    alreadyRunning: 'A conversion is already running. Cancel it before choosing another file.',
    stays: 'stays on this device',
    converting: (name) => `Converting ${name}…`,
    binary: '(this writer produced binary output; use Download)',
    complete: (ms) => `Ready · converted locally in ${ms} ms`,
    conversionFailed: 'Conversion failed',
    noArtifact: 'No artifact was produced.',
    directions: 'What you can do:',
    details: 'Details',
    engineTitle: 'THE BROWSER ENGINE COULD NOT START',
    engineBody: 'Nothing was converted. The rest of this page still works.',
    reload: 'Reload the page: A temporary browser failure is the most common cause.',
    conversionTitle: 'THE CONVERSION COULD NOT BE COMPLETED',
    retry: 'Reload the page and try again.',
  },
  'zh-Hans': {
    searchFailed: '无法加载搜索。你仍然可以浏览中文文档或英文 ZDS。',
    noMatches: '没有找到匹配的文档章节或设计记录。',
    ready: '已就绪，请选择文档。',
    exampleTitle: '# 第一次转换',
    exampleBody: '这份文档在浏览器中创建。',
    exampleLocal: '它不会离开这台设备。',
    exampleMarkdown: '输出仍是纯 Markdown。',
    wrapOff: '自动换行：关闭',
    wrapOn: '自动换行',
    copied: '已复制',
    copy: '复制',
    copyBlocked: '浏览器阻止了复制操作。请选中文本后手动复制。',
    alreadyRunning: '已有转换正在运行。请先取消，再选择其他文件。',
    stays: '只留在这台设备上',
    converting: (name) => `正在转换 ${name}…`,
    binary: '（这个 writer 生成了二进制结果，请使用“下载”）',
    complete: (ms) => `已完成 · 在本地用时 ${ms} ms`,
    conversionFailed: '转换失败',
    noArtifact: '没有生成 artifact。',
    directions: '你可以这样处理：',
    details: '详细信息',
    engineTitle: '浏览器转换引擎无法启动',
    engineBody: '没有转换任何内容，页面的其他部分仍可使用。',
    reload: '请重新加载页面。最常见的原因是临时浏览器故障。',
    conversionTitle: '无法完成转换',
    retry: '请重新加载页面后再试一次。',
  },
  ja: {
    searchFailed: '検索を読み込めませんでした。日本語ドキュメントまたは英語 ZDS はそのまま閲覧できます。',
    noMatches: '一致するドキュメントまたは設計記録がありません。',
    ready: '準備できました。ドキュメントを選択してください。',
    exampleTitle: '# 最初の変換',
    exampleBody: 'このドキュメントはブラウザ内で作成されました。',
    exampleLocal: 'この端末の外へ送信されません。',
    exampleMarkdown: '出力は plain Markdown のままです。',
    wrapOff: '行の折り返し：オフ',
    wrapOn: '行を折り返す',
    copied: 'コピーしました',
    copy: 'コピー',
    copyBlocked: 'ブラウザがコピーを許可しませんでした。text を選択してコピーしてください。',
    alreadyRunning: '別の変換を実行中です。cancel してから次の file を選んでください。',
    stays: 'この端末内だけで処理',
    converting: (name) => `${name} を変換しています…`,
    binary: '（この writer は binary を出力しました。ダウンロードしてください）',
    complete: (ms) => `完了 · browser 内で ${ms} ms`,
    conversionFailed: '変換に失敗しました',
    noArtifact: 'artifact は作成されませんでした。',
    directions: '次にできること：',
    details: '詳細',
    engineTitle: 'ブラウザ用エンジンを起動できませんでした',
    engineBody: '変換は行われていません。page のほかの部分は利用できます。',
    reload: 'page を再読み込みしてください。一時的な browser error がよくある原因です。',
    conversionTitle: '変換を完了できませんでした',
    retry: 'page を再読み込みして、もう一度お試しください。',
  },
  ko: {
    searchFailed: '검색을 불러오지 못했습니다. 한국어 문서나 영어 ZDS는 그대로 볼 수 있습니다.',
    noMatches: '일치하는 문서 장이나 설계 기록이 없습니다.',
    ready: '준비되었습니다. 문서를 선택하세요.',
    exampleTitle: '# 첫 번째 변환',
    exampleBody: '이 문서는 브라우저에서 만들었습니다.',
    exampleLocal: '이 기기 밖으로 전송되지 않습니다.',
    exampleMarkdown: '결과는 plain Markdown으로 유지됩니다.',
    wrapOff: '줄 바꿈: 끄기',
    wrapOn: '줄 바꿈',
    copied: '복사했습니다',
    copy: '복사',
    copyBlocked: '브라우저가 복사를 막았습니다. text를 선택해 직접 복사해 주세요.',
    alreadyRunning: '다른 변환이 실행 중입니다. 먼저 취소한 뒤 새 파일을 선택하세요.',
    stays: '이 기기에만 보관',
    converting: (name) => `${name} 변환 중…`,
    binary: '(이 writer가 binary 결과를 만들었습니다. 다운로드를 사용하세요)',
    complete: (ms) => `완료 · 기기에서 ${ms} ms`,
    conversionFailed: '변환 실패',
    noArtifact: 'artifact를 만들지 못했습니다.',
    directions: '다음 방법을 시도해 보세요:',
    details: '세부 정보',
    engineTitle: '브라우저 엔진을 시작하지 못했습니다',
    engineBody: '변환하지 못했지만 페이지의 다른 부분은 계속 사용할 수 있습니다.',
    reload: '페이지를 새로고침하세요. 일시적인 브라우저 오류가 가장 흔한 원인입니다.',
    conversionTitle: '변환을 완료하지 못했습니다',
    retry: '페이지를 새로고침한 뒤 다시 시도하세요.',
  },
};

const messages = MESSAGES[locale] ?? MESSAGES.en;

// -- theme ------------------------------------------------------------

const THEME_KEY = 'zenfmt-theme';
const THEMES = ['light', 'dark', 'system'];

function applyTheme(theme) {
  root.classList.remove('theme-light', 'theme-dark', 'theme-system');
  root.classList.add(`theme-${theme}`);
}

function storedTheme() {
  try {
    const value = localStorage.getItem(THEME_KEY);
    return THEMES.includes(value) ? value : null;
  } catch {
    // A browser with storage disabled still gets a working site; it just
    // does not remember the choice.
    return null;
  }
}

// With no stored preference, follow the operating system. The page shell
// carries the same class so this is also the no-script and first-paint default.
let theme = storedTheme() ?? 'system';
applyTheme(theme);

const themeSelect = document.querySelector('[data-theme-select]');
if (themeSelect) themeSelect.value = theme;
themeSelect?.addEventListener('change', () => {
  theme = THEMES.includes(themeSelect.value) ? themeSelect.value : 'system';
  applyTheme(theme);
  try {
    localStorage.setItem(THEME_KEY, theme);
  } catch {
    /* Not remembering the choice is acceptable; failing to change it is not. */
  }
});

// -- language ---------------------------------------------------------

const LANGUAGE_KEY = 'zenfmt-language';
const languageSelect = document.querySelector('[data-language-select]');

languageSelect?.addEventListener('change', () => {
  const selected = languageSelect.selectedOptions[0]?.dataset.locale ?? 'en';
  try {
    localStorage.setItem(LANGUAGE_KEY, selected);
  } catch {
    /* Navigation still works when storage is unavailable. */
  }
  window.location.assign(languageSelect.value);
});

if (locale === 'en' && document.querySelector('[data-drop]')) {
  redirectFromBrowserLanguage();
}

function redirectFromBrowserLanguage() {
  let preferred = null;
  try {
    preferred = localStorage.getItem(LANGUAGE_KEY);
  } catch {
    /* Browser preference remains usable without storage. */
  }
  if (!preferred) {
    const languages = navigator.languages?.length ? navigator.languages : [navigator.language];
    preferred = languages.map(languageCode).find(Boolean) ?? 'en';
  }
  const option = languageSelect?.querySelector(`option[data-locale="${preferred}"]`);
  if (preferred !== 'en' && option) window.location.replace(option.value);
}

function languageCode(value) {
  const normalized = String(value ?? '').toLowerCase();
  if (normalized === 'ja' || normalized.startsWith('ja-')) return 'ja';
  if (normalized === 'ko' || normalized.startsWith('ko-')) return 'ko';
  if (normalized === 'zh' || normalized.startsWith('zh-cn') ||
      normalized.startsWith('zh-sg') || normalized.includes('hans')) return 'zh-Hans';
  return normalized === 'en' || normalized.startsWith('en-') ? 'en' : null;
}

// -- local documentation search --------------------------------------

const searchInput = document.querySelector('[data-search-input]');
const searchResults = document.querySelector('[data-search-results]');
const runtimeScript = document.querySelector('script[type="module"][data-search]');
if (searchInput && searchResults && runtimeScript) initSearch();

async function initSearch() {
  let index = null;
  const searchUrl = new URL(runtimeScript.dataset.search, document.baseURI);
  const siteRoot = new URL('../', searchUrl);

  searchInput.addEventListener('input', async () => {
    const query = searchInput.value.trim().toLocaleLowerCase();
    if (query.length < 2) {
      searchResults.hidden = true;
      searchResults.textContent = '';
      return;
    }
    try {
      index ??= await fetch(searchUrl).then((response) => {
        if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
        return response.json();
      });
    } catch {
      searchResults.textContent = messages.searchFailed;
      searchResults.hidden = false;
      return;
    }

    const terms = query.split(/\s+/).filter(Boolean);
    const matches = index
      .filter((entry) => terms.every((term) =>
        `${entry.title} ${entry.description} ${entry.text}`.toLocaleLowerCase().includes(term)))
      .slice(0, 8);
    searchResults.textContent = '';
    const list = document.createElement('ul');
    for (const entry of matches) {
      const item = document.createElement('li');
      const link = document.createElement('a');
      link.href = new URL(entry.route, siteRoot).href;
      link.textContent = entry.title;
      const detail = document.createElement('span');
      detail.textContent = entry.description;
      item.append(link, detail);
      list.append(item);
    }
    if (matches.length === 0) {
      const item = document.createElement('li');
      item.textContent = messages.noMatches;
      list.append(item);
    }
    searchResults.append(list);
    searchResults.hidden = false;
  });

  searchInput.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      searchInput.value = '';
      searchResults.hidden = true;
      searchResults.textContent = '';
    }
  });
}

// -- converter --------------------------------------------------------

const dropTarget = document.querySelector('[data-drop]');
if (dropTarget) {
  initConverter();
}

async function initConverter() {
  const script = document.querySelector('script[type="module"][data-adapter]');
  const input = document.querySelector('[data-source]');
  const status = document.querySelector('[data-status]');
  const output = document.querySelector('[data-output]');
  const reportsPanel = document.querySelector('[data-reports]');
  const copyButton = document.querySelector('[data-copy]');
  const downloadButton = document.querySelector('[data-download]');
  const wrapButton = document.querySelector('[data-wrap]');
  const cancelButton = document.querySelector('[data-cancel]');
  const resetButton = document.querySelector('[data-reset]');
  const exampleButton = document.querySelector('[data-example]');
  const fileMeta = document.querySelector('[data-file-meta]');
  const strict = document.querySelector('[data-strict]');
  const facets = document.querySelector('[data-facets]');

  let converter = null;
  let current = null;
  let activeController = null;

  const say = (text, state) => {
    status.textContent = text;
    if (state) status.dataset.state = state;
    else delete status.dataset.state;
  };

  dropTarget.addEventListener('dragover', (event) => {
    event.preventDefault();
    dropTarget.classList.add('is-over');
  });
  dropTarget.addEventListener('dragleave', () => dropTarget.classList.remove('is-over'));
  dropTarget.addEventListener('drop', (event) => {
    event.preventDefault();
    dropTarget.classList.remove('is-over');
    const file = event.dataTransfer?.files?.[0];
    if (file) convertFile(file);
  });
  input.addEventListener('change', () => {
    const file = input.files?.[0];
    if (file) convertFile(file);
  });

  exampleButton.addEventListener('click', () => {
    const sample = new File([
      `${messages.exampleTitle}\n\n${messages.exampleBody}\n\n` +
      `- ${messages.exampleLocal}\n- ${messages.exampleMarkdown}\n`,
    ], 'zenfmt-example.md', { type: 'text/markdown' });
    convertFile(sample);
  });

  wrapButton.addEventListener('click', () => {
    const wrapping = wrapButton.getAttribute('aria-pressed') !== 'false';
    wrapButton.setAttribute('aria-pressed', String(!wrapping));
    output.classList.toggle('output-nowrap', wrapping);
    wrapButton.textContent = wrapping ? messages.wrapOff : messages.wrapOn;
  });

  cancelButton.addEventListener('click', () => activeController?.abort());

  copyButton.addEventListener('click', async () => {
    if (!current) return;
    try {
      // Only ever after an explicit gesture, and focus is left where it was.
      await navigator.clipboard.writeText(current.text);
      copyButton.textContent = messages.copied;
      setTimeout(() => { copyButton.textContent = messages.copy; }, 2000);
    } catch {
      say(messages.copyBlocked, 'failed');
    }
  });

  downloadButton.addEventListener('click', () => {
    if (!current) return;
    const blob = new Blob([current.artifact], { type: 'text/markdown' });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = safeFilename(current.artifactName ?? 'document.md');
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    // Let the browser begin reading the URL before its document handle goes.
    setTimeout(() => URL.revokeObjectURL(url), 0);
  });

  resetButton.addEventListener('click', () => {
    current = null;
    output.textContent = '';
    reportsPanel.hidden = true;
    reportsPanel.textContent = '';
    input.value = '';
    fileMeta.hidden = true;
    fileMeta.textContent = '';
    setResultActions(false);
    say(messages.ready, 'ready');
    input.focus();
  });

  try {
    const moduleUrl = new URL(script.dataset.wasm, document.baseURI).href;
    const workerUrl = new URL(script.dataset.worker, document.baseURI).href;
    const { createWorkerConverter } = await import(
      new URL(script.dataset.adapter, document.baseURI).href
    );
    converter = await createWorkerConverter({ moduleUrl, workerUrl });
    window.addEventListener('pagehide', () => converter.dispose(), { once: true });
    say(messages.ready, 'ready');
  } catch (error) {
    // A failure here changes the converter panel and nothing else.
    say(describe(error), 'failed');
    return;
  }

  async function convertFile(file) {
    if (activeController) {
      say(messages.alreadyRunning, 'failed');
      input.value = '';
      return;
    }
    activeController = new AbortController();
    fileMeta.textContent = `${file.name} · ${formatBytes(file.size)} · ${messages.stays}`;
    fileMeta.hidden = false;
    say(messages.converting(file.name), 'converting');
    setResultActions(false);
    cancelButton.hidden = false;
    reportsPanel.hidden = true;
    try {
      current = await converter.convert(file, {
        artifactName: markdownFilename(file.name),
        strict: strict.value,
        preserveFacets: facets.checked,
        signal: activeController.signal,
        timeoutMs: 30000,
      });
      output.textContent = current.isText
        ? current.text
        : messages.binary;
      renderReports(current.reports);
      setResultActions(true);
      say(messages.complete(Math.round(current.elapsedMs)), 'complete');
    } catch (error) {
      current = null;
      output.textContent = '';
      renderReports(error?.reports?.length ? error.reports : [{
        severity: 'error',
        title: error?.code ?? messages.conversionFailed,
        code: error?.code ?? 'browser.conversion-failed',
        exit_class: error?.exitClass ?? 'conversion',
        problem: error?.problem ?? describe(error),
        consequence: error?.consequence ?? messages.noArtifact,
        directions: error?.directions ?? [],
      }]);
      say(describe(error), 'failed');
      resetButton.disabled = false;
    } finally {
      activeController = null;
      cancelButton.hidden = true;
    }
  }

  function setResultActions(enabled) {
    for (const button of [copyButton, downloadButton, resetButton]) {
      button.disabled = !enabled;
    }
  }

  function renderReports(reports) {
    reportsPanel.textContent = '';
    if (!reports || reports.length === 0) {
      reportsPanel.hidden = true;
      return;
    }
    for (const report of reports) {
      const item = document.createElement('div');
      item.className = 'report';
      item.dataset.severity = report.severity;

      const kind = document.createElement('p');
      kind.className = 'report-kind';
      // The severity is stated in words, not only in the border colour.
      kind.textContent = `${report.severity}: ${report.title ?? report.code}`.toUpperCase();
      item.append(kind);

      for (const text of [report.problem, report.consequence]) {
        if (!text) continue;
        const paragraph = document.createElement('p');
        paragraph.textContent = text;
        item.append(paragraph);
      }

      if (report.directions?.length) {
        const heading = document.createElement('p');
        heading.textContent = messages.directions;
        item.append(heading);
        const list = document.createElement('ul');
        for (const direction of report.directions) {
          const entry = document.createElement('li');
          entry.textContent = `${direction.title}: ${direction.explanation}`;
          list.append(entry);
        }
        item.append(list);
      }
      const details = document.createElement('details');
      const summary = document.createElement('summary');
      summary.textContent = messages.details;
      const code = document.createElement('code');
      code.textContent = `${report.code} · ${report.exit_class ?? 'conversion'}`;
      details.append(summary, code);
      item.append(details);
      reportsPanel.append(item);
    }
    reportsPanel.hidden = false;
  }
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}

function describe(error) {
  if (error && typeof error.message === 'string' && error.code) return error.message;
  if (error && typeof error.message === 'string' && error.message) {
    return `${messages.engineTitle}\n` +
      `${messages.engineBody}\n` +
      `${messages.directions}\n` +
      `  ${messages.reload}\n` +
      `${messages.details}: ${error.message}`;
  }
  return `${messages.conversionTitle}\n${messages.engineBody}\n` +
    `${messages.directions}\n  ${messages.retry}`;
}

/// Strips anything that would make a download land somewhere unexpected or
/// read as a different name than it is.
function safeFilename(name) {
  return name
    .replace(/[\x00-\x1f\x7f‪-‮]/g, '')
    .replace(/[/\\]/g, '-')
    .slice(0, 200) || 'document.md';
}

/// Mirrors the CLI and server convention: `report.docx` becomes `report.md`.
function markdownFilename(name) {
  const basename = name.split(/[/\\]/).at(-1) ?? '';
  const extension = basename.lastIndexOf('.');
  const stem = extension > 0 ? basename.slice(0, extension) : basename;
  return safeFilename(`${stem || 'document'}.md`);
}
