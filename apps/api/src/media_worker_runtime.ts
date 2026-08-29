import {mkdir, mkdtemp, realpath, rm, stat} from 'node:fs/promises';
import {isAbsolute, join, relative, resolve, sep} from 'node:path';
import {
  FFMPEG_MEDIA_PROCESSORS,
  type PostgresMediaDispatcher,
} from './media_dispatcher.js';
import {
  processClaimedFfmpegDerivative,
  type MediaFfmpegWorkerRepository,
  type MediaFfmpegWorkerResult,
  type MediaOutputPublisher,
  type MediaOutputVerifier,
  type MediaProcessRunner,
} from './media_ffmpeg_worker.js';
import {sha256File} from './media_object_store.js';
import {
  MediaIdentityConflictError,
  type MediaAssetRecord,
  type MediaDerivativeClaim,
  type PostgresMediaRepository,
} from './media_repository.js';
import {
  createMediaClaimAttemptSignal,
  mediaAttemptFailureCode,
  MEDIA_CLAIM_COMPLETION_MARGIN_MS,
} from './media_worker_claim.js';

export type MediaWorkerRepository = MediaFfmpegWorkerRepository &
  Pick<PostgresMediaRepository, 'getAsset'>;

export type MediaWorkerDispatcher = Pick<PostgresMediaDispatcher, 'claimNext'>;

export interface MaterializedMediaSource {
  inputPath: string;
  cleanup?: () => Promise<void>;
}

export type MediaSourceMaterializer = (
  asset: MediaAssetRecord,
  workDirectory: string,
  signal?: AbortSignal,
) => Promise<MaterializedMediaSource>;

export interface MediaWorkerRuntimeOptions {
  sourceMaterializer: MediaSourceMaterializer;
  verifyOutput: MediaOutputVerifier;
  publishOutput: MediaOutputPublisher;
  workRoot: string;
  leaseMs?: number;
  timeoutMs?: number;
  idleMs?: number;
  signal?: AbortSignal;
  ffmpegExecutable?: string;
  runProcess?: MediaProcessRunner;
  onResult?: (result: MediaWorkerIterationResult) => void;
}

export type MediaWorkerIterationStatus =
  | 'idle'
  | 'aborted'
  | 'processed'
  | 'source_failed'
  | 'stale';

export interface MediaWorkerIterationResult {
  status: MediaWorkerIterationStatus;
  claim: MediaDerivativeClaim | null;
  workerResult?: MediaFfmpegWorkerResult;
  errorCode?: string;
}

const DEFAULT_LEASE_MS = 15 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;
const DEFAULT_IDLE_MS = 1_000;
const MAX_INTERVAL_MS = 60 * 60 * 1000;

export async function runMediaWorkerOnce(
  dispatcher: MediaWorkerDispatcher,
  repository: MediaWorkerRepository,
  options: MediaWorkerRuntimeOptions,
): Promise<MediaWorkerIterationResult> {
  const timing = normalizeTiming(options);
  const workRoot = absoluteRoot(options.workRoot, 'workRoot');
  if (options.signal?.aborted) {
    return emit(options, {status: 'aborted', claim: null});
  }

  const claim = await dispatcher.claimNext(
    FFMPEG_MEDIA_PROCESSORS,
    timing.leaseMs,
  );
  if (claim === null) {
    return emit(options, {status: 'idle', claim: null});
  }

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
    const workDirectory = await mkdtemp(join(workRoot, 'attempt-'));
    let materialized: MaterializedMediaSource | null = null;
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

      const outputPath = join(
        workDirectory,
        outputFileName(claim.derivative.purpose),
      );
      const workerResult = await processClaimedFfmpegDerivative(
        repository,
        claim,
        {inputPath: materialized.inputPath, outputPath},
        options.verifyOutput,
        options.publishOutput,
        {
          timeoutMs: timing.timeoutMs,
          signal: attemptSignal.signal,
          ...(options.ffmpegExecutable === undefined
            ? {}
            : {ffmpegExecutable: options.ffmpegExecutable}),
          ...(options.runProcess === undefined
            ? {}
            : {runProcess: options.runProcess}),
        },
      );
      return emit(options, {
        status: workerResult.status === 'stale' ? 'stale' : 'processed',
        claim,
        workerResult,
        ...(workerResult.errorCode === undefined
          ? {}
          : {errorCode: workerResult.errorCode}),
      });
    } finally {
      await materialized?.cleanup?.().catch(() => undefined);
      await rm(workDirectory, {recursive: true, force: true}).catch(() => undefined);
    }
  } finally {
    attemptSignal.dispose();
  }
}

