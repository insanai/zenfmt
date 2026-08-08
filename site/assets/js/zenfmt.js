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
  return new Converter(compiled);
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
          explanation: 'createConverter resolves before the module is instantiated; ' +
            'await converter.ready() or await a convert() call.',
        }],
      });
    }
  }
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
    return { name: requireName(explicitName), data: source };
  }
  if (source instanceof ArrayBuffer) {
    return { name: requireName(explicitName), data: new Uint8Array(source) };
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
