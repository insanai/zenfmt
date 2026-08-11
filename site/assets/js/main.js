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
      searchResults.textContent = 'Search could not be loaded. Browse the Book or ZDS instead.';
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
      item.textContent = 'No matching Book chapter or design record.';
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
      '# A first conversion\n\nThis document was created in your browser.\n\n' +
      '- It never leaves this device.\n- The output remains plain Markdown.\n',
    ], 'zenfmt-example.md', { type: 'text/markdown' });
    convertFile(sample);
  });

  wrapButton.addEventListener('click', () => {
    const wrapping = wrapButton.getAttribute('aria-pressed') !== 'false';
    wrapButton.setAttribute('aria-pressed', String(!wrapping));
    output.classList.toggle('output-nowrap', wrapping);
    wrapButton.textContent = wrapping ? 'Wrap lines: off' : 'Wrap lines';
  });

  cancelButton.addEventListener('click', () => activeController?.abort());

  copyButton.addEventListener('click', async () => {
    if (!current) return;
    try {
      // Only ever after an explicit gesture, and focus is left where it was.
      await navigator.clipboard.writeText(current.text);
      copyButton.textContent = 'Copied';
      setTimeout(() => { copyButton.textContent = 'Copy'; }, 2000);
    } catch {
      say('Copying was blocked by the browser. Select the text and copy it.', 'failed');
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
    say('Ready. Choose a document.', 'ready');
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
    say('Ready. Choose a document.', 'ready');
  } catch (error) {
    // A failure here changes the converter panel and nothing else.
    say(describe(error), 'failed');
    return;
  }

  async function convertFile(file) {
    if (activeController) {
      say('A conversion is already running. Cancel it before choosing another file.', 'failed');
      input.value = '';
      return;
    }
    activeController = new AbortController();
    fileMeta.textContent = `${file.name} · ${formatBytes(file.size)} · stays on this device`;
    fileMeta.hidden = false;
    say(`Converting ${file.name}…`, 'converting');
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
        : '(this writer produced binary output; use Download)';
      renderReports(current.reports);
      setResultActions(true);
      say(`Ready · converted locally in ${Math.round(current.elapsedMs)} ms`, 'complete');
    } catch (error) {
      current = null;
      output.textContent = '';
      renderReports(error?.reports?.length ? error.reports : [{
        severity: 'error',
        title: error?.code ?? 'Conversion failed',
        code: error?.code ?? 'browser.conversion-failed',
        exit_class: error?.exitClass ?? 'conversion',
        problem: error?.problem ?? describe(error),
        consequence: error?.consequence ?? 'No artifact was produced.',
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
        heading.textContent = 'What you can do:';
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
      summary.textContent = 'Details';
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
    return 'THE BROWSER ENGINE COULD NOT START\n' +
      'Nothing was converted. The rest of this page still works.\n' +
      'What you can do:\n' +
      '  Reload the page: A temporary browser failure is the most common cause.\n' +
      `Details: ${error.message}`;
  }
  return 'THE CONVERSION COULD NOT BE COMPLETED\nNothing was converted.\n' +
    'What you can do:\n  Reload the page and try again.';
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
