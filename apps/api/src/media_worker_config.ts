import {isAbsolute, resolve} from 'node:path';

interface MediaWorkerCommonConfig {
  databaseUrl: string;
  workRoot: string;
  leaseMs: number;
  timeoutMs: number;
  idleMs: number;
  ffmpegExecutable: string;
  ffprobeExecutable: string;
}

export interface LocalMediaWorkerConfig extends MediaWorkerCommonConfig {
  storageMode: 'local';
  sourceRoot: string;
  objectRoot: string;
}

export interface S3MediaWorkerConfig extends MediaWorkerCommonConfig {
  storageMode: 's3';
  storageTimeoutMs: number;
  s3Endpoint: string;
  s3Bucket: string;
  s3Region: string;
  s3AccessKeyId: string;
  s3SecretAccessKey: string;
  s3SessionToken?: string;
}

export type MediaWorkerConfig = LocalMediaWorkerConfig | S3MediaWorkerConfig;

const DEFAULT_LEASE_MS = 15 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;
const DEFAULT_IDLE_MS = 1_000;
const DEFAULT_STORAGE_TIMEOUT_MS = 60_000;
const MAX_INTERVAL_MS = 60 * 60 * 1000;
const MAX_STORAGE_TIMEOUT_MS = 5 * 60 * 1000;
const CLAIM_MARGIN_MS = 30_000;
const FFPROBE_BUDGET_MS = 15_000;
const MAX_S3_REQUESTS_PER_ATTEMPT = 3;

export function loadMediaWorkerConfig(
  env: NodeJS.ProcessEnv = process.env,
): MediaWorkerConfig {
  const databaseUrl = requiredEnv(env, 'DATABASE_URL');
  const workRoot = absoluteEnv(env, 'MEDIA_WORKER_WORK_ROOT');
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
  const storageMode = storageModeEnv(env.MEDIA_WORKER_STORAGE_MODE);
  const common = {
    databaseUrl,
    workRoot,
    leaseMs,
    timeoutMs,
    idleMs,
    ffmpegExecutable: optionalExecutable(env.MEDIA_FFMPEG_PATH, 'ffmpeg'),
    ffprobeExecutable: optionalExecutable(env.MEDIA_FFPROBE_PATH, 'ffprobe'),
  } as const;

  if (storageMode === 'local') {
    ensureLocalLeaseBudget(leaseMs, timeoutMs);
    return Object.freeze({
      ...common,
      storageMode,
      sourceRoot: absoluteEnv(env, 'MEDIA_WORKER_SOURCE_ROOT'),
      objectRoot: absoluteEnv(env, 'MEDIA_WORKER_OBJECT_ROOT'),
    });
  }

  const storageTimeoutMs = integerEnv(
    env,
    'MEDIA_WORKER_STORAGE_TIMEOUT_MS',
    DEFAULT_STORAGE_TIMEOUT_MS,
    MAX_STORAGE_TIMEOUT_MS,
  );
  ensureRemoteLeaseBudget(leaseMs, timeoutMs, storageTimeoutMs);
  const sessionToken = optionalSecretEnv(env.MEDIA_S3_SESSION_TOKEN);
  return Object.freeze({
    ...common,
    storageMode,
    storageTimeoutMs,
    s3Endpoint: httpsOriginEnv(env, 'MEDIA_S3_ENDPOINT'),
    s3Bucket: requiredEnv(env, 'MEDIA_S3_BUCKET'),
    s3Region: requiredEnv(env, 'MEDIA_S3_REGION'),
    s3AccessKeyId: requiredEnv(env, 'MEDIA_S3_ACCESS_KEY_ID'),
    s3SecretAccessKey: requiredSecretEnv(env, 'MEDIA_S3_SECRET_ACCESS_KEY'),
    ...(sessionToken === undefined ? {} : {s3SessionToken: sessionToken}),
  });
}

function ensureLocalLeaseBudget(leaseMs: number, timeoutMs: number): void {
  if (timeoutMs + CLAIM_MARGIN_MS >= leaseMs) {
    throw new Error(
      `MEDIA_WORKER_TIMEOUT_MS must leave at least ${CLAIM_MARGIN_MS} ms before MEDIA_WORKER_LEASE_MS expires`,
    );
  }
}

function ensureRemoteLeaseBudget(
  leaseMs: number,
  timeoutMs: number,
  storageTimeoutMs: number,
): void {
  const requiredMs =
    timeoutMs +
    storageTimeoutMs * MAX_S3_REQUESTS_PER_ATTEMPT +
    FFPROBE_BUDGET_MS +
    CLAIM_MARGIN_MS;
  if (requiredMs >= leaseMs) {
    throw new Error(
      'S3 worker timing is unsafe: MEDIA_WORKER_LEASE_MS must exceed ' +
        'MEDIA_WORKER_TIMEOUT_MS + 3*MEDIA_WORKER_STORAGE_TIMEOUT_MS + ' +
        `${FFPROBE_BUDGET_MS} ms verification + ${CLAIM_MARGIN_MS} ms completion margin`,
    );
  }
}

function storageModeEnv(value: string | undefined): 'local' | 's3' {
  const normalized = value?.trim().toLowerCase();
  if (normalized === undefined || normalized === '') return 'local';
  if (normalized === 'local' || normalized === 's3') return normalized;
  throw new Error('MEDIA_WORKER_STORAGE_MODE must be local or s3');
}

function requiredEnv(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name]?.trim();
  if (!value || value.includes('\u0000')) {
    throw new Error(`${name} is required and must contain no NUL bytes`);
  }
  return value;
}

function requiredSecretEnv(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (!value || /[\r\n\u0000]/.test(value)) {
    throw new Error(`${name} is required and must be a single-line value`);
  }
  return value;
}

function optionalSecretEnv(value: string | undefined): string | undefined {
  if (value === undefined || value === '') return undefined;
  if (/[\r\n\u0000]/.test(value)) {
    throw new Error('MEDIA_S3_SESSION_TOKEN must be a single-line value');
  }
  return value;
}

function absoluteEnv(env: NodeJS.ProcessEnv, name: string): string {
  const value = requiredEnv(env, name);
  if (!isAbsolute(value)) throw new Error(`${name} must be an absolute path`);
  return resolve(value);
}

function httpsOriginEnv(env: NodeJS.ProcessEnv, name: string): string {
  const raw = requiredEnv(env, name);
  let url: URL;
  try {
    url = new URL(raw);
  } catch (error) {
    throw new Error(`${name} must be an absolute HTTPS origin`, {cause: error});
  }
  if (
    url.protocol !== 'https:' ||
    url.username ||
    url.password ||
    url.pathname !== '/' ||
    url.search ||
    url.hash
  ) {
    throw new Error(`${name} must be an HTTPS origin with no path, credentials, query or fragment`);
  }
  return url.origin;
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
  if (normalized.includes('\u0000')) {
    throw new Error('Media executable path contains a NUL byte');
  }
  return normalized;
}
