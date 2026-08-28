import {spawn} from 'node:child_process';

export type MediaProcessFailureKind =
  | 'spawn'
  | 'exit'
  | 'timeout'
  | 'aborted'
  | 'output_limit';

export class MediaProcessError extends Error {
  constructor(
    readonly kind: MediaProcessFailureKind,
    message: string,
    options: {
      exitCode?: number | null;
      signal?: NodeJS.Signals | null;
      stderrTail?: string;
      cause?: unknown;
    } = {},
  ) {
    super(message, options.cause === undefined ? undefined : {cause: options.cause});
    this.name = 'MediaProcessError';
    this.exitCode = options.exitCode ?? null;
    this.signal = options.signal ?? null;
    this.stderrTail = options.stderrTail ?? '';
  }

  readonly exitCode: number | null;
  readonly signal: NodeJS.Signals | null;
  readonly stderrTail: string;
}

export interface MediaProcessInvocation {
  executable: string;
  args: readonly string[];
}

export interface MediaProcessRunOptions {
  timeoutMs: number;
  signal?: AbortSignal;
  killGraceMs?: number;
  maxStderrChars?: number;
  captureStdout?: boolean;
  maxStdoutChars?: number;
}

export interface MediaProcessResult {
  durationMs: number;
  stderrTail: string;
  stdoutText?: string;
}

const DEFAULT_KILL_GRACE_MS = 2_000;
const DEFAULT_STDERR_CHARS = 32 * 1024;
const DEFAULT_STDOUT_CHARS = 512 * 1024;
const MAX_TIMEOUT_MS = 60 * 60 * 1000;
const MAX_KILL_GRACE_MS = 30_000;
const MAX_STDERR_CHARS = 1024 * 1024;
const MAX_STDOUT_CHARS = 4 * 1024 * 1024;

export async function runMediaProcess(
  invocation: MediaProcessInvocation,
  options: MediaProcessRunOptions,
): Promise<MediaProcessResult> {
  const executable = requiredProcessText(invocation.executable, 'executable');
  const args = invocation.args.map((argument, index) =>
    requiredProcessArgument(argument, `args[${index}]`),
  );
  const timeoutMs = boundedPositiveInteger(options.timeoutMs, 'timeoutMs', MAX_TIMEOUT_MS);
  const killGraceMs = boundedPositiveInteger(
    options.killGraceMs ?? DEFAULT_KILL_GRACE_MS,
    'killGraceMs',
    MAX_KILL_GRACE_MS,
  );
  const maxStderrChars = boundedPositiveInteger(
    options.maxStderrChars ?? DEFAULT_STDERR_CHARS,
    'maxStderrChars',
    MAX_STDERR_CHARS,
  );
  const captureStdout = options.captureStdout ?? false;
  const maxStdoutChars = boundedPositiveInteger(
    options.maxStdoutChars ?? DEFAULT_STDOUT_CHARS,
    'maxStdoutChars',
    MAX_STDOUT_CHARS,
  );

  if (options.signal?.aborted) {
    throw new MediaProcessError('aborted', 'Media process was aborted before spawn');
  }

  const startedAt = Date.now();
  return await new Promise<MediaProcessResult>((resolve, reject) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(executable, args, {
        shell: false,
        windowsHide: true,
        stdio: ['ignore', captureStdout ? 'pipe' : 'ignore', 'pipe'],
      });
    } catch (error) {
      reject(new MediaProcessError('spawn', `Failed to spawn ${executable}`, {cause: error}));
      return;
    }

    let stdoutText = '';
    let stderrTail = '';
    let termination: 'timeout' | 'aborted' | 'output_limit' | null = null;
    let forceKillTimer: NodeJS.Timeout | null = null;
    let timeoutTimer: NodeJS.Timeout | null = null;
    let settled = false;

    const appendStderr = (chunk: string): void => {
      stderrTail += chunk;
      if (stderrTail.length > maxStderrChars) {
        stderrTail = stderrTail.slice(stderrTail.length - maxStderrChars);
      }
    };

    const terminate = (reason: 'timeout' | 'aborted' | 'output_limit'): void => {
      if (termination !== null || settled) return;
      termination = reason;
      if (child.exitCode !== null || child.signalCode !== null) return;
      try {
        child.kill('SIGTERM');
      } catch {
        // Close/error handling below remains authoritative.
      }
      forceKillTimer = setTimeout(() => {
        if (child.exitCode !== null || child.signalCode !== null) return;
        try {
          child.kill('SIGKILL');
        } catch {
          // Close/error handling below remains authoritative.
        }
      }, killGraceMs);
      forceKillTimer.unref();
    };

    child.stdout?.setEncoding('utf8');
    child.stdout?.on('data', (chunk: string) => {
      if (termination !== null) return;
      if (stdoutText.length + chunk.length > maxStdoutChars) {
        stdoutText = '';
        terminate('output_limit');
        return;
      }
      stdoutText += chunk;
    });
    child.stderr?.setEncoding('utf8');
    child.stderr?.on('data', (chunk: string) => appendStderr(chunk));

    const cleanup = (): void => {
      if (timeoutTimer !== null) clearTimeout(timeoutTimer);
      if (forceKillTimer !== null) clearTimeout(forceKillTimer);
      options.signal?.removeEventListener('abort', abortListener);
    };

    const abortListener = (): void => terminate('aborted');
    options.signal?.addEventListener('abort', abortListener, {once: true});
    if (options.signal?.aborted) abortListener();

    timeoutTimer = setTimeout(() => terminate('timeout'), timeoutMs);
    timeoutTimer.unref();

    child.once('error', (error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(
        new MediaProcessError('spawn', `Media process failed to spawn ${executable}`, {
          stderrTail,
          cause: error,
        }),
      );
    });

    child.once('close', (code, signal) => {
      if (settled) return;
      settled = true;
      cleanup();
      const durationMs = Math.max(0, Date.now() - startedAt);
      if (termination === 'timeout') {
        reject(
          new MediaProcessError('timeout', `Media process exceeded ${timeoutMs} ms`, {
            exitCode: code,
            signal,
            stderrTail,
          }),
        );
        return;
      }
      if (termination === 'aborted') {
        reject(
          new MediaProcessError('aborted', 'Media process was aborted', {
            exitCode: code,
            signal,
            stderrTail,
          }),
        );
        return;
      }
      if (termination === 'output_limit') {
        reject(
          new MediaProcessError(
            'output_limit',
            `Media process stdout exceeded ${maxStdoutChars} characters`,
            {exitCode: code, signal, stderrTail},
          ),
        );
        return;
      }
      if (code !== 0) {
        reject(
          new MediaProcessError('exit', `Media process exited with code ${String(code)}`, {
            exitCode: code,
            signal,
            stderrTail,
          }),
        );
        return;
      }
      resolve({
        durationMs,
        stderrTail,
        ...(captureStdout ? {stdoutText} : {}),
      });
    });
  });
}

function requiredProcessText(value: string, name: string): string {
  const normalized = value.trim();
  if (!normalized || normalized.includes('\u0000')) {
    throw new TypeError(`${name} must be non-empty and contain no NUL bytes`);
  }
  return normalized;
}

function requiredProcessArgument(value: string, name: string): string {
  if (value.includes('\u0000')) {
    throw new TypeError(`${name} must contain no NUL bytes`);
  }
  return value;
}

function boundedPositiveInteger(value: number, name: string, maximum: number): number {
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new TypeError(`${name} must be a positive safe integer <= ${maximum}`);
  }
  return value;
}
