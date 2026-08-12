# @insnai/zenfmt

This package contains zenfmt's dependency-free browser distribution. Document
conversion runs in WebAssembly on the caller's machine. The adapter does not
upload documents or fall back to a remote conversion service.

```sh
npm install @insnai/zenfmt
```

Use a dedicated worker for browser applications:

```js
import {
  createWorkerConverter,
  wasmUrl,
  workerUrl,
} from '@insnai/zenfmt';

const converter = await createWorkerConverter({
  moduleUrl: wasmUrl,
  workerUrl,
});

const result = await converter.convert(file, { timeoutMs: 30_000 });
console.log(result.text);
converter.dispose();
```

Some bundlers require an asset rule for `.wasm` files. The package also
exports `@insnai/zenfmt/zenfmt.wasm`, `@insnai/zenfmt/worker`, and
`@insnai/zenfmt/capabilities.json` for callers that manage URLs explicitly.

The module has no host imports. It accepts inputs up to 32 MiB and caps linear
memory at 1 GiB. The npm package contains the same module, adapter, worker,
declarations, and capability contract as the tagged GitHub release.

Copyright 2026 Vikrant Rathore and Ronak Rathore. Licensed under MIT.
