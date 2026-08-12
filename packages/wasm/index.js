export * from './zenfmt.js';

export const wasmUrl = new URL('./zenfmt.wasm', import.meta.url);
export const workerUrl = new URL('./zenfmt.worker.js', import.meta.url);
