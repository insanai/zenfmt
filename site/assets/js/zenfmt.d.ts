// Type declarations for the zenfmt browser adapter (ZDS 0015).
//
// Handwritten, and checked structurally rather than by a type checker: a
// compiler for these would require the JavaScript toolchain this project
// deliberately does not have, and buying one type check at the price of a
// second package ecosystem is a bad trade for a single declaration file.
//
// `zig build wasm-check` asserts a three-way agreement between this file, the
// adapter, and the API tests: every declared name is implemented, every
// implemented name is declared, and both are exercised. Names and constants
// therefore cannot drift. Types can — that limitation is stated rather than
// papered over.

export interface Direction {
  readonly title: string;
  readonly explanation: string;
}

export interface Report {
  readonly severity: 'note' | 'warning' | 'error';
  readonly code: string;
  readonly title: string;
  readonly problem: string;
  readonly consequence: string;
  readonly exit_class?: 'conversion' | 'usage' | 'limit';
  readonly directions?: readonly Direction[];
  readonly count?: number;
}

export interface Resource {
  readonly path: string;
  readonly bytes: Uint8Array;
  readonly digest: string;
}

export interface ConvertOptions {
  /** Required for byte input; a File supplies its own. */
  readonly name?: string;
  readonly artifactName?: string;
  readonly from?: string;
  readonly to?: string;
  readonly strict?: 'off' | 'content' | 'structure' | 'exact';
  readonly preserveFacets?: boolean;
  /** May lower a browser-profile limit. Raising one is refused. */
  readonly limits?: Readonly<Record<string, number>>;
}

export interface WorkerConvertOptions extends ConvertOptions {
  /** Stops synchronous parsing by terminating and replacing the worker. */
  readonly signal?: AbortSignal;
  /** Zero disables the timeout. The project site uses 30 seconds. */
  readonly timeoutMs?: number;
}

export declare class Conversion {
  readonly artifact: Uint8Array;
  readonly artifactName: string | null;
  readonly sourceFormat: string | null;
  readonly outputFormat: string | null;
  readonly isText: boolean;
  readonly reports: readonly Report[];
  readonly manifest: unknown | null;
  readonly resources: readonly Resource[];
  readonly elapsedMs: number;
  /** Throws for a writer that emits binary rather than text. */
  readonly text: string;
}

export declare class ZenfmtError extends Error {
  readonly code: string;
  readonly exitClass: 'conversion' | 'usage' | 'limit';
  readonly problem: string;
  readonly consequence: string;
  readonly directions: readonly Direction[];
  readonly reports: readonly Report[];
}

export interface Capabilities {
  readonly schema: number;
  readonly version: string;
  readonly revision: string;
  readonly target: string;
  readonly abi_version: number;
  readonly default_output_format: string;
  readonly formats: readonly {
    readonly format: string;
    readonly extensions: readonly string[];
    readonly read: boolean;
    readonly write: boolean;
    readonly text_writer: boolean | null;
  }[];
  readonly browser_profile: Readonly<Record<string, number>>;
  readonly engine_limits: Readonly<Record<string, number>>;
  readonly unavailable: readonly string[];
  readonly cpu_features: readonly string[];
}

export interface MemoryUse {
  readonly pages: number;
  readonly highWaterPages: number;
  readonly liveBytes: number;
  readonly liveResults: number;
}

export declare class Converter {
  readonly compiledModule: WebAssembly.Module;
  readonly capabilities: Capabilities;
  readonly version: string;
  readonly memory: MemoryUse;
  readonly disposed: boolean;
  ready(): Promise<Converter>;
  convert(
    source: File | Blob | ArrayBuffer | Uint8Array,
    options?: ConvertOptions,
  ): Promise<Conversion>;
  dispose(): void;
}

export declare function createConverter(options: {
  readonly moduleUrl: string | URL;
  readonly signal?: AbortSignal;
}): Promise<Converter>;

export declare class WorkerConverter {
  readonly capabilities: Capabilities;
  readonly version: string;
  readonly memory: MemoryUse;
  readonly disposed: boolean;
  ready(): Promise<WorkerConverter>;
  convert(
    source: File | Blob | ArrayBuffer | Uint8Array,
    options?: WorkerConvertOptions,
  ): Promise<Conversion>;
  dispose(): void;
}

export declare function createWorkerConverter(options: {
  readonly moduleUrl: string | URL;
  readonly workerUrl: string | URL;
  readonly signal?: AbortSignal;
}): Promise<WorkerConverter>;

export declare function readSource(
  source: File | Blob | ArrayBuffer | Uint8Array,
  explicitName?: string,
): Promise<{ name: string; data: Uint8Array }>;

export declare const abi: {
  readonly version: number;
  readonly statusSuccess: number;
  readonly statusFailed: number;
  readonly statusInvalidRequest: number;
  readonly statusInvalidHandle: number;
  readonly requestSchema: number;
};

/** The adapter release; a module from another release is rejected. */
export declare const version: string;
