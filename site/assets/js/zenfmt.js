// The zenfmt browser adapter (ZDS 0015, Public Browser API and Worker Model).
//
// A standards-based ES module with no build step, no bundler, and no
// dependencies. It loads an explicit WebAssembly module URL — there is no
// implicit CDN, no global, and no network conversion fallback — and converts
// documents entirely inside the visitor's browser.
//
// One rule governs everything here, and it is the rule most WebAssembly
// adapters get wrong:
//
//   Never hold a typed-array view across a call into the module.
//
// Any allocation can grow linear memory, and growing it detaches every view
// over the old buffer. A view captured before a call and used after it is
// either empty or pointing at nothing. So this file has exactly one accessor,
// `bytes()`, and it is called immediately before each read or write.

const ABI_VERSION = 0x0001_0000;
const PACKAGE_VERSION = '0.3.0';

const STATUS_SUCCESS = 0;
const STATUS_FAILED = 1;
const STATUS_INVALID_REQUEST = 2;
const STATUS_INVALID_HANDLE = 3;

const VIEW_ARTIFACT = 0;
const VIEW_ARTIFACT_NAME = 1;
const VIEW_SOURCE_FORMAT = 2;
const VIEW_OUTPUT_FORMAT = 3;
const VIEW_REPORTS_JSON = 4;
const VIEW_MANIFEST_JSON = 5;
const VIEW_RESOURCE_REL_PATH = 6;
const VIEW_RESOURCE_BYTES = 7;
const VIEW_RESOURCE_DIGEST_HEX = 8;

const REQUEST_SCHEMA = 1;
let workerUrlPolicy = null;

/// A failure a caller can act on: a stable code, the engine's structured
/// reports when there are any, and directions phrased as things to do rather
/// than facts about what went wrong.
export class ZenfmtError extends Error {
  constructor({ code, exitClass, problem, consequence, directions, reports, cause }) {
    super(renderMessage({ code, problem, consequence, directions }));
    this.name = 'ZenfmtError';
    this.code = code;
    this.exitClass = exitClass ?? 'usage';
    this.problem = problem ?? '';
    this.consequence = consequence ?? '';
    this.directions = Object.freeze(directions ?? []);
    this.reports = Object.freeze(reports ?? []);
    if (cause !== undefined) this.cause = cause;
    Object.freeze(this);
  }
}

function renderMessage({ code, problem, consequence, directions }) {
  const lines = [problem ?? code];
  if (consequence) lines.push(consequence);
  if (directions && directions.length > 0) {
    lines.push('What you can do:');
    for (const direction of directions) {
      lines.push(`  ${direction.title}: ${direction.explanation}`);
    }
  }
  return lines.join('\n');
}

/// The engine's own reports carry everything a message needs, so a failure
/// that came from the engine is rendered from its first error rather than
/// re-described here in words that could drift from it.
function errorFromReports(reports, fallbackCode, exitClass) {
  const failure = reports.find((report) => report.severity === 'error');
  if (!failure) {
    return new ZenfmtError({
      code: fallbackCode,
      exitClass,
      problem: 'The conversion did not succeed.',
      reports,
    });
  }
  return new ZenfmtError({
    code: failure.code,
    exitClass: failure.exit_class ?? exitClass,
    problem: failure.problem,
    consequence: failure.consequence,
    directions: failure.directions ?? [],
    reports,
  });
}

/// One conversion's complete result. Everything is frozen and every byte
/// array is this object's own copy, so nothing here can change underneath a
/// caller when the next conversion grows the module's memory.
export class Conversion {
  constructor(fields) {
    Object.assign(this, fields);
    Object.freeze(this);
  }

  /// The artifact decoded as text. Only meaningful for a writer that emits
  /// text, which is why it throws rather than returning mojibake for one that
  /// does not.
  get text() {
    if (!this.isText) {
      throw new ZenfmtError({
        code: 'browser.binary-artifact',
        problem: `The ${this.outputFormat} writer emits binary, not text.`,
        consequence: 'No text was decoded.',
        directions: [{
          title: 'Use the artifact bytes',
          explanation: 'Read `artifact`, which holds the exact bytes the writer produced.',
        }],
      });
    }
    return new TextDecoder('utf-8', { fatal: true }).decode(this.artifact);
  }
}

