import {
  compileFfmpegInvocation,
  MediaPlanCompileError,
  supportsFfmpegPlan,
  type FfmpegExpectedOutput,
} from './media_ffmpeg.js';
import {
  MediaProcessError,
  runMediaProcess,
  type MediaProcessInvocation,
  type MediaProcessResult,
  type MediaProcessRunOptions,
} from './media_process.js';
import {
  MediaIdentityConflictError,
  type MediaDerivativeOutput,
  type MediaDerivativeRecord,
  type PostgresMediaRepository,
} from './media_repository.js';
import {type MediaDerivativePlan} from './media.js';

export type MediaFfmpegWorkerRepository = Pick<
  PostgresMediaRepository,
  'getDerivative' | 'claimDerivative' | 'markDerivativeReady' | 'markDerivativeFailed'
>;

export type VerifiedMediaOutput = Omit<MediaDerivativeOutput, 'storageKey'>;

export interface MediaOutputVerificationRequest {
  outputPath: string;
  storageKey: string;
  plan: MediaDerivativePlan;
  expectedOutput: Readonly<FfmpegExpectedOutput>;
  signal?: AbortSignal;
}

export type MediaOutputVerifier = (
  request: MediaOutputVerificationRequest,
) => Promise<VerifiedMediaOutput>;

export type MediaProcessRunner = (
  invocation: MediaProcessInvocation,
  options: MediaProcessRunOptions,
) => Promise<MediaProcessResult>;

export interface MediaFfmpegJob {
  assetId: string;
  derivativeKey: string;
  inputPath: string;
  outputPath: string;
  outputStorageKey: string;
}

export interface MediaFfmpegWorkerOptions {
  leaseMs?: number;
  timeoutMs?: number;
  signal?: AbortSignal;
  ffmpegExecutable?: string;
  runProcess?: MediaProcessRunner;
}

export type MediaFfmpegWorkerStatus =
  | 'missing'
  | 'unsupported'
  | 'aborted'
  | 'not_claimed'
  | 'ready'
  | 'failed'
  | 'stale';

export interface MediaFfmpegWorkerResult {
  status: MediaFfmpegWorkerStatus;
  derivative: MediaDerivativeRecord | null;
  errorCode?: string;
}

export class MediaOutputVerificationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'MediaOutputVerificationError';
  }
}

const DEFAULT_LEASE_MS = 15 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;
const MAX_LEASE_MS = 60 * 60 * 1000;
const CLAIM_COMPLETION_MARGIN_MS = 30_000;

