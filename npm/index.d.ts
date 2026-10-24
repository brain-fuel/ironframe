/** One request to the core: a method, its parameters and the effect results so far. */
export interface CoreRequest {
  method: string;
  params: unknown;
  effects: EffectResult[];
}

/** The core's answer: a result, a failure, the next effect, or a protocol error. */
export type CoreResponse =
  | { done: unknown }
  | { failed: string }
  | { effect: Effect; index: number }
  | { error: string };

/** An effect the core asks the host for, named by its "effect" field. */
export interface Effect {
  effect: string;
  [field: string]: unknown;
}

/** What performing an effect gave. */
export type EffectResult = { ok: unknown } | { error: string; notFound?: boolean };

/** A method run to its end. */
export type RunResult = { done: unknown } | { failed: string };

export type Core = (request: CoreRequest) => Promise<CoreResponse>;

export interface Host {
  perform(effect: Effect): Promise<EffectResult>;
  close?(): Promise<void>;
  signal?: AbortSignal;
}

/** Replaces any of the host's dependencies, as tests do. */
export interface HostOptions {
  signal?: AbortSignal;
  createServer?: unknown;
  fs?: unknown;
  process?: unknown;
  spawn?: unknown;
  net?: unknown;
  fetch?: typeof fetch;
  clock?: unknown;
  clouds?: Record<string, Record<string, (fields: Record<string, unknown>) => Promise<EffectResult>>>;
}

export function createHost(options?: HostOptions): Host;

export function run(core: Core, method: string, params: unknown, host: Host): Promise<RunResult>;

export class ProtocolError extends Error {}

export interface Ironframe {
  call(request: CoreRequest): Promise<CoreResponse>;
  run(method: string, params?: unknown): Promise<RunResult>;
}

export function createIronframe(options?: { host?: Host; core?: Core }): Ironframe;