/// Loads a module and returns a converter. `moduleUrl` is required and
/// explicit: an adapter that guessed a URL would be an adapter that could
/// silently load a different build than the page was tested against.
export async function createConverter({ moduleUrl, signal } = {}) {
  if (!moduleUrl) {
    throw new ZenfmtError({
      code: 'browser.missing-module-url',
      problem: 'createConverter needs the URL of the WebAssembly module.',
      consequence: 'No converter was created.',
      directions: [{
        title: 'Pass the module URL',
        explanation: 'Serve zenfmt.wasm from your own origin and pass its URL, ' +
          'so the page always loads the build it was tested with.',
      }],
    });
  }

  const compiled = await compile(moduleUrl);
  signal?.throwIfAborted();
  const converter = new Converter(compiled);
  await converter.ready();
  return converter;
}

/// Creates the worker-backed converter used by the project site. The module
/// is compiled once on the page and cloned into replaceable workers, so an
/// abort or timeout can stop synchronous parsing without another fetch or
/// compilation.
export async function createWorkerConverter({ moduleUrl, workerUrl, signal } = {}) {
  if (!workerUrl) {
    throw new ZenfmtError({
      code: 'browser.missing-worker-url',
      problem: 'createWorkerConverter needs the URL of zenfmt.worker.js.',
      consequence: 'No conversion worker was created.',
      directions: [{
        title: 'Pass the worker URL',
        explanation: 'Serve zenfmt.worker.js beside the adapter and pass its explicit URL.',
      }],
    });
  }
  if (!moduleUrl) {
    throw new ZenfmtError({
      code: 'browser.missing-module-url',
      problem: 'createWorkerConverter needs the URL of the WebAssembly module.',
      consequence: 'No conversion worker was created.',
      directions: [{
        title: 'Pass the module URL',
        explanation: 'Serve zenfmt.wasm from your own origin and pass its explicit URL.',
      }],
    });
  }
  const compiled = await compile(moduleUrl);
  signal?.throwIfAborted();
  const converter = new WorkerConverter(compiled, workerUrl);
  await converter.ready();
  return converter;
}

async function compile(moduleUrl) {
  try {
    // Streaming compilation needs the correct media type. A static host that
    // serves the module as something else is a configuration mistake worth
    // recovering from rather than failing on, so fall back to a buffer.
    return await WebAssembly.compileStreaming(fetch(moduleUrl));
  } catch (streamingCause) {
    try {
      const response = await fetch(moduleUrl);
      if (!response.ok) {
        throw new Error(`${response.status} ${response.statusText}`);
      }
      return await WebAssembly.compile(await response.arrayBuffer());
    } catch (cause) {
      throw new ZenfmtError({
        code: 'browser.module-load-failed',
        problem: `The zenfmt engine could not be loaded from ${moduleUrl}.`,
        consequence: 'Nothing was converted. The rest of this page still works.',
        directions: [
          {
            title: 'Reload the page',
            explanation: 'A network interruption during loading is the most common cause.',
          },
          {
            title: 'Use the command-line tool or the Python library',
            explanation: 'Both convert the same documents without a browser.',
          },
        ],
        cause: cause ?? streamingCause,
      });
    }
  }
}

/// A loaded engine. One instance converts one document at a time, which is
/// what a single worker is for; a page that wants concurrency creates more
/// converters rather than sharing one.
export class Converter {
  #module;
  #instance = null;
  #exports = null;
  #capabilities = null;
  #disposed = false;

  constructor(compiledModule) {
    this.#module = compiledModule;
  }

  /// The compiled module, so a worker can be handed it without refetching or
  /// recompiling. This is what makes terminate-on-cancel affordable.
  get compiledModule() {
    return this.#module;
  }

