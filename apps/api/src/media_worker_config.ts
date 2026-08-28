import {isAbsolute, resolve} from 'node:path';

export interface MediaWorkerConfig {
  databaseUrl: string;
  sourceRoot: string;
  workRoot: string;
  objectRoot: string;
  leaseMs: number;
  timeoutMs: number;
  idleMs: number;
  ffmpegExecutable: string;
  ffprobeExecutable: string;
}

const DEFAULT_LEASE_MS = 15 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;
const DEFAULT_IDLE_MS = 1_000;
const MAX_INTERVAL_MS = 60 * 60 * 1000;
const CLAIM_MARGIN_MS = 30_000;

export function loadMediaWorkerConfig(
  env: NodeJS.ProcessEnv = process.env,
): MediaWorkerConfig {
  const databaseUrl = requiredEnv(env, 'DATABASE_URL');
  const sourceRoot = absoluteEnv(env, 'MEDIA_WORKER_SOURCE_ROOT');
  const workRoot = absoluteEnv(env, 'MEDIA_WORKER_WORK_ROOT');
  const objectRoot = absoluteEnv(env, 'MEDIA_WORKER_OBJECT_ROOT');
  const leaseMs = integerEnv(
    env,
    'MEDIA_WORKER_LEASE_MS',
    DEFAULT_LEASE_MS,
    MAX_INTERVAL_MS,
  );
  const timeoutMs = integerEnv(
    env,
    'MEDIA_WORKER_TIMEOUT_MS',
    DEFAULT_TIMEOUT_MS,
    MAX_INTERVAL_MS,
  );
  const idleMs = integerEnv(env, 'MEDIA_WORKER_IDLE_MS', DEFAULT_IDLE_MS, 60_000);
  if (timeoutMs + CLAIM_MARGIN_MS >= leaseMs) {
    throw new Error(
      `MEDIA_WORKER_TIMEOUT_MS must leave at least ${CLAIM_MARGIN_MS} ms before MEDIA_WORKER_LEASE_MS expires`,
    );
  }
  return Object.freeze({
    databaseUrl,
    sourceRoot,
    workRoot,
    objectRoot,
    leaseMs,
    timeoutMs,
    idleMs,
    ffmpegExecutable: optionalExecutable(env.MEDIA_FFMPEG_PATH, 'ffmpeg'),
    ffprobeExecutable: optionalExecutable(env.MEDIA_FFPROBE_PATH, 'ffprobe'),
  });
}

function requiredEnv(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name]?.trim();
  if (!value || value.includes('\u0000')) {
    throw new Error(`${name} is required and must contain no NUL bytes`);
  }
  return value;
}

function absoluteEnv(env: NodeJS.ProcessEnv, name: string): string {
  const value = requiredEnv(env, name);
  if (!isAbsolute(value)) throw new Error(`${name} must be an absolute path`);
  return resolve(value);
}

function integerEnv(
  env: NodeJS.ProcessEnv,
  name: string,
  defaultValue: number,
  maximum: number,
): number {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return defaultValue;
  if (!/^\d+$/.test(raw.trim())) {
    throw new Error(`${name} must be a positive integer`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new Error(`${name} must be a positive safe integer <= ${maximum}`);
  }
  return value;
}

function optionalExecutable(value: string | undefined, fallback: string): string {
  if (value === undefined || value.trim() === '') return fallback;
  const normalized = value.trim();
  if (normalized.includes('\u0000')) throw new Error('Media executable path contains a NUL byte');
  return normalized;
}
