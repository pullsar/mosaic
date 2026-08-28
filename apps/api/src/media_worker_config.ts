import {
  loadMediaStorageConfig,
  optionalExecutableEnv,
  positiveIntegerEnv,
  requiredAbsoluteEnv,
  requiredEnvText,
  type LocalMediaStorageConfig,
  type S3MediaStorageConfig,
} from './media_storage_config.js';

interface MediaWorkerCommonConfig {
  databaseUrl: string;
  workRoot: string;
  leaseMs: number;
  timeoutMs: number;
  idleMs: number;
  ffmpegExecutable: string;
  ffprobeExecutable: string;
}

export interface LocalMediaWorkerConfig
  extends MediaWorkerCommonConfig,
    LocalMediaStorageConfig {}

export interface S3MediaWorkerConfig
  extends MediaWorkerCommonConfig,
    S3MediaStorageConfig {}

export type MediaWorkerConfig = LocalMediaWorkerConfig | S3MediaWorkerConfig;

const DEFAULT_LEASE_MS = 15 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;
const DEFAULT_IDLE_MS = 1_000;
const MAX_INTERVAL_MS = 60 * 60 * 1000;
const CLAIM_MARGIN_MS = 30_000;
const FFPROBE_BUDGET_MS = 15_000;
const MAX_S3_REQUESTS_PER_ATTEMPT = 3;

export function loadMediaWorkerConfig(
  env: NodeJS.ProcessEnv = process.env,
): MediaWorkerConfig {
  const databaseUrl = requiredEnvText(env, 'DATABASE_URL');
  const workRoot = requiredAbsoluteEnv(env, 'MEDIA_WORKER_WORK_ROOT');
  const leaseMs = positiveIntegerEnv(
    env,
    'MEDIA_WORKER_LEASE_MS',
    DEFAULT_LEASE_MS,
    MAX_INTERVAL_MS,
  );
  const timeoutMs = positiveIntegerEnv(
    env,
    'MEDIA_WORKER_TIMEOUT_MS',
    DEFAULT_TIMEOUT_MS,
    MAX_INTERVAL_MS,
  );
  const idleMs = positiveIntegerEnv(
    env,
    'MEDIA_WORKER_IDLE_MS',
    DEFAULT_IDLE_MS,
    60_000,
  );
  const storage = loadMediaStorageConfig(env);
  const common = {
    databaseUrl,
    workRoot,
    leaseMs,
    timeoutMs,
    idleMs,
    ffmpegExecutable: optionalExecutableEnv(
      env.MEDIA_FFMPEG_PATH,
      'ffmpeg',
      'MEDIA_FFMPEG_PATH',
    ),
    ffprobeExecutable: optionalExecutableEnv(
      env.MEDIA_FFPROBE_PATH,
      'ffprobe',
      'MEDIA_FFPROBE_PATH',
    ),
  } as const;

  if (storage.storageMode === 'local') {
    ensureLocalLeaseBudget(leaseMs, timeoutMs);
    return Object.freeze({...common, ...storage});
  }

  ensureRemoteLeaseBudget(leaseMs, timeoutMs, storage.storageTimeoutMs);
  return Object.freeze({...common, ...storage});
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