  async ready() {
    if (this.#instance) return this;
    this.#assertLive();
    this.#instance = await WebAssembly.instantiate(this.#module, {});
    this.#exports = this.#instance.exports;

    const abi = this.#exports.zenfmt_abi_version();
    if ((abi & 0xffff0000) !== (ABI_VERSION & 0xffff0000)) {
      throw new ZenfmtError({
        code: 'browser.abi-mismatch',
        problem: `This adapter speaks ABI ${describeAbi(ABI_VERSION)}, but the ` +
          `module speaks ${describeAbi(abi)}.`,
        consequence: 'Nothing was converted, because the two would not agree ' +
          'about what the results mean.',
        directions: [{
          title: 'Serve matching adapter and module files',
          explanation: 'zenfmt.js and zenfmt.wasm come from one release and are ' +
            'versioned together; deploy both from the same archive.',
        }],
      });
    }

    this.#capabilities = Object.freeze(JSON.parse(this.#readGlobal(
      this.#exports.zenfmt_capabilities_ptr(),
      this.#exports.zenfmt_capabilities_len(),
    )));
    const moduleVersion = this.version;
    if (moduleVersion !== PACKAGE_VERSION || this.#capabilities.version !== PACKAGE_VERSION) {
      throw new ZenfmtError({
        code: 'browser.version-mismatch',
        problem: `This adapter is zenfmt ${PACKAGE_VERSION}, but the module is ` +
          `zenfmt ${moduleVersion}.`,
        consequence: 'Nothing was converted, because mixed release files are unsafe to combine.',
        directions: [{
          title: 'Serve one complete release',
          explanation: 'Replace zenfmt.js, zenfmt.worker.js, and zenfmt.wasm together ' +
            'from the same versioned archive.',
        }],
      });
    }
    return this;
  }

  get capabilities() {
    this.#assertReady();
    return this.#capabilities;
  }

  get version() {
    this.#assertReady();
    return this.#readGlobal(
      this.#exports.zenfmt_version_ptr(),
      this.#exports.zenfmt_version_len(),
    );
  }

  /// Current and peak linear memory, in pages. A host uses the peak to decide
  /// when to replace this converter: WebAssembly memory never shrinks, so the
  /// only way to give it back is to discard the instance.
  get memory() {
    this.#assertReady();
    return Object.freeze({
      pages: this.#exports.zenfmt_memory_pages(),
      highWaterPages: this.#exports.zenfmt_high_water_pages(),
      liveBytes: this.#exports.zenfmt_live_bytes(),
      liveResults: this.#exports.zenfmt_live_results(),
    });
  }

  async convert(source, options = {}) {
    this.#assertLive();
    await this.ready();

    const { name, data } = await readSource(source, options.name);
    const request = JSON.stringify(buildRequest(name, options));

    const started = performance.now();
    const requestPtr = this.#upload(new TextEncoder().encode(request));
    const inputPtr = this.#upload(data);
    let handle = 0;
    try {
      handle = this.#exports.zenfmt_convert(
        requestPtr,
        new TextEncoder().encode(request).length,
        inputPtr,
        data.length,
      );
      if (handle === 0) throw outOfMemory();
      return this.#readResult(handle, performance.now() - started);
    } finally {
      // Freed in a finally so a throw between here and there cannot leak the
      // document's bytes into a module that outlives the failure.
      if (handle !== 0) this.#exports.zenfmt_result_free(handle);
      this.#exports.zenfmt_free(inputPtr);
      this.#exports.zenfmt_free(requestPtr);
    }
  }

  dispose() {
    this.#disposed = true;
    this.#instance = null;
    this.#exports = null;
    this.#capabilities = null;
  }

  get disposed() {
    return this.#disposed;
  }

  // A fresh view every time, because the previous one may have been detached
  // by any allocation since.
  #bytes() {
    return new Uint8Array(this.#exports.memory.buffer);
  }

  #upload(source) {
    const ptr = this.#exports.zenfmt_alloc(source.length);
    if (ptr === 0 && source.length !== 0) throw outOfMemory();
    if (source.length !== 0) this.#bytes().set(source, ptr);
    return ptr;
  }

  #readGlobal(ptr, len) {
    return new TextDecoder('utf-8', { fatal: true })
      .decode(this.#bytes().slice(ptr, ptr + len));
  }

  #view(handle, view, index = 0) {
    const ptr = this.#exports.zenfmt_result_view_ptr(handle, view, index);
    if (ptr === 0) return null;
    const len = this.#exports.zenfmt_result_view_len(handle, view, index);
    // `slice`, never `subarray`: a subarray would alias linear memory and go
    // stale — or silently change — the next time the module allocates.
    return this.#bytes().slice(ptr, ptr + len);
  }

  #text(handle, view, index = 0) {
    const bytes = this.#view(handle, view, index);
    if (bytes === null) return null;
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  }

  #readResult(handle, elapsedMs) {
    const status = this.#exports.zenfmt_result_status(handle);
    if (status === STATUS_INVALID_HANDLE) throw outOfMemory();

    const reportsText = this.#text(handle, VIEW_REPORTS_JSON) ?? '[]';
    const reports = Object.freeze(JSON.parse(reportsText));
    const exitClass = ['conversion', 'usage', 'limit'][
      this.#exports.zenfmt_result_exit_class(handle)
    ] ?? 'conversion';

    if (status !== STATUS_SUCCESS) {
      throw errorFromReports(
        reports,
        status === STATUS_INVALID_REQUEST
          ? 'browser.malformed-request'
          : 'browser.conversion-failed',
        exitClass,
      );
    }

    const outputFormat = this.#text(handle, VIEW_OUTPUT_FORMAT);
    const manifestText = this.#text(handle, VIEW_MANIFEST_JSON);

    const resources = [];
    const count = this.#exports.zenfmt_result_resource_count(handle);
    for (let index = 0; index < count; index += 1) {
      resources.push(Object.freeze({
        path: this.#text(handle, VIEW_RESOURCE_REL_PATH, index),
        bytes: this.#view(handle, VIEW_RESOURCE_BYTES, index),
        digest: this.#text(handle, VIEW_RESOURCE_DIGEST_HEX, index),
      }));
    }

    return new Conversion({
      artifact: this.#view(handle, VIEW_ARTIFACT) ?? new Uint8Array(0),
      artifactName: this.#text(handle, VIEW_ARTIFACT_NAME),
      sourceFormat: this.#text(handle, VIEW_SOURCE_FORMAT),
      outputFormat,
      isText: this.#isTextWriter(outputFormat),
      reports,
      manifest: manifestText === null ? null : Object.freeze(JSON.parse(manifestText)),
      resources: Object.freeze(resources),
      elapsedMs,
    });
  }

  #isTextWriter(format) {
    const entry = this.#capabilities?.formats?.find((f) => f.format === format);
    return entry?.text_writer === true;
  }

  #assertLive() {
    if (this.#disposed) {
      throw new ZenfmtError({
        code: 'browser.disposed',
        problem: 'This converter was disposed.',
        consequence: 'Nothing was converted.',
        directions: [{
          title: 'Create a new converter',
          explanation: 'A disposed converter is not reusable; call createConverter again.',
        }],
      });
    }
  }

  #assertReady() {
    this.#assertLive();
    if (!this.#exports) {
      throw new ZenfmtError({
        code: 'browser.not-ready',
        problem: 'The converter has not finished loading.',
        consequence: 'Nothing was read.',
        directions: [{
          title: 'Await ready() first',
          explanation: 'Await converter.ready() before reading its identity or capabilities.',
        }],
      });
    }
  }
}