export async function runMediaWorkerLoop(
  dispatcher: MediaWorkerDispatcher,
  repository: MediaWorkerRepository,
  options: MediaWorkerRuntimeOptions,
): Promise<void> {
  const timing = normalizeTiming(options);
  while (!options.signal?.aborted) {
    const result = await runMediaWorkerOnce(dispatcher, repository, options);
    if (result.status === 'aborted') return;
    if (result.status === 'idle') {
      await abortableSleep(timing.idleMs, options.signal);
    }
  }
}

export function createLocalMediaSourceMaterializer(
  sourceRoot: string,
): MediaSourceMaterializer {
  const configuredRoot = absoluteRoot(sourceRoot, 'sourceRoot');
  return async (asset, _workDirectory, signal) => {
    if (
      asset.sourceStorageKey === null ||
      asset.sourceSha256 === null ||
      asset.sourceSizeBytes === null
    ) {
      throw new Error(`Media asset ${asset.id} has no verified local source`);
    }
    abortIfRequested(signal);
    const root = await realpath(configuredRoot);
    const candidate = resolveRelativeStoragePath(root, asset.sourceStorageKey);
    const inputPath = await realpath(candidate);
    assertWithinRoot(root, inputPath, 'sourceStorageKey');
    const info = await stat(inputPath);
    if (!info.isFile() || info.size !== asset.sourceSizeBytes) {
      throw new Error(`Media asset ${asset.id} source size no longer matches verified metadata`);
    }
    const digest = await sha256File(inputPath, signal);
    if (digest !== asset.sourceSha256) {
      throw new Error(`Media asset ${asset.id} source digest no longer matches verified metadata`);
    }
    return {inputPath};
  };
}

async function failClaim(
  repository: MediaWorkerRepository,
  claim: MediaDerivativeClaim,
  errorCode: string,
  options: MediaWorkerRuntimeOptions,
): Promise<MediaWorkerIterationResult> {
  try {
    const failed = await repository.markDerivativeFailed(
      claim.derivative.assetId,
      claim.derivative.derivativeKey,
      claim.claimToken,
      errorCode,
    );
    return emit(options, {
      status: 'source_failed',
      claim,
      workerResult: {
        status: 'failed',
        derivative: failed,
        errorCode,
      },
      errorCode,
    });
  } catch (error) {
    if (error instanceof MediaIdentityConflictError) {
      return emit(options, {status: 'stale', claim, errorCode});
    }
    throw error;
  }
}

function normalizeTiming(options: MediaWorkerRuntimeOptions): {
  leaseMs: number;
  timeoutMs: number;
  idleMs: number;
} {
  const leaseMs = positiveBoundedInteger(
    options.leaseMs ?? DEFAULT_LEASE_MS,
    'leaseMs',
    MAX_INTERVAL_MS,
  );
  const timeoutMs = positiveBoundedInteger(
    options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    'timeoutMs',
    MAX_INTERVAL_MS,
  );
  const idleMs = positiveBoundedInteger(
    options.idleMs ?? DEFAULT_IDLE_MS,
    'idleMs',
    60_000,
  );
  if (timeoutMs + MEDIA_CLAIM_COMPLETION_MARGIN_MS >= leaseMs) {
    throw new TypeError(
      `timeoutMs must leave at least ${MEDIA_CLAIM_COMPLETION_MARGIN_MS} ms before lease expiry`,
    );
  }
  return {leaseMs, timeoutMs, idleMs};
}

function outputFileName(purpose: MediaDerivativeClaim['derivative']['purpose']): string {
  switch (purpose) {
    case 'image':
      return 'output.jpg';
    case 'playback':
      return 'output.mp4';
    case 'poster':
      return 'output.jpg';
    case 'audio':
      return 'output.m4a';
    case 'captions':
      return 'output.vtt';
  }
}

function absoluteRoot(value: string, name: string): string {
  if (!value || !isAbsolute(value)) {
    throw new TypeError(`${name} must be an absolute filesystem path`);
  }
  return resolve(value);
}

function resolveRelativeStoragePath(root: string, storageKey: string): string {
  if (!storageKey || storageKey.includes('\u0000') || storageKey.startsWith('/')) {
    throw new TypeError('sourceStorageKey must be a non-empty relative key');
  }
  const candidate = resolve(join(root, ...storageKey.split('/')));
  assertWithinRoot(root, candidate, 'sourceStorageKey');
  return candidate;
}

function assertWithinRoot(root: string, candidate: string, name: string): void {
  const rel = relative(root, candidate);
  if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new TypeError(`${name} escapes its configured root`);
  }
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

function abortIfRequested(signal?: AbortSignal): void {
  if (signal?.aborted) {
    const error = new Error('Media worker aborted');
    error.name = 'AbortError';
    throw error;
  }
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
  options: MediaWorkerRuntimeOptions,
  result: MediaWorkerIterationResult,
): MediaWorkerIterationResult {
  options.onResult?.(result);
  return result;
}
