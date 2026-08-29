import {readFile, stat} from 'node:fs/promises';
import {join} from 'node:path';
import {
  MediaOutputPublicationError,
  mediaAttemptStorageKey,
  type MediaOutputPublisher,
} from './media_ffmpeg_worker.js';
import {MediaProcessError, runMediaProcess, type MediaProcessRunner} from './media_process.js';
import {
  MediaIdentityConflictError,
  type MediaDerivativeClaim,
  type MediaDerivativeRecord,
  type PostgresMediaRepository,
} from './media_repository.js';
import type {CanonicalJsonValue, MediaDerivativePlan} from './media.js';

export const TRANSCRIPT_MEDIA_PROCESSOR = 'speech-transcript-v1';

export type TranscriptWorkerRepository = Pick<
  PostgresMediaRepository,
  'getDerivative' | 'markDerivativeReady'
>;

export interface TranscriptClaimedJob {
  inputPath: string;
  workDirectory: string;
}

export interface TranscriptProcessorOptions {
  ffmpegExecutable?: string;
  whisperExecutable?: string;
  whisperModelPath: string;
  prepareTimeoutMs: number;
  whisperTimeoutMs: number;
  signal?: AbortSignal;
  runProcess?: MediaProcessRunner;
  maxVttBytes?: number;
}

export interface TranscriptProcessorResult {
  status: 'ready' | 'stale';
  derivative: MediaDerivativeRecord | null;
}

export interface VerifiedWebVtt {
  mimeType: 'text/vtt';
  sizeBytes: number;
  durationMs: number;
  metadata: Readonly<Record<string, CanonicalJsonValue>>;
}

export class TranscriptWorkerError extends Error {
  constructor(
    public readonly errorCode: string,
    message: string,
    options?: ErrorOptions,
  ) {
    super(message, options);
    this.name = 'TranscriptWorkerError';
  }
}

interface TranscriptPlanContract {
  durationMs: number;
  language: string;
  whisperLanguage: string;
}

const DEFAULT_MAX_VTT_BYTES = 4 * 1024 * 1024;
const MAX_MAX_VTT_BYTES = 16 * 1024 * 1024;
const MAX_CUES = 20_000;
const MAX_LINE_CHARS = 16 * 1024;
const DURATION_TOLERANCE_MS = 5_000;

export async function processClaimedTranscriptDerivative(
  repository: TranscriptWorkerRepository,
  claim: MediaDerivativeClaim,
  job: TranscriptClaimedJob,
  publishOutput: MediaOutputPublisher,
  options: TranscriptProcessorOptions,
): Promise<TranscriptProcessorResult> {
  assertClaim(claim);
  const contract = transcriptPlanContract(claim.derivative.plan);
  const ffmpegExecutable = requiredText(
    options.ffmpegExecutable ?? 'ffmpeg',
    'FFmpeg executable',
  );
  const whisperExecutable = requiredText(
    options.whisperExecutable ?? 'whisper-cli',
    'whisper executable',
  );
  const whisperModelPath = requiredText(options.whisperModelPath, 'whisper model path');
  const prepareTimeoutMs = positiveSafeInteger(options.prepareTimeoutMs, 'prepareTimeoutMs');
  const whisperTimeoutMs = positiveSafeInteger(options.whisperTimeoutMs, 'whisperTimeoutMs');
  const maxVttBytes = boundedPositiveInteger(
    options.maxVttBytes ?? DEFAULT_MAX_VTT_BYTES,
    'maxVttBytes',
    MAX_MAX_VTT_BYTES,
  );
  abortIfRequested(options.signal);

  const preparedAudioPath = join(job.workDirectory, 'transcript-input.wav');
  const outputBase = join(job.workDirectory, 'transcript-output');
  const outputPath = `${outputBase}.vtt`;
  const runner = options.runProcess ?? runMediaProcess;

  await runStage(
    runner,
    {
      executable: ffmpegExecutable,
      args: Object.freeze([
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-n',
        '-i',
        job.inputPath,
        '-map',
        '0:a:0',
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-c:a',
        'pcm_s16le',
        '-f',
        'wav',
        preparedAudioPath,
      ]),
    },
    prepareTimeoutMs,
    options.signal,
    'transcript_audio_prepare',
  );

  await runStage(
    runner,
    {
      executable: whisperExecutable,
      args: Object.freeze([
        '--model',
        whisperModelPath,
        '--file',
        preparedAudioPath,
        '--output-vtt',
        '--output-file',
        outputBase,
        '--no-prints',
        '--language',
        contract.whisperLanguage,
      ]),
    },
    whisperTimeoutMs,
    options.signal,
    'transcript_engine',
  );

  const verified = await verifyWebVttOutput(
    outputPath,
    contract.durationMs,
    contract.language,
    maxVttBytes,
  );
  const storageKey = mediaAttemptStorageKey(
    claim.derivative.assetId,
    claim.derivative.derivativeKey,
    claim.claimToken,
    'captions',
  );

  try {
    await publishOutput({
      assetId: claim.derivative.assetId,
      derivativeKey: claim.derivative.derivativeKey,
      claimToken: claim.claimToken,
      outputPath,
      storageKey,
      plan: claim.derivative.plan,
      verifiedOutput: verified,
      ...(options.signal === undefined ? {} : {signal: options.signal}),
    });
  } catch (error) {
    throw new TranscriptWorkerError(
      'transcript_publish_failed',
      `Failed to publish transcript derivative ${storageKey}`,
      {cause: error},
    );
  }

  try {
    const ready = await repository.markDerivativeReady(
      claim.derivative.assetId,
      claim.derivative.derivativeKey,
      claim.claimToken,
      {storageKey, ...verified},
    );
    return {status: 'ready', derivative: ready};
  } catch (error) {
    if (error instanceof MediaIdentityConflictError) {
      return {
        status: 'stale',
        derivative: await repository.getDerivative(
          claim.derivative.assetId,
          claim.derivative.derivativeKey,
        ),
      };
    }
    throw error;
  }
}

