import {stat} from 'node:fs/promises';
import {type Stats} from 'node:fs';
import {type CanonicalJsonValue, type MediaDerivativePlan} from './media.js';
import {
  MediaOutputVerificationError,
  type MediaOutputVerificationRequest,
  type MediaOutputVerifier,
  type MediaProcessRunner,
  type VerifiedMediaOutput,
} from './media_ffmpeg_worker.js';
import {runMediaProcess} from './media_process.js';

export interface FfprobeVerifierOptions {
  executable?: string;
  timeoutMs?: number;
  maxJsonChars?: number;
  runProcess?: MediaProcessRunner;
  statFile?: (path: string) => Promise<Pick<Stats, 'size' | 'isFile'>>;
}

const DEFAULT_TIMEOUT_MS = 15_000;
const DEFAULT_JSON_CHARS = 512 * 1024;
const MAX_TIMEOUT_MS = 2 * 60 * 1000;
const MAX_JSON_CHARS = 4 * 1024 * 1024;
const HDR_TRANSFERS = new Set(['smpte2084', 'arib-std-b67']);

export function createFfprobeOutputVerifier(
  options: FfprobeVerifierOptions = {},
): MediaOutputVerifier {
  const executable = requiredText(options.executable ?? 'ffprobe', 'ffprobe executable');
  const timeoutMs = boundedPositiveInteger(
    options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    'ffprobe timeoutMs',
    MAX_TIMEOUT_MS,
  );
  const maxJsonChars = boundedPositiveInteger(
    options.maxJsonChars ?? DEFAULT_JSON_CHARS,
    'ffprobe maxJsonChars',
    MAX_JSON_CHARS,
  );
  const runProcess = options.runProcess ?? runMediaProcess;
  const statFile = options.statFile ?? stat;

  return async (request) => {
    const result = await runProcess(
      {
        executable,
        args: ffprobeArgs(request.outputPath),
      },
      {
        timeoutMs,
        captureStdout: true,
        maxStdoutChars: maxJsonChars,
        ...(request.signal === undefined ? {} : {signal: request.signal}),
      },
    );
    const json = result.stdoutText;
    if (json === undefined || json.trim().length === 0) {
      throw new MediaOutputVerificationError('FFprobe produced no JSON output');
    }

    let decoded: unknown;
    try {
      decoded = JSON.parse(json) as unknown;
    } catch (error) {
      throw new MediaOutputVerificationError(
        `FFprobe returned invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
      );
    }

    const file = await statFile(request.outputPath);
    if (!file.isFile() || !Number.isSafeInteger(file.size) || file.size <= 0) {
      throw new MediaOutputVerificationError('Normalized media output is not a non-empty regular file');
    }
    return verifyProbeDocument(request, decoded, file.size);
  };
}

export function ffprobeArgs(outputPath: string): readonly string[] {
  return Object.freeze([
    '-v',
    'error',
    '-print_format',
    'json',
    '-show_format',
    '-show_streams',
    '-show_entries',
    'format=format_name,duration,size:stream=index,codec_type,codec_name,profile,width,height,pix_fmt,color_range,color_space,color_transfer,color_primaries,sample_rate,channels,avg_frame_rate,duration',
    outputPath,
  ]);
}

interface ProbeStream {
  codecType: string;
  codecName: string | null;
  profile: string | null;
  width: number | null;
  height: number | null;
  pixelFormat: string | null;
  colorRange: string | null;
  colorSpace: string | null;
  colorTransfer: string | null;
  colorPrimaries: string | null;
  sampleRateHz: number | null;
  channels: number | null;
  averageFrameRate: number | null;
  durationMs: number | null;
}

interface ProbeDocument {
  formatName: string | null;
  durationMs: number | null;
  streams: readonly ProbeStream[];
}

function verifyProbeDocument(
  request: MediaOutputVerificationRequest,
  decoded: unknown,
  sizeBytes: number,
): VerifiedMediaOutput {
  const probe = parseProbeDocument(decoded);
  switch (request.plan.processor) {
    case 'ffmpeg-video-normalize-v1':
      return verifyPlayback(request.plan, request.expectedOutput.mimeType, probe, sizeBytes);
    case 'ffmpeg-poster-v1':
      return verifyPoster(request.plan, request.expectedOutput.mimeType, probe, sizeBytes);
    case 'ffmpeg-audio-normalize-v1':
      return verifyAudio(request.plan, request.expectedOutput.mimeType, probe, sizeBytes);
    default:
      throw new MediaOutputVerificationError(
        `FFprobe verifier does not support processor ${request.plan.processor}`,
      );
  }
}

function verifyPlayback(
  plan: MediaDerivativePlan,
  mimeType: string,
  probe: ProbeDocument,
  sizeBytes: number,
): VerifiedMediaOutput {
  const videoStreams = probe.streams.filter((stream) => stream.codecType === 'video');
  const audioStreams = probe.streams.filter((stream) => stream.codecType === 'audio');
  const otherStreams = probe.streams.filter(
    (stream) => stream.codecType !== 'video' && stream.codecType !== 'audio',
  );
  if (videoStreams.length !== 1 || otherStreams.length !== 0 || audioStreams.length > 1) {
    throw new MediaOutputVerificationError('Playback derivative must contain one video, at most one audio and no other streams');
  }
  const parameters = canonicalRecord(plan.parameters, 'playback parameters');
  const source = recordField(parameters, 'source', 'playback parameters');
  const output = recordField(parameters, 'output', 'playback parameters');
  const hasAudio = booleanField(source, 'hasAudio', 'playback source');
  if (audioStreams.length !== (hasAudio ? 1 : 0)) {
    throw new MediaOutputVerificationError(
      `Playback derivative audio stream count ${audioStreams.length} does not match source policy`,
    );
  }

  const video = videoStreams[0]!;
  requireEqual(video.codecName, 'h264', 'video codec');
  requireEqual(normalizeProfile(video.profile), 'main', 'video profile');
  requireEqual(video.pixelFormat, 'yuv420p', 'pixel format');
  requireEqual(video.colorPrimaries, 'bt709', 'color primaries');
  requireEqual(video.colorTransfer, 'bt709', 'color transfer');
  requireEqual(video.colorSpace, 'bt709', 'color matrix');
  if (video.colorRange !== 'tv' && video.colorRange !== 'limited') {
    throw new MediaOutputVerificationError(`Playback color range must be limited/tv, got ${String(video.colorRange)}`);
  }
  if (video.width === null || video.height === null || video.width <= 0 || video.height <= 0) {
    throw new MediaOutputVerificationError('Playback derivative requires positive video dimensions');
  }
  if (video.width % 2 !== 0 || video.height % 2 !== 0) {
    throw new MediaOutputVerificationError('Playback derivative dimensions must be even');
  }

  const sourceWidth = positiveIntegerField(source, 'width', 'playback source');
  const sourceHeight = positiveIntegerField(source, 'height', 'playback source');
  const rotation = integerField(source, 'rotationDegrees', 'playback source');
  const rotated = rotation === 90 || rotation === 270;
  const displayWidth = rotated ? sourceHeight : sourceWidth;
  const displayHeight = rotated ? sourceWidth : sourceHeight;
  const maxLong = positiveIntegerField(output, 'maxLongEdge', 'playback output');
  const maxShort = positiveIntegerField(output, 'maxShortEdge', 'playback output');
  const landscape = displayWidth >= displayHeight;
  const maxWidth = landscape ? maxLong : maxShort;
  const maxHeight = landscape ? maxShort : maxLong;
  if (
    video.width > Math.min(displayWidth, maxWidth) ||
    video.height > Math.min(displayHeight, maxHeight)
  ) {
    throw new MediaOutputVerificationError('Playback derivative exceeds source or launch-profile dimensions');
  }
  const maxFps = positiveNumberField(output, 'maxFps', 'playback output');
  if (video.averageFrameRate === null || video.averageFrameRate <= 0 || video.averageFrameRate > maxFps + 0.01) {
    throw new MediaOutputVerificationError(
      `Playback average frame rate ${String(video.averageFrameRate)} exceeds ${maxFps}`,
    );
  }

  const audio = audioStreams[0];
  if (audio !== undefined) {
    requireEqual(audio.codecName, 'aac', 'audio codec');
    if (audio.sampleRateHz !== 48_000) {
      throw new MediaOutputVerificationError(`Playback audio sample rate must be 48000, got ${String(audio.sampleRateHz)}`);
    }
    if (audio.channels === null || audio.channels <= 0 || audio.channels > 2) {
      throw new MediaOutputVerificationError(`Playback audio channels must be 1-2, got ${String(audio.channels)}`);
    }
  }

  const durationMs = requiredDuration(probe, video);
  requireDurationNearPlan(plan, durationMs);
  requireMp4Format(probe.formatName);
  return {
    mimeType,
    sizeBytes,
    width: video.width,
    height: video.height,
    durationMs,
    container: 'mp4',
    videoCodec: 'h264',
    videoProfile: 'main',
    ...(audio === undefined ? {} : {audioCodec: 'aac'}),
    colorSpace: 'bt709',
    dynamicRange: HDR_TRANSFERS.has(video.colorTransfer ?? '') ? 'hdr' : 'sdr',
    metadata: {
      pixelFormat: video.pixelFormat,
      frameRate: video.averageFrameRate,
      colorPrimaries: video.colorPrimaries,
      colorTransfer: video.colorTransfer,
      colorMatrix: video.colorSpace,
      colorRange: video.colorRange,
      ...(audio === undefined
        ? {}
        : {audioSampleRateHz: audio.sampleRateHz, audioChannels: audio.channels}),
    },
  };
}

function verifyPoster(
  plan: MediaDerivativePlan,
  mimeType: string,
  probe: ProbeDocument,
  sizeBytes: number,
): VerifiedMediaOutput {
  const videoStreams = probe.streams.filter((stream) => stream.codecType === 'video');
  const otherStreams = probe.streams.filter((stream) => stream.codecType !== 'video');
  if (videoStreams.length !== 1 || otherStreams.length !== 0) {
    throw new MediaOutputVerificationError('Poster derivative must contain exactly one video/image stream');
  }
  const video = videoStreams[0]!;
  requireEqual(video.codecName, 'mjpeg', 'poster codec');
  if (video.width === null || video.height === null || video.width <= 0 || video.height <= 0) {
    throw new MediaOutputVerificationError('Poster requires positive dimensions');
  }
  if (video.width % 2 !== 0 || video.height % 2 !== 0) {
    throw new MediaOutputVerificationError('Poster dimensions must be even');
  }
  const output = recordField(canonicalRecord(plan.parameters, 'poster parameters'), 'output', 'poster parameters');
  const maxLongEdge = positiveIntegerField(output, 'maxLongEdge', 'poster output');
  if (Math.max(video.width, video.height) > maxLongEdge) {
    throw new MediaOutputVerificationError(`Poster exceeds maxLongEdge ${maxLongEdge}`);
  }
  return {
    mimeType,
    sizeBytes,
    width: video.width,
    height: video.height,
    dynamicRange: 'sdr',
    metadata: {
      pixelFormat: video.pixelFormat,
      colorPrimaries: video.colorPrimaries,
      colorTransfer: video.colorTransfer,
      colorMatrix: video.colorSpace,
      colorRange: video.colorRange,
    },
  };
}

function verifyAudio(
  plan: MediaDerivativePlan,
  mimeType: string,
  probe: ProbeDocument,
  sizeBytes: number,
): VerifiedMediaOutput {
  const audioStreams = probe.streams.filter((stream) => stream.codecType === 'audio');
  const otherStreams = probe.streams.filter((stream) => stream.codecType !== 'audio');
  if (audioStreams.length !== 1 || otherStreams.length !== 0) {
    throw new MediaOutputVerificationError('Audio derivative must contain exactly one audio stream');
  }
  const audio = audioStreams[0]!;
  requireEqual(audio.codecName, 'aac', 'audio codec');
  if (audio.sampleRateHz !== 48_000) {
    throw new MediaOutputVerificationError(`Audio derivative sample rate must be 48000, got ${String(audio.sampleRateHz)}`);
  }
  if (audio.channels === null || audio.channels <= 0 || audio.channels > 2) {
    throw new MediaOutputVerificationError(`Audio derivative channels must be 1-2, got ${String(audio.channels)}`);
  }
  const durationMs = requiredDuration(probe, audio);
  requireDurationNearPlan(plan, durationMs);
  requireMp4Format(probe.formatName);
  return {
    mimeType,
    sizeBytes,
    durationMs,
    container: 'mp4',
    audioCodec: 'aac',
    metadata: {audioSampleRateHz: audio.sampleRateHz, audioChannels: audio.channels},
  };
}

function parseProbeDocument(value: unknown): ProbeDocument {
  const root = unknownRecord(value, 'FFprobe root');
  const streamValues = root.streams;
  if (!Array.isArray(streamValues)) {
    throw new MediaOutputVerificationError('FFprobe streams must be an array');
  }
  const streams = streamValues.map((stream, index) => parseProbeStream(stream, index));
  const format = root.format === undefined ? null : unknownRecord(root.format, 'FFprobe format');
  return {
    formatName: optionalString(format?.format_name),
    durationMs: optionalSecondsAsMilliseconds(format?.duration, 'format.duration'),
    streams,
  };
}

function parseProbeStream(value: unknown, index: number): ProbeStream {
  const stream = unknownRecord(value, `FFprobe stream ${index}`);
  const codecType = requiredString(stream.codec_type, `stream ${index}.codec_type`);
  return {
    codecType,
    codecName: optionalString(stream.codec_name),
    profile: optionalString(stream.profile),
    width: optionalPositiveInteger(stream.width, `stream ${index}.width`),
    height: optionalPositiveInteger(stream.height, `stream ${index}.height`),
    pixelFormat: optionalString(stream.pix_fmt),
    colorRange: optionalString(stream.color_range),
    colorSpace: optionalString(stream.color_space),
    colorTransfer: optionalString(stream.color_transfer),
    colorPrimaries: optionalString(stream.color_primaries),
    sampleRateHz: optionalPositiveIntegerString(stream.sample_rate, `stream ${index}.sample_rate`),
    channels: optionalPositiveInteger(stream.channels, `stream ${index}.channels`),
    averageFrameRate: optionalRational(stream.avg_frame_rate, `stream ${index}.avg_frame_rate`),
    durationMs: optionalSecondsAsMilliseconds(stream.duration, `stream ${index}.duration`),
  };
}

function requiredDuration(probe: ProbeDocument, stream: ProbeStream): number {
  const durationMs = probe.durationMs ?? stream.durationMs;
  if (durationMs === null || durationMs <= 0) {
    throw new MediaOutputVerificationError('Normalized media must expose a positive duration');
  }
  return durationMs;
}

function requireDurationNearPlan(plan: MediaDerivativePlan, actualMs: number): void {
  const source = recordField(canonicalRecord(plan.parameters, 'plan parameters'), 'source', 'plan parameters');
  const expectedMs = positiveIntegerField(source, 'durationMs', 'plan source');
  const toleranceMs = Math.max(250, Math.round(expectedMs * 0.02));
  if (Math.abs(actualMs - expectedMs) > toleranceMs) {
    throw new MediaOutputVerificationError(
      `Output duration ${actualMs} ms differs from ${expectedMs} ms by more than ${toleranceMs} ms`,
    );
  }
}

function requireMp4Format(formatName: string | null): void {
  if (formatName === null) throw new MediaOutputVerificationError('FFprobe did not report a container format');
  const formats = new Set(formatName.split(',').map((value) => value.trim().toLowerCase()));
  if (!formats.has('mp4') && !formats.has('mov') && !formats.has('m4a')) {
    throw new MediaOutputVerificationError(`Output is not an MP4-family container: ${formatName}`);
  }
}

function normalizeProfile(value: string | null): string | null {
  if (value === null) return null;
  const normalized = value.trim().toLowerCase().replace(/\s+/g, '-');
  return normalized || null;
}

function canonicalRecord(
  value: CanonicalJsonValue,
  context: string,
): Readonly<Record<string, CanonicalJsonValue>> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new MediaOutputVerificationError(`${context} must be an object`);
  }
  return value;
}

function recordField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): Readonly<Record<string, CanonicalJsonValue>> {
  const value = record[key];
  if (value === undefined) throw new MediaOutputVerificationError(`${context}.${key} is missing`);
  return canonicalRecord(value, `${context}.${key}`);
}

function booleanField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): boolean {
  const value = record[key];
  if (typeof value !== 'boolean') throw new MediaOutputVerificationError(`${context}.${key} must be boolean`);
  return value;
}

function integerField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): number {
  const value = record[key];
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
    throw new MediaOutputVerificationError(`${context}.${key} must be a safe integer`);
  }
  return value;
}

function positiveIntegerField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): number {
  const value = integerField(record, key, context);
  if (value <= 0) throw new MediaOutputVerificationError(`${context}.${key} must be positive`);
  return value;
}

function positiveNumberField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): number {
  const value = record[key];
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) {
    throw new MediaOutputVerificationError(`${context}.${key} must be a positive finite number`);
  }
  return value;
}

function unknownRecord(value: unknown, context: string): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new MediaOutputVerificationError(`${context} must be an object`);
  }
  return value as Record<string, unknown>;
}

function requiredString(value: unknown, context: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new MediaOutputVerificationError(`${context} must be a non-empty string`);
  }
  return value.trim().toLowerCase();
}

function optionalString(value: unknown): string | null {
  if (value === undefined || value === null || value === 'N/A' || value === 'unknown') return null;
  if (typeof value !== 'string') throw new MediaOutputVerificationError('FFprobe optional text field must be a string');
  const normalized = value.trim().toLowerCase();
  return normalized && normalized !== 'n/a' && normalized !== 'unknown' ? normalized : null;
}

function optionalPositiveInteger(value: unknown, context: string): number | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) {
    throw new MediaOutputVerificationError(`${context} must be a positive safe integer`);
  }
  return value;
}

function optionalPositiveIntegerString(value: unknown, context: string): number | null {
  if (value === undefined || value === null || value === 'N/A') return null;
  if (typeof value !== 'string' || !/^\d+$/.test(value)) {
    throw new MediaOutputVerificationError(`${context} must be an integer string`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new MediaOutputVerificationError(`${context} must be a positive safe integer`);
  }
  return parsed;
}

function optionalSecondsAsMilliseconds(value: unknown, context: string): number | null {
  if (value === undefined || value === null || value === 'N/A') return null;
  if (typeof value !== 'string') throw new MediaOutputVerificationError(`${context} must be a decimal string`);
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds < 0) {
    throw new MediaOutputVerificationError(`${context} must be a non-negative finite duration`);
  }
  return Math.round(seconds * 1000);
}

function optionalRational(value: unknown, context: string): number | null {
  if (value === undefined || value === null || value === 'N/A' || value === '0/0') return null;
  if (typeof value !== 'string') throw new MediaOutputVerificationError(`${context} must be a rational string`);
  const match = /^(-?\d+)\/(-?\d+)$/.exec(value.trim());
  if (match === null) throw new MediaOutputVerificationError(`${context} must be a rational string`);
  const numerator = Number(match[1]);
  const denominator = Number(match[2]);
  if (!Number.isSafeInteger(numerator) || !Number.isSafeInteger(denominator) || denominator === 0) {
    throw new MediaOutputVerificationError(`${context} is not a safe rational`);
  }
  const result = numerator / denominator;
  return Number.isFinite(result) && result > 0 ? result : null;
}

function requireEqual(actual: string | null, expected: string, field: string): void {
  if (actual !== expected) {
    throw new MediaOutputVerificationError(`${field} must be ${expected}, got ${String(actual)}`);
  }
}

function requiredText(value: string, name: string): string {
  const normalized = value.trim();
  if (!normalized || normalized.includes('\u0000')) throw new TypeError(`${name} must be non-empty`);
  return normalized;
}

function boundedPositiveInteger(value: number, name: string, maximum: number): number {
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new TypeError(`${name} must be a positive safe integer <= ${maximum}`);
  }
  return value;
}
