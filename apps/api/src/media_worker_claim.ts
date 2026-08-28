import type {MediaDerivativeClaim} from './media_repository.js';

export const MEDIA_CLAIM_COMPLETION_MARGIN_MS = 30_000;

export interface MediaClaimAttemptSignal {
  signal: AbortSignal;
  deadlineSignal: AbortSignal;
  dispose: () => void;
}

/**
 * Produces a signal that aborts before a dispatcher-owned lease reaches its
 * completion margin. Returning null means the claim is already too close to
 * expiry to begin any source I/O or processing safely.
 */
export function createMediaClaimAttemptSignal(
  claim: MediaDerivativeClaim,
  outerSignal?: AbortSignal,
): MediaClaimAttemptSignal | null {
  const leaseExpiresAt = claim.derivative.leaseExpiresAt?.getTime();
  if (leaseExpiresAt === undefined || !Number.isFinite(leaseExpiresAt)) return null;
  const delayMs = leaseExpiresAt - Date.now() - MEDIA_CLAIM_COMPLETION_MARGIN_MS;
  if (delayMs <= 0) return null;

  const controller = new AbortController();
  const timer = setTimeout(() => {
    const error = new Error('Media claim reached its completion deadline');
    error.name = 'AbortError';
    controller.abort(error);
  }, delayMs);
  timer.unref();

  return {
    signal: outerSignal === undefined
      ? controller.signal
      : AbortSignal.any([outerSignal, controller.signal]),
    deadlineSignal: controller.signal,
    dispose: () => clearTimeout(timer),
  };
}

export function mediaAttemptFailureCode(
  error: unknown,
  outerSignal: AbortSignal | undefined,
  deadlineSignal: AbortSignal,
  fallback: string,
): string {
  if (outerSignal?.aborted) return 'media_worker_aborted';
  if (deadlineSignal.aborted) return 'media_claim_deadline';
  if (isAbortError(error)) return 'media_worker_aborted';
  return fallback;
}

export function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError';
}