export function transcriptPlanContract(plan: MediaDerivativePlan): TranscriptPlanContract {
  if (plan.purpose !== 'captions' || plan.processor !== TRANSCRIPT_MEDIA_PROCESSOR) {
    throw new TranscriptWorkerError(
      'transcript_plan_invalid',
      `Unsupported transcript plan ${plan.purpose}/${plan.processor}`,
    );
  }
  const parameters = recordValue(plan.parameters, 'transcript parameters');
  const source = recordField(parameters, 'source', 'transcript parameters');
  const output = recordField(parameters, 'output', 'transcript parameters');
  const durationMs = positiveIntegerField(source, 'durationMs', 'transcript source');
  const format = stringField(output, 'format', 'transcript output');
  if (format !== 'webvtt') {
    throw new TranscriptWorkerError(
      'transcript_plan_invalid',
      `Transcript output format must be webvtt, got ${format}`,
    );
  }
  const language = stringField(output, 'language', 'transcript output').trim();
  if (!language || language.includes('\u0000')) {
    throw new TranscriptWorkerError(
      'transcript_plan_invalid',
      'Transcript language must be non-empty',
    );
  }
  return {
    durationMs,
    language,
    whisperLanguage: whisperLanguageCode(language),
  };
}

export async function verifyWebVttOutput(
  outputPath: string,
  expectedDurationMs: number,
  language: string,
  maxBytes = DEFAULT_MAX_VTT_BYTES,
): Promise<VerifiedWebVtt> {
  positiveSafeInteger(expectedDurationMs, 'expectedDurationMs');
  boundedPositiveInteger(maxBytes, 'maxBytes', MAX_MAX_VTT_BYTES);
  const info = await stat(outputPath);
  if (!info.isFile() || !Number.isSafeInteger(info.size) || info.size <= 0) {
    throw new TranscriptWorkerError(
      'transcript_output_invalid',
      'Transcript output must be a non-empty regular file',
    );
  }
  if (info.size > maxBytes) {
    throw new TranscriptWorkerError(
      'transcript_output_invalid',
      `Transcript output exceeds ${maxBytes} bytes`,
    );
  }
  const bytes = await readFile(outputPath);
  if (bytes.length !== info.size) {
    throw new TranscriptWorkerError(
      'transcript_output_invalid',
      'Transcript output size changed while verifying',
    );
  }
  const text = bytes.toString('utf8');
  if (Buffer.from(text, 'utf8').length !== bytes.length || text.includes('\uFFFD')) {
    throw new TranscriptWorkerError(
      'transcript_output_invalid',
      'Transcript output must be valid UTF-8',
    );
  }
  const cueCount = validateWebVtt(text, expectedDurationMs);
  return Object.freeze({
    mimeType: 'text/vtt',
    sizeBytes: bytes.length,
    durationMs: expectedDurationMs,
    metadata: Object.freeze({cueCount, language}),
  });
}