/// A dedicated-worker host with the same result model as Converter. Its
/// convert options additionally accept `signal` and `timeoutMs`; neither is
/// sent into the engine request. Stopping a conversion terminates the worker,
/// then starts a fresh instance from the already-compiled module.
export class WorkerConverter {
  #module;
  #workerUrl;
  #worker = null;
  #readyPromise = null;
  #pending = new Map();
  #nextId = 1;
  #disposed = false;
  #capabilities = null;
  #version = null;
  #memory = null;
  #conversions = 0;

  constructor(compiledModule, workerUrl) {
    this.#module = compiledModule;
    this.#workerUrl = workerUrl;
    this.#readyPromise = this.#start();
  }

  async ready() {
    this.#assertLive();
    await this.#readyPromise;
    return this;
  }

  get capabilities() {
    this.#assertReady();
    return this.#capabilities;
  }

  get version() {
    this.#assertReady();
    return this.#version;
  }

  get memory() {
    this.#assertReady();
    return this.#memory;
  }

  get disposed() {
    return this.#disposed;
  }

  async convert(source, options = {}) {
    this.#assertLive();
    await this.ready();

    const { signal, timeoutMs = 0, ...engineOptions } = options;
    const { name, data } = await readSource(source, engineOptions.name);
    const input = data;
    const requestOptions = { ...engineOptions, name };

    let timedOut = false;
    const controller = new AbortController();
    const abortFromCaller = () => controller.abort();
    signal?.addEventListener('abort', abortFromCaller, { once: true });
    const timer = timeoutMs > 0 ? setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, timeoutMs) : null;

