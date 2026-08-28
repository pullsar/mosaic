import {mkdir, mkdtemp, rm} from 'node:fs/promises';
import {isAbsolute, resolve} from 'node:path';
import type {PostgresMediaDispatcher} from './media_dispatcher.js';
import type {MediaOutputPublisher} from './media_ffmpeg_worker.js';
import type {MediaProcessRunner} from './media_process.js';
import {
  MediaIdentityConflictError,
  type MediaDerivativeClaim,
  type PostgresMediaRepository,
} from './media_repository.js';
import {
  processClaimedTranscriptDerivative,
  TRANSCRIPT_MEDIA_PROCESSOR,
  TranscriptWorkerError,
  type TranscriptProcessorResult,
  type TranscriptWorkerRepository,
} from './media_transcript.js';
import type {MediaSourceMaterializer} from './media_worker_runtime.js';
import {
  createMediaClaimAttemptSignal,
  mediaAttemptFailureCode,
  MEDIA_CLAIM_COMPLETION_MARGIN_MS,
} from './media_worker_claim.js';

export type TranscriptRuntimeRepository = TranscriptWorkerRepository &
  Pick<PostgresMediaRepository, 'getAsset' | 'markDerivativeFailed'>;

export type TranscriptWorkerDispatcher = Pick<PostgresMediaDispatcher, 'claimNext'>;

export interface TranscriptWorkerRuntimeOptions {
  sourceMaterializer: MediaSourceMaterializer;
  publishOutput: MediaOutputPublisher;
  workRoot: string;
  whisperModelPath: string;
  leaseMs?: number;
  prepareTimeoutMs?: number;
  whisperTimeoutMs?: number;
  idleMs?: number;
  maxVttBytes?: number;
  signal?: AbortSignal;
  ffmpegExecutable?: string;
  whisperExecutable?: string;
  runProcess?: MediaProcessRunner;
  onResult?: (result: TranscriptWorkerIterationResult) => void;
}

export type TranscriptWorkerIterationStatus =
  | 'idle'
  | 'aborted'
  | 'processed'
  | 'failed'
  | 'stale';

export interface TranscriptWorkerIterationResult {
  status: TranscriptWorkerIterationStatus;
  claim: MediaDerivativeClaim | null;
  workerResult?: TranscriptProcessorResult;
  errorCode?: string;
}

const TRANSCRIPT_PROCESSORS = Object.freeze([TRANSCRIPT_MEDIA_PROCESSOR] as const);
const DEFAULT_LEASE_MS = 30 * 60 * 1000;
const DEFAULT_PREPARE_TIMEOUT_MS = 2 * 60 * 1000;
const DEFAULT_WHISPER_TIMEOUT_MS = 20 * 60 * 1000;
const DEFAULT_IDLE_MS = 1_000;
const MAX_INTERVAL_MS = 60 * 60 * 1000;

export async function runTranscriptWorkerOnce(
  dispatcher: TranscriptWorkerDispatcher,
  repository: TranscriptRuntimeRepository,
  options: TranscriptWorkerRuntimeOptions,
): Promise<TranscriptWorkerIterationResult> {
  const timing = normalizeTiming(options);
  const workRoot = absoluteRoot(options.workRoot, 'workRoot');
  if (options.signal?.aborted) {
    return emit(options, {status: 'aborted', claim: null});
  }

  const claim = await dispatcher.claimNext(TRANSCRIPT_PROCESSORS, timing.leaseMs);
  if (claim === null) return emit(options, {status: 'idle', claim: null});

  const attemptSignal = createMediaClaimAttemptSignal(claim, options.signal);
  if (attemptSignal === null) {
    return await failClaim(repository, claim, 'media_claim_invalid', options);
  }

  try {
    const asset = await repository.getAsset(claim.derivative.assetId);
    if (
      asset === null ||
      asset.state === 'revoked' ||
      asset.sourceStorageKey === null ||
      asset.sourceSha256 === null ||
      asset.sourceMimeType === null ||
      asset.sourceSizeBytes === null ||
      asset.sourceSha256 !== claim.derivative.sourceSha256
    ) {
      return await failClaim(
        repository,
        claim,
        'media_source_unavailable',
        options,
      );
    }

    await mkdir(workRoot, {recursive: true, mode: 0o700});
    const workDirectory = await mkdtemp(`${workRoot}/transcript-attempt-`);
    let materialized: Awaited<ReturnType<MediaSourceMaterializer>> | null = null;
    try {
      try {
        materialized = await options.sourceMaterializer(
          asset,
          workDirectory,
          attemptSignal.signal,
        );
      } catch (error) {
        const errorCode = mediaAttemptFailureCode(
          error,
          options.signal,
          attemptSignal.deadlineSignal,
          'media_source_unavailable',
        );
        return await failClaim(repository, claim, errorCode, options);
      }

      try {
        const workerResult = await processClaimedTranscriptDerivative(
          repository,
          claim,
          {inputPath: materialized.inputPath, workDirectory},
          options.publishOutput,
          {
            whisperModelPath: options.whisperModelPath,
            prepareTimeoutMs: timing.prepareTimeoutMs,
            whisperTimeoutMs: timing.whisperTimeoutMs,
            signal: attemptSignal.signal,
            ...(options.maxVttBytes === undefined
              ? {}
              : {maxVttBytes: options.maxVttBytes}),
            ...(options.ffmpegExecutable === undefined
              ? {}
              : {ffmpegExecutable: options.ffmpegExecutable}),
            ...(options.whisperExecutable === undefined
              ? {}
              : {whisperExecutable: options.whisperExecutable}),
            ...(options.runProcess === undefined
              ? {}
              : {runProcess: options.runProcess}),
          },
        );
        return emit(options, {
          status: workerResult.status === 'stale' ? 'stale' : 'processed',
          claim,
          workerResult,
        });
      } catch (error) {
        const fallback = error instanceof TranscriptWorkerError
          ? error.errorCode
          : 'transcript_worker_failed';
        const errorCode = mediaAttemptFailureCode(
          error,
          options.signal,
          attemptSignal.deadlineSignal,
          fallback,
        );
        return await failClaim(repository, claim, errorCode, options);
      }
    } finally {
      await materialized?.cleanup?.().catch(() => undefined);
      await rm(workDirectory, {recursive: true, force: true}).catch(() => undefined);
    }
  } finally {
    attemptSignal.dispose();
  }
}

