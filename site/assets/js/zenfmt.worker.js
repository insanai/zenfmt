// The zenfmt conversion worker (ZDS 0015, Public Browser API and Worker
// Model).
//
// Conversion is synchronous inside the module: once a document is being
// parsed, nothing can interrupt it from inside. Running it on the page's own
// thread would therefore mean a hostile or merely large document can freeze
// scrolling, typing, and assistive technology for as long as it takes.
//
// So conversion happens here, and cancellation is `worker.terminate()`. That
// is the only interruption WebAssembly actually offers, and it is why the
// page compiles the module once and sends the compiled module across: a
// replacement worker then costs a message rather than a refetch and a
// recompile, which is what makes terminating affordable enough to be the
// normal path rather than a last resort.

import { Converter, ZenfmtError } from './zenfmt.js';

let converter = null;

self.onmessage = async (event) => {
  const message = event.data;
  try {
    switch (message.kind) {
      case 'init':
        await handleInit(message);
        break;
      case 'convert':
        await handleConvert(message);
        break;
      default:
        post({ kind: 'error', id: message.id, error: describe(new ZenfmtError({
          code: 'browser.unknown-message',
          problem: `The worker received an unknown message kind: ${message.kind}.`,
          consequence: 'Nothing was done.',
          directions: [{
            title: 'Use the published adapter',
            explanation: 'zenfmt.js speaks this worker\'s protocol; it is not a public API.',
          }],
        })) });
    }
  } catch (error) {
    post({ kind: 'error', id: message.id, error: describe(error) });
  }
};

async function handleInit(message) {
  converter = new Converter(message.module);
  await converter.ready();
  post({
    kind: 'ready',
    id: message.id,
    capabilities: converter.capabilities,
    version: converter.version,
  });
}

async function handleConvert(message) {
  if (!converter) {
    throw new ZenfmtError({
      code: 'browser.not-ready',
      problem: 'The worker was asked to convert before it was initialized.',
      consequence: 'Nothing was converted.',
      directions: [{
        title: 'Send init first',
        explanation: 'The adapter does this; a page should not drive the worker directly.',
      }],
    });
  }

  const result = await converter.convert(message.data, message.options);

  // The artifact and every resource are transferred rather than copied: they
  // are this worker's own defensive copies already, so the page taking
  // ownership costs nothing and avoids a second copy of a large document.
  const transfer = [result.artifact.buffer];
  const resources = result.resources.map((resource) => {
    transfer.push(resource.bytes.buffer);
    return { path: resource.path, bytes: resource.bytes, digest: resource.digest };
  });

  post({
    kind: 'converted',
    id: message.id,
    result: {
      artifact: result.artifact,
      artifactName: result.artifactName,
      sourceFormat: result.sourceFormat,
      outputFormat: result.outputFormat,
      isText: result.isText,
      reports: result.reports,
      manifest: result.manifest,
      resources,
      elapsedMs: result.elapsedMs,
    },
    memory: converter.memory,
  }, transfer);
}

/// Errors do not survive `postMessage` as instances, so they cross as plain
/// data and the page rebuilds them. Everything a caller needs to act — the
/// code, the exit class, the directions, the engine's reports — is carried;
/// the stack is not, because it describes this file rather than the document.
function describe(error) {
  if (error instanceof ZenfmtError) {
    return {
      code: error.code,
      exitClass: error.exitClass,
      problem: error.problem,
      consequence: error.consequence,
      directions: error.directions,
      reports: error.reports,
    };
  }
  return {
    code: 'browser.worker-failed',
    exitClass: 'usage',
    problem: 'The conversion worker stopped unexpectedly.',
    consequence: 'Nothing was converted. The page is unaffected.',
    directions: [{
      title: 'Try again',
      explanation: 'The worker is replaced automatically before the next conversion.',
    }],
    reports: [],
    detail: String(error && error.message ? error.message : error),
  };
}

function post(message, transfer) {
  self.postMessage(message, transfer ?? []);
}