function validateWebVtt(text: string, expectedDurationMs: number): number {
  if (text.includes('\u0000')) {
    throw invalidVtt('Transcript WebVTT contains a NUL byte');
  }
  const normalized = text.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
  const lines = normalized.split('\n');
  if (lines[0]?.trim() !== 'WEBVTT') {
    throw invalidVtt('Transcript WebVTT must begin with WEBVTT');
  }
  if (lines.some((line) => line.length > MAX_LINE_CHARS)) {
    throw invalidVtt(`Transcript WebVTT line exceeds ${MAX_LINE_CHARS} characters`);
  }

  let index = 1;
  let cueCount = 0;
  let previousStartMs = -1;
  while (index < lines.length) {
    while (index < lines.length && lines[index]?.trim() === '') index += 1;
    if (index >= lines.length) break;

    const first = lines[index] ?? '';
    let timingLine = first;
    if (!first.includes('-->')) {
      if (/^(NOTE|STYLE|REGION)(?:\s|$)/.test(first)) {
        throw invalidVtt('Transcript WebVTT may contain only cues');
      }
      index += 1;
      timingLine = lines[index] ?? '';
    }
    const timing = parseCueTiming(timingLine);
    if (timing.startMs < previousStartMs) {
      throw invalidVtt('Transcript WebVTT cue starts are not monotonic');
    }
    if (timing.endMs <= timing.startMs) {
      throw invalidVtt('Transcript WebVTT cue end must follow its start');
    }
    if (timing.endMs > expectedDurationMs + DURATION_TOLERANCE_MS) {
      throw invalidVtt('Transcript WebVTT cue exceeds source duration tolerance');
    }
    previousStartMs = timing.startMs;
    cueCount += 1;
    if (cueCount > MAX_CUES) {
      throw invalidVtt(`Transcript WebVTT exceeds ${MAX_CUES} cues`);
    }

    index += 1;
    let textLines = 0;
    while (index < lines.length && lines[index]?.trim() !== '') {
      const line = lines[index] ?? '';
      if (line.includes('-->')) {
        throw invalidVtt('Transcript WebVTT cue is missing a blank separator');
      }
      textLines += 1;
      index += 1;
    }
    if (textLines === 0) {
      throw invalidVtt('Transcript WebVTT cue must contain text');
    }
  }
  return cueCount;
}

function parseCueTiming(value: string): {startMs: number; endMs: number} {
  const match = value.match(
    /^(\d{2,}:\d{2}:\d{2}\.\d{3}|\d{2}:\d{2}\.\d{3})\s+-->\s+(\d{2,}:\d{2}:\d{2}\.\d{3}|\d{2}:\d{2}\.\d{3})(?:\s+[^\r\n]+)?$/,
  );
  if (match === null) throw invalidVtt(`Invalid WebVTT cue timing: ${value}`);
  return {startMs: timestampMs(match[1]!), endMs: timestampMs(match[2]!)};
}

function timestampMs(value: string): number {
  const parts = value.split(':');
  const secondsPart = parts.pop();
  const minutesPart = parts.pop();
  if (secondsPart === undefined || minutesPart === undefined) {
    throw invalidVtt(`Invalid WebVTT timestamp ${value}`);
  }
  const [secondsText, millisText] = secondsPart.split('.');
  const hoursText = parts.pop() ?? '0';
  const hours = Number(hoursText);
  const minutes = Number(minutesPart);
  const seconds = Number(secondsText);
  const millis = Number(millisText);
  if (
    !Number.isSafeInteger(hours) ||
    !Number.isSafeInteger(minutes) ||
    !Number.isSafeInteger(seconds) ||
    !Number.isSafeInteger(millis) ||
    hours < 0 ||
    minutes < 0 ||
    minutes > 59 ||
    seconds < 0 ||
    seconds > 59 ||
    millis < 0 ||
    millis > 999
  ) {
    throw invalidVtt(`Invalid WebVTT timestamp ${value}`);
  }
  const total = ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis;
  if (!Number.isSafeInteger(total)) throw invalidVtt('WebVTT timestamp exceeds safe range');
  return total;
}

