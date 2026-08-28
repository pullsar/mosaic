import {
  loadMediaStorageConfig,
  optionalExecutableEnv,
  positiveIntegerEnv,
  requiredAbsoluteEnv,
  requiredEnvText,
  type LocalMediaStorageConfig,
  type S3MediaStorageConfig,
} from './media_storage_config.js';

interface TranscriptWorkerCommonConfig {
  databaseUrl: string;
  workRoot: string;
  leaseMs: number;
  prepareTimeoutMs: number;
  whisperTimeoutMs: number;
  idleMs: number;
  maxVttBytes: number;
  whisperThreads: number;
  ffmpegExecutable: string;
  whisperExecutable: string;
  whisperModelPath: string;
}

export interface LocalTranscriptWorkerConfig
  extends TranscriptWorkerCommonConfig,
    LocalMediaStorageConfig {}

export interface S3TranscriptWorkerConfig
  extends TranscriptWorkerCommonConfig,
    S3MediaStorageConfig {}

export type TranscriptWorkerConfig =
  | LocalTranscriptWorkerConfig
  | S3TranscriptWorkerConfig;

const DEFAULT_LEASE_MS = 30 * 60 * 1000;
const DEFAULT_PREPARE_TIMEOUT_MS = 2 * 60 * 1000;
const DEFAULT_WHISPER_TIMEOUT_MS = 20 * 60 * 1000;
const DEFAULT_IDLE_MS = 1_000;
const DEFAULT_MAX_VTT_BYTES = 4 * 1024 * 1024;
const DEFAULT_WHISPER_THREADS = 4;
const MAX_INTERVAL_MS = 60 * 60 * 1000;
const MAX_VTT_BYTES = 16 * 1024 * 1024;
const MAX_WHISPER_THREADS = 64;
const CLAIM_MARGIN_MS = 30_000;
const MAX_S3_REQUESTS_PER_ATTEMPT = 3;

export function loadTranscriptWorkerConfig(
  env: NodeJS.ProcessEnv = process.env,
): TranscriptWorkerConfig {
  const storage = loadMediaStorageConfig(env);
  const common = {
    databaseUrl: requiredEnvText(env, 'DATABASE_URL'),
    workRoot: requiredAbsoluteEnv(env, 'MEDIA_TRANSCRIPT_WORK_ROOT'),
    leaseMs: positiveIntegerEnv(
      env,
      'MEDIA_TRANSCRIPT_LEASE_MS',
      DEFAULT_LEASE_MS,
      MAX_INTERVAL_MS,
    ),
    prepareTimeoutMs: positiveIntegerEnv(
      env,
      'MEDIA_TRANSCRIPT_PREPARE_TIMEOUT_MS',
      DEFAULT_PREPARE_TIMEOUT_MS,
      MAX_INTERVAL_MS,
    ),
    whisperTimeoutMs: positiveIntegerEnv(
      env,
      'MEDIA_TRANSCRIPT_WHISPER_TIMEOUT_MS',
      DEFAULT_WHISPER_TIMEOUT_MS,
      MAX_INTERVAL_MS,
    ),
    idleMs: positiveIntegerEnv(
      env,
      'MEDIA_TRANSCRIPT_IDLE_MS',
      DEFAULT_IDLE_MS,
      60_000,
    ),
    maxVttBytes: positiveIntegerEnv(
      env,
      'MEDIA_TRANSCRIPT_MAX_VTT_BYTES',
      DEFAULT_MAX_VTT_BYTES,
      MAX_VTT_BYTES,
    ),
    whisperThreads: positiveIntegerEnv(
      env,
      'MEDIA_TRANSCRIPT_WHISPER_THREADS',
      DEFAULT_WHISPER_THREADS,
      MAX_WHISPER_THREADS,
    ),
    ffmpegExecutable: optionalExecutableEnv(
      env.MEDIA_FFMPEG_PATH,
      'ffmpeg',
      'MEDIA_FFMPEG_PATH',
    ),
    whisperExecutable: optionalExecutableEnv(
      env.MEDIA_TRANSCRIPT_WHISPER_PATH,
      'whisper-cli',
      'MEDIA_TRANSCRIPT_WHISPER_PATH',
    ),
    whisperModelPath: requiredAbsoluteEnv(env, 'MEDIA_TRANSCRIPT_MODEL_PATH'),
  } as const;

  if (storage.storageMode === 'local') {
    ensureLeaseBudget(common, 0);
    return Object.freeze({...common, ...storage});
  }

  ensureLeaseBudget(
    common,
    storage.storageTimeoutMs * MAX_S3_REQUESTS_PER_ATTEMPT,
  );
  return Object.freeze({...common, ...storage});
}

function ensureLeaseBudget(
  config: Pick<
    TranscriptWorkerCommonConfig,
    'leaseMs' | 'prepareTimeoutMs' | 'whisperTimeoutMs'
  >,
  storageBudgetMs: number,
): void {
  const requiredMs =
    config.prepareTimeoutMs +
    config.whisperTimeoutMs +
    storageBudgetMs +
    CLAIM_MARGIN_MS;
  if (requiredMs >= config.leaseMs) {
    throw new Error(
      'Transcript worker timing is unsafe: MEDIA_TRANSCRIPT_LEASE_MS must exceed ' +
        'MEDIA_TRANSCRIPT_PREPARE_TIMEOUT_MS + MEDIA_TRANSCRIPT_WHISPER_TIMEOUT_MS + ' +
        `${storageBudgetMs === 0 ? '0' : '3*MEDIA_WORKER_STORAGE_TIMEOUT_MS'} + ` +
        `${CLAIM_MARGIN_MS} ms completion margin`,
    );
  }
}