export async function processFfmpegDerivative(
  repository: MediaFfmpegWorkerRepository,
  job: MediaFfmpegJob,
  verifyOutput: MediaOutputVerifier,
  options: MediaFfmpegWorkerOptions = {},
): Promise<MediaFfmpegWorkerResult> {
  const assetId = requiredText(job.assetId, 'assetId');
  const derivativeKey = requiredText(job.derivativeKey, 'derivativeKey');
  const storageKey = requiredText(job.outputStorageKey, 'outputStorageKey');
  const leaseMs = boundedPositiveInteger(options.leaseMs ?? DEFAULT_LEASE_MS, 'leaseMs', MAX_LEASE_MS);
  const timeoutMs = boundedPositiveInteger(options.timeoutMs ?? DEFAULT_TIMEOUT_MS, 'timeoutMs', MAX_LEASE_MS);
  if (timeoutMs + CLAIM_COMPLETION_MARGIN_MS >= leaseMs) {
    throw new TypeError(
      `timeoutMs must leave at least ${CLAIM_COMPLETION_MARGIN_MS} ms before the derivative lease expires`,
    );
  }
  if (options.signal?.aborted) {
    return {status: 'aborted', derivative: null};
  }

  const existing = await repository.getDerivative(assetId, derivativeKey);
  if (existing === null) return {status: 'missing', derivative: null};
  if (existing.state === 'ready') return {status: 'ready', derivative: existing};
  if (!supportsFfmpegPlan(existing.plan)) {
    return {status: 'unsupported', derivative: existing};
  }

  const claim = await repository.claimDerivative(assetId, derivativeKey, leaseMs);
  if (claim === null) {
    return {
      status: 'not_claimed',
      derivative: await repository.getDerivative(assetId, derivativeKey),
    };
  }

  try {
    const invocation = compileFfmpegInvocation(
      claim.derivative.plan,
      {inputPath: job.inputPath, outputPath: job.outputPath},
      options.ffmpegExecutable === undefined
        ? {}
        : {executable: options.ffmpegExecutable},
    );
    const runner = options.runProcess ?? runMediaProcess;
    await runner(
      invocation,
      options.signal === undefined
        ? {timeoutMs}
        : {timeoutMs, signal: options.signal},
    );

    const verified = await verifyOutput({
      outputPath: job.outputPath,
      storageKey,
      plan: claim.derivative.plan,
      expectedOutput: invocation.expectedOutput,
      ...(options.signal === undefined ? {} : {signal: options.signal}),
    });
    assertVerifiedOutput(invocation.expectedOutput, verified);

    try {
      const ready = await repository.markDerivativeReady(
        assetId,
        derivativeKey,
        claim.claimToken,
        {storageKey, ...verified},
      );
      return {status: 'ready', derivative: ready};
    } catch (error) {
      if (error instanceof MediaIdentityConflictError) {
        return {
          status: 'stale',
          derivative: await repository.getDerivative(assetId, derivativeKey),
        };
      }
      throw error;
    }
  } catch (error) {
    const errorCode = mediaWorkerErrorCode(error);
    try {
      const failed = await repository.markDerivativeFailed(
        assetId,
        derivativeKey,
        claim.claimToken,
        errorCode,
      );
      return {status: 'failed', derivative: failed, errorCode};
    } catch (claimError) {
      if (claimError instanceof MediaIdentityConflictError) {
        return {
          status: 'stale',
          derivative: await repository.getDerivative(assetId, derivativeKey),
          errorCode,
        };
      }
      throw claimError;
    }
  }
}

export function mediaWorkerErrorCode(error: unknown): string {
  if (error instanceof MediaProcessError) {
    switch (error.kind) {
      case 'timeout':
        return 'ffmpeg_timeout';
      case 'aborted':
        return 'ffmpeg_aborted';
      case 'spawn':
        return 'ffmpeg_spawn_failed';
      case 'exit':
        return 'ffmpeg_exit_nonzero';
    }
  }
  if (error instanceof MediaPlanCompileError) return 'media_plan_invalid';
  if (error instanceof MediaOutputVerificationError) return 'media_output_invalid';
  return 'media_worker_failed';
}

function assertVerifiedOutput(
  expected: Readonly<FfmpegExpectedOutput>,
  verified: VerifiedMediaOutput,
): void {
  if (verified.mimeType !== expected.mimeType) {
    throw new MediaOutputVerificationError(
      `Output MIME ${verified.mimeType} does not match ${expected.mimeType}`,
    );
  }
  expectedString(verified.container, expected.container, 'container');
  expectedString(verified.videoCodec, expected.videoCodec, 'videoCodec');
  expectedString(verified.videoProfile, expected.videoProfile, 'videoProfile');
  expectedString(verified.audioCodec, expected.audioCodec, 'audioCodec');
  expectedString(verified.colorSpace, expected.colorSpace, 'colorSpace');
  if (expected.dynamicRange !== undefined && verified.dynamicRange !== expected.dynamicRange) {
    throw new MediaOutputVerificationError(
      `Output dynamicRange ${String(verified.dynamicRange)} does not match ${expected.dynamicRange}`,
    );
  }
}

function expectedString(
  actual: string | undefined,
  expected: string | undefined,
  field: string,
): void {
  if (expected !== undefined && actual !== expected) {
    throw new MediaOutputVerificationError(
      `Output ${field} ${String(actual)} does not match ${expected}`,
    );
  }
}

function requiredText(value: string, name: string): string {
  const normalized = value.trim();
  if (!normalized || normalized.includes('\u0000')) {
    throw new TypeError(`${name} must be non-empty and contain no NUL bytes`);
  }
  return normalized;
}

function boundedPositiveInteger(value: number, name: string, maximum: number): number {
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new TypeError(`${name} must be a positive safe integer <= ${maximum}`);
  }
  return value;
}