async function runStage(
  runner: MediaProcessRunner,
  invocation: {executable: string; args: readonly string[]},
  timeoutMs: number,
  signal: AbortSignal | undefined,
  codePrefix: 'transcript_audio_prepare' | 'transcript_engine',
): Promise<void> {
  try {
    await runner(
      invocation,
      signal === undefined ? {timeoutMs} : {timeoutMs, signal},
    );
  } catch (error) {
    if (error instanceof MediaProcessError) {
      const suffix = error.kind === 'timeout'
        ? 'timeout'
        : error.kind === 'aborted'
          ? 'aborted'
          : 'failed';
      throw new TranscriptWorkerError(
        `${codePrefix}_${suffix}`,
        `${codePrefix} failed: ${error.message}`,
        {cause: error},
      );
    }
    throw new TranscriptWorkerError(
      `${codePrefix}_failed`,
      `${codePrefix} failed`,
      {cause: error},
    );
  }
}

function assertClaim(claim: MediaDerivativeClaim): void {
  if (
    claim.derivative.state !== 'processing' ||
    claim.derivative.purpose !== 'captions' ||
    claim.derivative.plan.processor !== TRANSCRIPT_MEDIA_PROCESSOR ||
    !claim.claimToken.trim()
  ) {
    throw new TranscriptWorkerError(
      'media_claim_invalid',
      'Transcript worker received an invalid dispatcher-owned claim',
    );
  }
}

function whisperLanguageCode(language: string): string {
  if (language.toLowerCase() === 'auto') return 'auto';
  const primary = language.split('-')[0]?.toLowerCase() ?? '';
  if (!/^[a-z]{2,3}$/.test(primary)) {
    throw new TranscriptWorkerError(
      'transcript_plan_invalid',
      `Transcript language ${language} is not usable by whisper`,
    );
  }
  return primary;
}

function recordValue(value: unknown, name: string): Readonly<Record<string, unknown>> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TranscriptWorkerError('transcript_plan_invalid', `${name} must be an object`);
  }
  return value as Readonly<Record<string, unknown>>;
}

function recordField(
  value: Readonly<Record<string, unknown>>,
  field: string,
  name: string,
): Readonly<Record<string, unknown>> {
  return recordValue(value[field], `${name}.${field}`);
}

function stringField(
  value: Readonly<Record<string, unknown>>,
  field: string,
  name: string,
): string {
  const result = value[field];
  if (typeof result !== 'string') {
    throw new TranscriptWorkerError(
      'transcript_plan_invalid',
      `${name}.${field} must be a string`,
    );
  }
  return result;
}

function positiveIntegerField(
  value: Readonly<Record<string, unknown>>,
  field: string,
  name: string,
): number {
  const result = value[field];
  if (!Number.isSafeInteger(result) || (result as number) <= 0) {
    throw new TranscriptWorkerError(
      'transcript_plan_invalid',
      `${name}.${field} must be a positive safe integer`,
    );
  }
  return result as number;
}

function requiredText(value: string, name: string): string {
  const normalized = value.trim();
  if (!normalized || normalized.includes('\u0000')) {
    throw new TypeError(`${name} must be non-empty and contain no NUL bytes`);
  }
  return normalized;
}

function positiveSafeInteger(value: number, name: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new TypeError(`${name} must be a positive safe integer`);
  }
  return value;
}

function boundedPositiveInteger(value: number, name: string, maximum: number): number {
  const normalized = positiveSafeInteger(value, name);
  if (normalized > maximum) throw new TypeError(`${name} must be <= ${maximum}`);
  return normalized;
}

function abortIfRequested(signal?: AbortSignal): void {
  if (!signal?.aborted) return;
  if (signal.reason instanceof Error) throw signal.reason;
  const error = new Error('Transcript worker aborted');
  error.name = 'AbortError';
  throw error;
}

function invalidVtt(message: string): TranscriptWorkerError {
  return new TranscriptWorkerError('transcript_output_invalid', message);
}