    try {
      const message = await this.#request(
        'convert',
        { data: input, options: requestOptions },
        [input.buffer],
        controller.signal,
      );
      this.#memory = Object.freeze(message.memory);
      this.#conversions += 1;
      const conversion = conversionFromWorker(message.result);
      // Linear memory cannot shrink. Recycle at 512 MiB, or periodically so
      // long-lived pages return allocator pages even after small documents.
      if (this.#memory.highWaterPages >= 8192 || this.#conversions >= 25) {
        await this.#replace();
      }
      return conversion;
    } catch (error) {
      if (timedOut) throw timedOutError(timeoutMs);
      if (signal?.aborted) throw canceledError();
      throw error;
    } finally {
      signal?.removeEventListener('abort', abortFromCaller);
      if (timer !== null) clearTimeout(timer);
    }
  }

  dispose() {
    if (this.#disposed) return;
    this.#disposed = true;
    this.#worker?.terminate();
    this.#worker = null;
    this.#rejectPending(disposedError());
    this.#capabilities = null;
    this.#version = null;
    this.#memory = null;
  }

  async #start() {
    this.#assertLive();
    const worker = new Worker(trustedWorkerUrl(this.#workerUrl), {
      type: 'module',
      name: 'zenfmt',
    });
    this.#worker = worker;
    worker.addEventListener('message', (event) => this.#receive(worker, event.data));
    worker.addEventListener('error', () => this.#workerFailed(worker));
    const message = await this.#request('init', { module: this.#module });
    this.#capabilities = deepFreeze(message.capabilities);
    this.#version = message.version;
    this.#memory = Object.freeze({
      pages: 0,
      highWaterPages: 0,
      liveBytes: 0,
      liveResults: 0,
    });
    this.#conversions = 0;
  }

  #request(kind, fields, transfer = [], signal = null) {
    this.#assertLive();
    const id = this.#nextId;
    this.#nextId += 1;
    return new Promise((resolve, reject) => {
      const abort = () => {
        if (!this.#pending.delete(id)) return;
        reject(canceledError());
        this.#replace().catch(() => {});
      };
      if (signal?.aborted) {
        reject(canceledError());
        this.#replace().catch(() => {});
        return;
      }
      this.#pending.set(id, { resolve, reject, signal, abort });
      signal?.addEventListener('abort', abort, { once: true });
      this.#worker.postMessage({ kind, id, ...fields }, transfer);
    });
  }

  #receive(worker, message) {
    if (worker !== this.#worker) return;
    const pending = this.#pending.get(message.id);
    if (!pending) return;
    this.#pending.delete(message.id);
    pending.signal?.removeEventListener('abort', pending.abort);
    if (message.kind === 'error') pending.reject(errorFromWorker(message.error));
    else pending.resolve(message);
  }

  #workerFailed(worker) {
    if (worker !== this.#worker || this.#disposed) return;
    const wasReady = this.#capabilities !== null;
    const error = new ZenfmtError({
      code: 'browser.worker-failed',
      problem: 'The conversion worker stopped unexpectedly.',
      consequence: 'The current conversion did not produce an artifact.',
      directions: [{
        title: 'Try the document again',
        explanation: 'The worker has been replaced with a clean instance.',
      }],
    });
    this.#rejectPending(error);
    this.#worker?.terminate();
    this.#worker = null;
    if (wasReady) this.#replace().catch(() => {});
  }

  async #replace() {
    if (this.#disposed) return;
    this.#worker?.terminate();
    this.#worker = null;
    this.#rejectPending(canceledError());
    this.#capabilities = null;
    this.#version = null;
    this.#memory = null;
    this.#readyPromise = this.#start();
    await this.#readyPromise;
  }

  #rejectPending(error) {
    for (const pending of this.#pending.values()) {
      pending.signal?.removeEventListener('abort', pending.abort);
      pending.reject(error);
    }
    this.#pending.clear();
  }

  #assertLive() {
    if (this.#disposed) throw disposedError();
  }

  #assertReady() {
    this.#assertLive();
    if (!this.#capabilities) {
      throw new ZenfmtError({
        code: 'browser.not-ready',
        problem: 'The conversion worker has not finished loading.',
        consequence: 'Nothing was read.',
        directions: [{
          title: 'Await ready() first',
          explanation: 'Wait for the worker to validate and instantiate the module.',
        }],
      });
    }
  }
}

