import type {RunResult} from './index.js';

export interface ApplicationBinding {
  format: 'ironframe-application-binding'; version: 1;
  node: string; implementation: string; revision: string; transition: string;
  previous: string | null; settings: Record<string, string>; settingsDigest: string;
  activation: 'drain-and-restart';
}
export function loadApplicationBinding(value: string | ApplicationBinding, options?: {
  ironframe?: {run(method: string, params: unknown): Promise<RunResult>};
}): Promise<{binding: ApplicationBinding; settings: Record<string, string>}>;
export function checkpointAfterFlush(options: {
  sdk: {forceFlush(): Promise<unknown>}; producer: string;
  counts: {logs: number; spans: number} | (() => {logs: number; spans: number});
  dropped?: number | (() => number); admin?: string; timeoutMs?: number; fetch?: typeof fetch;
}): Promise<{producer: string; counts: {logs: number; spans: number}; dropped: number; flushed: boolean; reason?: string}>;