export async function runTranscriptWorkerLoop(
  dispatcher: TranscriptWorkerDispatcher,
  repository: TranscriptRuntimeRepository,
  options: TranscriptWorkerRuntimeOptions,
): Promise<void> {
  const timing = normalizeTiming(options);
  while (!options.signal?.aborted) {
    const result = await runTranscriptWorkerOnce(dispatcher, repository, options);
    if (result.status === 'aborted') return;
    if (result.status === 'idle') {
      await abortableSleep(timing.idleMs, options.signal);
    }
  }
}

async function failClaim(
  repository: TranscriptRuntimeRepository,
  claim: MediaDerivativeClaim,
  errorCode: string,
  options: TranscriptWorkerRuntimeOptions,
): Promise<TranscriptWorkerIterationResult> {
  try {
    await repository.markDerivativeFailed(
      claim.derivative.assetId,
      claim.derivative.derivativeKey,
      claim.claimToken,
      errorCode,
    );
    return emit(options, {status: 'failed', claim, errorCode});
  } catch (error) {
    if (error instanceof MediaIdentityConflictError) {
      return emit(options, {status: 'stale', claim, errorCode});
    }
    throw error;
  }
}

function normalizeTiming(options: TranscriptWorkerRuntimeOptions): {
  leaseMs: number;
  prepareTimeoutMs: number;
  whisperTimeoutMs: number;
  idleMs: number;
} {
  const leaseMs = positiveBoundedInteger(
    options.leaseMs ?? DEFAULT_LEASE_MS,
    'leaseMs',
    MAX_INTERVAL_MS,
  );
  const prepareTimeoutMs = positiveBoundedInteger(
    options.prepareTimeoutMs ?? DEFAULT_PREPARE_TIMEOUT_MS,
    'prepareTimeoutMs',
    MAX_INTERVAL_MS,
  );
  const whisperTimeoutMs = positiveBoundedInteger(
    options.whisperTimeoutMs ?? DEFAULT_WHISPER_TIMEOUT_MS,
    'whisperTimeoutMs',
    MAX_INTERVAL_MS,
  );
  const idleMs = positiveBoundedInteger(
    options.idleMs ?? DEFAULT_IDLE_MS,
    'idleMs',
    60_000,
  );
  if (
    prepareTimeoutMs +
      whisperTimeoutMs +
      MEDIA_CLAIM_COMPLETION_MARGIN_MS >=
    leaseMs
  ) {
    throw new TypeError(
      'Transcript timeouts must leave the media claim completion margin before lease expiry',
    );
  }
  return {leaseMs, prepareTimeoutMs, whisperTimeoutMs, idleMs};
}

function absoluteRoot(value: string, name: string): string {
  if (!value || !isAbsolute(value)) {
    throw new TypeError(`${name} must be an absolute filesystem path`);
  }
  return resolve(value);
}

function positiveBoundedInteger(
  value: number,
  name: string,
  maximum: number,
): number {
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new TypeError(`${name} must be a positive safe integer <= ${maximum}`);
  }
  return value;
}

async function abortableSleep(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) return;
  await new Promise<void>((resolvePromise) => {
    const timer = setTimeout(resolvePromise, ms);
    const abort = (): void => {
      clearTimeout(timer);
      resolvePromise();
    };
    signal?.addEventListener('abort', abort, {once: true});
    timer.unref();
    if (signal?.aborted) abort();
  });
}

function emit(
  options: TranscriptWorkerRuntimeOptions,
  result: TranscriptWorkerIterationResult,
): TranscriptWorkerIterationResult {
  options.onResult?.(result);
  return result;
}