function trustedWorkerUrl(value) {
  const url = new URL(value, globalThis.location?.href);
  if (globalThis.location && url.origin !== globalThis.location.origin) {
    throw new ZenfmtError({
      code: 'browser.cross-origin-worker',
      problem: 'The conversion worker URL is not on this page\'s origin.',
      consequence: 'No worker was started.',
      directions: [{
        title: 'Serve the distribution together',
        explanation: 'Keep zenfmt.js, zenfmt.worker.js, and zenfmt.wasm on one origin.',
      }],
    });
  }
  if (!globalThis.trustedTypes) return url.href;
  workerUrlPolicy ??= globalThis.trustedTypes.createPolicy('zenfmt-worker', {
    createScriptURL: (candidate) => candidate,
  });
  return workerUrlPolicy.createScriptURL(url.href);
}

function conversionFromWorker(result) {
  const resources = Object.freeze(result.resources.map((resource) => Object.freeze({
    path: resource.path,
    bytes: resource.bytes,
    digest: resource.digest,
  })));
  return new Conversion({
    ...result,
    reports: deepFreeze(result.reports),
    manifest: deepFreeze(result.manifest),
    resources,
  });
}

function errorFromWorker(error) {
  return new ZenfmtError({
    code: error.code,
    exitClass: error.exitClass,
    problem: error.problem,
    consequence: error.consequence,
    directions: deepFreeze(error.directions ?? []),
    reports: deepFreeze(error.reports ?? []),
  });
}

function deepFreeze(value) {
  if (value === null || typeof value !== 'object' || ArrayBuffer.isView(value)) return value;
  for (const item of Object.values(value)) deepFreeze(item);
  return Object.freeze(value);
}

function canceledError() {
  return new ZenfmtError({
    code: 'browser.canceled',
    problem: 'The conversion was canceled.',
    consequence: 'No artifact was produced, and the document bytes were discarded.',
    directions: [{
      title: 'Choose the document again',
      explanation: 'A clean worker is ready for another conversion.',
    }],
  });
}

function timedOutError(timeoutMs) {
  return new ZenfmtError({
    code: 'browser.timed-out',
    exitClass: 'limit',
    problem: `The conversion did not finish within ${Math.round(timeoutMs / 1000)} seconds.`,
    consequence: 'The worker was stopped and no artifact was produced.',
    directions: [{
      title: 'Use the command-line tool for this document',
      explanation: 'It runs outside a browser and is intended for larger or slower work.',
    }],
  });
}

