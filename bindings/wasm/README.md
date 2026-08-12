# zenfmt for WebAssembly

This directory is the versioned browser distribution for zenfmt. It contains a
`wasm32-freestanding` engine with no host imports, a standards-based ES module,
an optional dedicated-worker adapter, and declarations.

The same files are published as `@insnai/zenfmt` for applications that prefer
npm. The tagged archive remains usable without a package manager or build
step, and the native CLI and server do not require Node or npm.

Serve every file from the same origin. The project site uses the worker-backed
API so synchronous document parsing never blocks the page:

```js
import { createWorkerConverter } from "./zenfmt.js";

const converter = await createWorkerConverter({
  moduleUrl: new URL("./zenfmt.wasm", import.meta.url),
  workerUrl: new URL("./zenfmt.worker.js", import.meta.url),
});

const result = await converter.convert(file, { timeoutMs: 30_000 });
console.log(result.text);
converter.dispose();
```

`zenfmt.js` also exports `createConverter` for expert callers that already own
a worker or another isolated JavaScript context. There is no implicit CDN,
filesystem, analytics, or network conversion fallback.

The browser profile accepts inputs up to 32 MiB and caps linear memory at
1 GiB. See `capabilities.json` for the complete format and limit contract,
`artifact-manifest.json` for sizes and SHA-256 digests, and the project Book
and ZDS 0015 for lifecycle, security, and ABI details.

Copyright 2026 Vikrant Rathore and Ronak Rathore. Licensed under MIT.
