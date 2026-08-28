import {
  runMediaProcess,
  type MediaProcessRunner,
} from './media_process.js';

export interface TranscriptProcessRunnerOptions {
  whisperExecutable: string;
  whisperThreads: number;
  runProcess?: MediaProcessRunner;
}

const MAX_WHISPER_THREADS = 64;

/**
 * Runtime-only tuning wrapper for whisper.cpp. Thread count is intentionally
 * excluded from derivative identity because it changes resource usage, not the
 * semantic transcript plan or publication key.
 */
export function createTranscriptProcessRunner(
  options: TranscriptProcessRunnerOptions,
): MediaProcessRunner {
  const whisperExecutable = requiredText(
    options.whisperExecutable,
    'whisperExecutable',
  );
  const whisperThreads = boundedPositiveInteger(
    options.whisperThreads,
    'whisperThreads',
    MAX_WHISPER_THREADS,
  );
  const baseRunner = options.runProcess ?? runMediaProcess;

  return async (invocation, runOptions) => {
    if (invocation.executable !== whisperExecutable) {
      return await baseRunner(invocation, runOptions);
    }
    if (
      invocation.args.includes('--threads') ||
      invocation.args.includes('-t')
    ) {
      throw new TypeError('Transcript invocation already contains a thread override');
    }
    return await baseRunner(
      {
        executable: invocation.executable,
        args: Object.freeze([
          ...invocation.args,
          '--threads',
          String(whisperThreads),
        ]),
      },
      runOptions,
    );
  };
}

function requiredText(value: string, name: string): string {
  const normalized = value.trim();
  if (!normalized || normalized.includes('\u0000')) {
    throw new TypeError(`${name} must be non-empty and contain no NUL bytes`);
  }
  return normalized;
}

function boundedPositiveInteger(
  value: number,
  name: string,
  maximum: number,
): number {
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new TypeError(`${name} must be a positive safe integer <= ${maximum}`);
  }
  return value;
}