function disposedError() {
  return new ZenfmtError({
    code: 'browser.disposed',
    problem: 'This converter was disposed.',
    consequence: 'Nothing was converted.',
    directions: [{
      title: 'Create a new converter',
      explanation: 'A disposed converter is not reusable.',
    }],
  });
}

function describeAbi(value) {
  return `${value >>> 16}.${value & 0xffff}`;
}

function outOfMemory() {
  return new ZenfmtError({
    code: 'browser.out-of-memory',
    exitClass: 'limit',
    problem: 'The browser engine ran out of memory for this document.',
    consequence: 'The conversion stopped. The page was not affected.',
    directions: [{
      title: 'Use the command-line tool for this document',
      explanation: 'It converts the same document with the engine\'s full limits.',
    }],
  });
}

function buildRequest(name, options) {
  const request = { schema: REQUEST_SCHEMA, name };
  if (options.artifactName) request.artifact_name = options.artifactName;
  if (options.from) request.from = options.from;
  if (options.to) request.to = options.to;
  if (options.strict) request.strict = options.strict;
  if (options.preserveFacets) request.preserve_facets = true;
  if (options.limits) request.limits = options.limits;
  return request;
}

/// Normalizes what a page can hand us into bytes plus a name. A `File` knows
/// its own name; anything else needs one, because the name is what detection
/// falls back to and what the output is named after.
export async function readSource(source, explicitName) {
  if (source instanceof Uint8Array) {
    return { name: requireName(explicitName), data: copyBytes(source) };
  }
  if (source instanceof ArrayBuffer) {
    return { name: requireName(explicitName), data: copyBuffer(source) };
  }
  if (typeof Blob !== 'undefined' && source instanceof Blob) {
    const name = source.name ?? explicitName;
    const buffer = await source.arrayBuffer();
    return { name: requireName(name), data: new Uint8Array(buffer) };
  }
  throw new ZenfmtError({
    code: 'browser.unsupported-source',
    problem: 'convert() accepts a File, a Blob, an ArrayBuffer, or a Uint8Array.',
    consequence: 'Nothing was converted.',
    directions: [{
      title: 'Pass the file itself',
      explanation: 'The File from an <input type="file"> or a drop event works directly.',
    }],
  });
}

function copyBytes(source) {
  try {
    return source.slice();
  } catch (cause) {
    throw detachedInput(cause);
  }
}

function copyBuffer(source) {
  try {
    return new Uint8Array(source.slice(0));
  } catch (cause) {
    throw detachedInput(cause);
  }
}

function detachedInput(cause) {
  return new ZenfmtError({
    code: 'browser.detached-input',
    problem: 'The input byte buffer has already been transferred or detached.',
    consequence: 'Nothing was converted, because its bytes are no longer readable.',
    directions: [{
      title: 'Pass an owned copy',
      explanation: 'Create a new Uint8Array before transferring the original buffer.',
    }],
    cause,
  });
}

function requireName(name) {
  if (typeof name === 'string' && name.length > 0) return name;
  throw new ZenfmtError({
    code: 'browser.missing-source-name',
    problem: 'Byte input needs a source name.',
    consequence: 'Nothing was converted, because the name is used to detect the ' +
      'format and to name the output.',
    directions: [{
      title: 'Pass a name',
      explanation: 'Give convert() a { name: "report.docx" } option. A File ' +
        'supplies its own name and needs no option.',
    }],
  });
}

export const abi = Object.freeze({
  version: ABI_VERSION,
  statusSuccess: STATUS_SUCCESS,
  statusFailed: STATUS_FAILED,
  statusInvalidRequest: STATUS_INVALID_REQUEST,
  statusInvalidHandle: STATUS_INVALID_HANDLE,
  requestSchema: REQUEST_SCHEMA,
});

export const version = PACKAGE_VERSION;
