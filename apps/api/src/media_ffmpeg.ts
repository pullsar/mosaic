import {isAbsolute} from 'node:path';
import {
  normalizeMediaDerivativePlan,
  type CanonicalJsonValue,
  type MediaDerivativePlan,
} from './media.js';

export const FFMPEG_VIDEO_PROCESSOR = 'ffmpeg-video-normalize-v1';
export const FFMPEG_POSTER_PROCESSOR = 'ffmpeg-poster-v1';
export const FFMPEG_AUDIO_PROCESSOR = 'ffmpeg-audio-normalize-v1';

const SUPPORTED_PROCESSORS = new Set([
  FFMPEG_VIDEO_PROCESSOR,
  FFMPEG_POSTER_PROCESSOR,
  FFMPEG_AUDIO_PROCESSOR,
]);

export interface FfmpegInvocationPaths {
  inputPath: string;
  outputPath: string;
}

export interface FfmpegExpectedOutput {
  mimeType: string;
  container?: string;
  videoCodec?: string;
  videoProfile?: string;
  audioCodec?: string;
  colorSpace?: string;
  dynamicRange?: 'sdr' | 'hdr';
}

export interface FfmpegInvocation {
  executable: string;
  args: readonly string[];
  expectedOutput: Readonly<FfmpegExpectedOutput>;
}

export interface FfmpegCompilerOptions {
  executable?: string;
}

export class MediaPlanCompileError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'MediaPlanCompileError';
  }
}

export class UnsupportedMediaProcessorError extends MediaPlanCompileError {
  constructor(processor: string) {
    super(`Unsupported media processor for FFmpeg worker: ${processor}`);
    this.name = 'UnsupportedMediaProcessorError';
  }
}

export function supportsFfmpegPlan(plan: MediaDerivativePlan): boolean {
  return SUPPORTED_PROCESSORS.has(plan.processor);
}

export function compileFfmpegInvocation(
  plan: MediaDerivativePlan,
  paths: FfmpegInvocationPaths,
  options: FfmpegCompilerOptions = {},
): FfmpegInvocation {
  const normalized = normalizeMediaDerivativePlan(plan);
  const inputPath = absoluteMediaPath(paths.inputPath, 'inputPath');
  const outputPath = absoluteMediaPath(paths.outputPath, 'outputPath');
  if (inputPath === outputPath) {
    throw new MediaPlanCompileError('FFmpeg inputPath and outputPath must be different');
  }
  const executable = executableName(options.executable ?? 'ffmpeg');

  if (!SUPPORTED_PROCESSORS.has(normalized.processor)) {
    throw new UnsupportedMediaProcessorError(normalized.processor);
  }

  const compiled = switchProcessor(normalized, inputPath, outputPath);
  return Object.freeze({
    executable,
    args: Object.freeze(compiled.args),
    expectedOutput: Object.freeze(compiled.expectedOutput),
  });
}

function switchProcessor(
  plan: MediaDerivativePlan,
  inputPath: string,
  outputPath: string,
): {args: string[]; expectedOutput: FfmpegExpectedOutput} {
  switch (plan.processor) {
    case FFMPEG_VIDEO_PROCESSOR:
      return compilePlayback(plan, inputPath, outputPath);
    case FFMPEG_POSTER_PROCESSOR:
      return compilePoster(plan, inputPath, outputPath);
    case FFMPEG_AUDIO_PROCESSOR:
      return compileAudio(plan, inputPath, outputPath);
    default:
      throw new UnsupportedMediaProcessorError(plan.processor);
  }
}

function compilePlayback(
  plan: MediaDerivativePlan,
  inputPath: string,
  outputPath: string,
): {args: string[]; expectedOutput: FfmpegExpectedOutput} {
  requirePurpose(plan, 'playback');
  const parameters = recordValue(plan.parameters, 'playback parameters');
  exactKeys(parameters, ['source', 'output'], 'playback parameters');
  const source = recordField(parameters, 'source', 'playback parameters');
  const output = recordField(parameters, 'output', 'playback parameters');

  exactKeys(
    source,
    [
      'width',
      'height',
      'durationMs',
      'videoCodec',
      'videoProfile',
      'dynamicRange',
      'colorPrimaries',
      'colorTransfer',
      'colorMatrix',
      'colorRange',
      'variableFrameRate',
      'nominalFrameRate',
      'rotationDegrees',
      'hasAudio',
      'audioCodec',
      'audioSampleRateHz',
      'audioChannels',
    ],
    'playback source',
  );
  exactKeys(
    output,
    [
      'container',
      'videoCodec',
      'videoProfile',
      'pixelFormat',
      'dynamicRange',
      'colorPrimaries',
      'colorTransfer',
      'colorMatrix',
      'colorRange',
      'frameRateMode',
      'maxFps',
      'maxLongEdge',
      'maxShortEdge',
      'evenDimensions',
      'orientation',
      'fastStart',
      'audio',
    ],
    'playback output',
  );

  const width = positiveIntegerField(source, 'width', 'playback source');
  const height = positiveIntegerField(source, 'height', 'playback source');
  positiveIntegerField(source, 'durationMs', 'playback source');
  stringField(source, 'videoCodec', 'playback source');
  optionalStringField(source, 'videoProfile', 'playback source');
  const dynamicRange = enumStringField(source, 'dynamicRange', ['sdr', 'hdr'], 'playback source');
  const color = sourceColor(source, dynamicRange, 'playback source');
  booleanField(source, 'variableFrameRate', 'playback source');
  const nominalFrameRate = optionalPositiveNumberField(source, 'nominalFrameRate', 'playback source');
  const rotationDegrees = rotationField(source, 'rotationDegrees', 'playback source');
  const hasAudio = booleanField(source, 'hasAudio', 'playback source');

  if (hasAudio) {
    stringField(source, 'audioCodec', 'playback source');
    positiveIntegerField(source, 'audioSampleRateHz', 'playback source');
    positiveIntegerField(source, 'audioChannels', 'playback source');
  } else if (
    source.audioCodec !== undefined ||
    source.audioSampleRateHz !== undefined ||
    source.audioChannels !== undefined
  ) {
    throw new MediaPlanCompileError('Silent playback source cannot contain audio fields');
  }

  expectString(output, 'container', 'mp4', 'playback output');
  expectString(output, 'videoCodec', 'h264', 'playback output');
  expectString(output, 'videoProfile', 'main', 'playback output');
  expectString(output, 'pixelFormat', 'yuv420p', 'playback output');
  expectString(output, 'dynamicRange', 'sdr', 'playback output');
  expectString(output, 'colorPrimaries', 'bt709', 'playback output');
  expectString(output, 'colorTransfer', 'bt709', 'playback output');
  expectString(output, 'colorMatrix', 'bt709', 'playback output');
  expectString(output, 'colorRange', 'limited', 'playback output');
  expectString(output, 'frameRateMode', 'cfr', 'playback output');
  const maxFps = positiveNumberField(output, 'maxFps', 'playback output');
  const maxLongEdge = positiveIntegerField(output, 'maxLongEdge', 'playback output');
  const maxShortEdge = positiveIntegerField(output, 'maxShortEdge', 'playback output');
  expectBoolean(output, 'evenDimensions', true, 'playback output');
  expectString(output, 'orientation', 'pixels-normalized', 'playback output');
  expectBoolean(output, 'fastStart', true, 'playback output');

  const outputAudio = output.audio;
  if (hasAudio) {
    const audio = recordValue(outputAudio, 'playback output audio');
    exactKeys(audio, ['codec', 'profile', 'sampleRateHz', 'maxChannels'], 'playback output audio');
    expectString(audio, 'codec', 'aac', 'playback output audio');
    expectString(audio, 'profile', 'lc', 'playback output audio');
    expectNumber(audio, 'sampleRateHz', 48_000, 'playback output audio');
    expectNumber(audio, 'maxChannels', 2, 'playback output audio');
  } else if (outputAudio !== null) {
    throw new MediaPlanCompileError('Silent playback output audio must be null');
  }

  const rotated = rotationDegrees === 90 || rotationDegrees === 270;
  const displayWidth = rotated ? height : width;
  const displayHeight = rotated ? width : height;
  const landscape = displayWidth >= displayHeight;
  const maxWidth = landscape ? maxLongEdge : maxShortEdge;
  const maxHeight = landscape ? maxShortEdge : maxLongEdge;
  const targetFps = Math.min(nominalFrameRate ?? maxFps, maxFps);

  const filters = [
    ...colorFilters(color),
    boundedScaleFilter(maxWidth, maxHeight),
    'setsar=1',
    `fps=fps=${decimal(targetFps)}:round=near`,
    'format=yuv420p',
  ];

  const args = [
    ...baseInputArgs(inputPath),
    '-map',
    '0:v:0',
    ...(hasAudio ? ['-map', '0:a:0?'] : ['-an']),
    '-sn',
    '-dn',
    '-vf',
    filters.join(','),
    '-c:v',
    'libx264',
    '-preset',
    'medium',
    '-crf',
    '21',
    '-profile:v',
    'main',
    '-pix_fmt',
    'yuv420p',
    '-fps_mode:v',
    'cfr',
    '-color_primaries',
    'bt709',
    '-color_trc',
    'bt709',
    '-colorspace',
    'bt709',
    '-color_range',
    'tv',
    ...(hasAudio
      ? [
          '-c:a',
          'aac',
          '-profile:a',
          'aac_low',
          '-ar',
          '48000',
          '-ac',
          '2',
          '-b:a',
          '128k',
        ]
      : []),
    '-movflags',
    '+faststart',
    '-map_metadata',
    '-1',
    '-map_chapters',
    '-1',
    '-f',
    'mp4',
    outputPath,
  ];

  return {
    args,
    expectedOutput: {
      mimeType: 'video/mp4',
      container: 'mp4',
      videoCodec: 'h264',
      videoProfile: 'main',
      ...(hasAudio ? {audioCodec: 'aac'} : {}),
      colorSpace: 'bt709',
      dynamicRange: 'sdr',
    },
  };
}

function compilePoster(
  plan: MediaDerivativePlan,
  inputPath: string,
  outputPath: string,
): {args: string[]; expectedOutput: FfmpegExpectedOutput} {
  requirePurpose(plan, 'poster');
  const parameters = recordValue(plan.parameters, 'poster parameters');
  exactKeys(parameters, ['source', 'output', 'timestampMs'], 'poster parameters');
  const source = recordField(parameters, 'source', 'poster parameters');
  const output = recordField(parameters, 'output', 'poster parameters');
  exactKeys(
    source,
    [
      'durationMs',
      'rotationDegrees',
      'dynamicRange',
      'colorPrimaries',
      'colorTransfer',
      'colorMatrix',
      'colorRange',
    ],
    'poster source',
  );
  exactKeys(
    output,
    ['format', 'quality', 'dynamicRange', 'colorSpace', 'maxLongEdge', 'evenDimensions', 'orientation'],
    'poster output',
  );

  positiveIntegerField(source, 'durationMs', 'poster source');
  rotationField(source, 'rotationDegrees', 'poster source');
  const dynamicRange = enumStringField(source, 'dynamicRange', ['sdr', 'hdr'], 'poster source');
  const color = sourceColor(source, dynamicRange, 'poster source');
  const timestampMs = nonNegativeIntegerField(parameters, 'timestampMs', 'poster parameters');

  expectString(output, 'format', 'jpeg', 'poster output');
  expectNumber(output, 'quality', 82, 'poster output');
  expectString(output, 'dynamicRange', 'sdr', 'poster output');
  expectString(output, 'colorSpace', 'srgb', 'poster output');
  const maxLongEdge = positiveIntegerField(output, 'maxLongEdge', 'poster output');
  expectBoolean(output, 'evenDimensions', true, 'poster output');
  expectString(output, 'orientation', 'pixels-normalized', 'poster output');

  const filters = [
    ...colorFilters(color),
    boundedScaleFilter(maxLongEdge, maxLongEdge),
    'setsar=1',
    'format=yuvj420p',
  ];
  const args = [
    ...baseInputArgs(inputPath),
    '-ss',
    millisecondsAsSeconds(timestampMs),
    '-map',
    '0:v:0',
    '-an',
    '-sn',
    '-dn',
    '-vf',
    filters.join(','),
    '-frames:v',
    '1',
    '-c:v',
    'mjpeg',
    '-q:v',
    '3',
    '-map_metadata',
    '-1',
    '-map_chapters',
    '-1',
    '-f',
    'image2',
    outputPath,
  ];
  return {
    args,
    expectedOutput: {
      mimeType: 'image/jpeg',
      dynamicRange: 'sdr',
    },
  };
}

function compileAudio(
  plan: MediaDerivativePlan,
  inputPath: string,
  outputPath: string,
): {args: string[]; expectedOutput: FfmpegExpectedOutput} {
  requirePurpose(plan, 'audio');
  const parameters = recordValue(plan.parameters, 'audio parameters');
  exactKeys(parameters, ['source', 'output'], 'audio parameters');
  const source = recordField(parameters, 'source', 'audio parameters');
  const output = recordField(parameters, 'output', 'audio parameters');
  exactKeys(source, ['durationMs', 'audioCodec', 'sampleRateHz', 'channels'], 'audio source');
  exactKeys(output, ['container', 'codec', 'profile', 'sampleRateHz', 'maxChannels', 'fastStart'], 'audio output');

  positiveIntegerField(source, 'durationMs', 'audio source');
  stringField(source, 'audioCodec', 'audio source');
  positiveIntegerField(source, 'sampleRateHz', 'audio source');
  positiveIntegerField(source, 'channels', 'audio source');
  expectString(output, 'container', 'mp4', 'audio output');
  expectString(output, 'codec', 'aac', 'audio output');
  expectString(output, 'profile', 'lc', 'audio output');
  expectNumber(output, 'sampleRateHz', 48_000, 'audio output');
  expectNumber(output, 'maxChannels', 2, 'audio output');
  expectBoolean(output, 'fastStart', true, 'audio output');

  const args = [
    ...baseInputArgs(inputPath),
    '-map',
    '0:a:0',
    '-vn',
    '-sn',
    '-dn',
    '-c:a',
    'aac',
    '-profile:a',
    'aac_low',
    '-ar',
    '48000',
    '-ac',
    '2',
    '-b:a',
    '128k',
    '-movflags',
    '+faststart',
    '-map_metadata',
    '-1',
    '-map_chapters',
    '-1',
    '-f',
    'mp4',
    outputPath,
  ];
  return {
    args,
    expectedOutput: {
      mimeType: 'audio/mp4',
      container: 'mp4',
      audioCodec: 'aac',
    },
  };
}

interface SourceColor {
  dynamicRange: 'sdr' | 'hdr';
  primaries: string | null;
  transfer: string | null;
  matrix: string | null;
  range: 'limited' | 'full' | null;
}

function sourceColor(
  source: Readonly<Record<string, CanonicalJsonValue>>,
  dynamicRange: 'sdr' | 'hdr',
  context: string,
): SourceColor {
  const primaries = optionalStringField(source, 'colorPrimaries', context);
  const transfer = optionalStringField(source, 'colorTransfer', context);
  const matrix = optionalStringField(source, 'colorMatrix', context);
  const rangeRaw = optionalStringField(source, 'colorRange', context);
  const range = rangeRaw === null
    ? null
    : rangeRaw === 'limited' || rangeRaw === 'full'
      ? rangeRaw
      : (() => {
          throw new MediaPlanCompileError(`${context}.colorRange must be limited or full`);
        })();

  const supplied = [primaries, transfer, matrix].filter((value) => value !== null).length;
  if (supplied !== 0 && supplied !== 3) {
    throw new MediaPlanCompileError(`${context} color primaries/transfer/matrix must be all present or all absent`);
  }
  if (dynamicRange === 'hdr' && supplied !== 3) {
    throw new MediaPlanCompileError(`${context} HDR source requires explicit primaries, transfer and matrix`);
  }
  for (const value of [primaries, transfer, matrix]) {
    if (value !== null) safeFilterToken(value, context);
  }
  return {dynamicRange, primaries, transfer, matrix, range};
}

function colorFilters(color: SourceColor): string[] {
  const inputParts: string[] = [];
  if (color.primaries !== null) inputParts.push(`pin=${color.primaries}`);
  if (color.transfer !== null) inputParts.push(`tin=${color.transfer}`);
  if (color.matrix !== null) inputParts.push(`min=${color.matrix}`);
  if (color.range !== null) inputParts.push(`rin=${color.range}`);

  if (color.dynamicRange === 'hdr') {
    return [
      `zscale=${[...inputParts, 't=linear', 'npl=100'].join(':')}`,
      'format=gbrpf32le',
      'tonemap=tonemap=hable:desat=0',
      'zscale=p=bt709:t=bt709:m=bt709:r=limited',
    ];
  }

  return [
    `zscale=${[...inputParts, 'p=bt709', 't=bt709', 'm=bt709', 'r=limited'].join(':')}`,
  ];
}

function boundedScaleFilter(maxWidth: number, maxHeight: number): string {
  return `scale=w='min(iw,${maxWidth})':h='min(ih,${maxHeight})':force_original_aspect_ratio=decrease:force_divisible_by=2`;
}

function baseInputArgs(inputPath: string): string[] {
  return ['-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-i', inputPath];
}

function requirePurpose(plan: MediaDerivativePlan, purpose: MediaDerivativePlan['purpose']): void {
  if (plan.purpose !== purpose) {
    throw new MediaPlanCompileError(`Processor ${plan.processor} cannot compile purpose ${plan.purpose}`);
  }
}

function absoluteMediaPath(value: string, name: string): string {
  if (!value || value.includes('\u0000') || !isAbsolute(value)) {
    throw new MediaPlanCompileError(`${name} must be a non-empty absolute filesystem path`);
  }
  return value;
}

function executableName(value: string): string {
  const normalized = value.trim();
  if (!normalized || normalized.includes('\u0000')) {
    throw new MediaPlanCompileError('FFmpeg executable must not be empty');
  }
  return normalized;
}

function isCanonicalRecord(value: unknown): value is Readonly<Record<string, CanonicalJsonValue>> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function recordValue(value: unknown, context: string): Readonly<Record<string, CanonicalJsonValue>> {
  if (!isCanonicalRecord(value)) {
    throw new MediaPlanCompileError(`${context} must be an object`);
  }
  return value;
}

function recordField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): Readonly<Record<string, CanonicalJsonValue>> {
  return recordValue(record[key], `${context}.${key}`);
}

function exactKeys(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  allowed: readonly string[],
  context: string,
): void {
  const known = new Set(allowed);
  for (const key of Object.keys(record)) {
    if (!known.has(key)) {
      throw new MediaPlanCompileError(`${context} contains unsupported field ${key}`);
    }
  }
}

function stringField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): string {
  const value = record[key];
  if (typeof value !== 'string' || !value) {
    throw new MediaPlanCompileError(`${context}.${key} must be a non-empty string`);
  }
  return value;
}

function optionalStringField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): string | null {
  const value = record[key];
  if (value === undefined) return null;
  if (typeof value !== 'string' || !value) {
    throw new MediaPlanCompileError(`${context}.${key} must be a non-empty string when present`);
  }
  return value;
}

function booleanField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): boolean {
  const value = record[key];
  if (typeof value !== 'boolean') {
    throw new MediaPlanCompileError(`${context}.${key} must be boolean`);
  }
  return value;
}

function numberField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): number {
  const value = record[key];
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new MediaPlanCompileError(`${context}.${key} must be a finite number`);
  }
  return value;
}

function positiveNumberField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): number {
  const value = numberField(record, key, context);
  if (value <= 0) throw new MediaPlanCompileError(`${context}.${key} must be positive`);
  return value;
}

function optionalPositiveNumberField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): number | null {
  if (record[key] === undefined) return null;
  return positiveNumberField(record, key, context);
}

function positiveIntegerField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): number {
  const value = numberField(record, key, context);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new MediaPlanCompileError(`${context}.${key} must be a positive safe integer`);
  }
  return value;
}

function nonNegativeIntegerField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): number {
  const value = numberField(record, key, context);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new MediaPlanCompileError(`${context}.${key} must be a non-negative safe integer`);
  }
  return value;
}

function rotationField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): 0 | 90 | 180 | 270 {
  const value = numberField(record, key, context);
  if (value !== 0 && value !== 90 && value !== 180 && value !== 270) {
    throw new MediaPlanCompileError(`${context}.${key} must be 0, 90, 180 or 270`);
  }
  return value;
}

function enumStringField<const T extends string>(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  allowed: readonly T[],
  context: string,
): T {
  const value = stringField(record, key, context);
  if (!(allowed as readonly string[]).includes(value)) {
    throw new MediaPlanCompileError(`${context}.${key} has unsupported value ${value}`);
  }
  return value as T;
}

function expectString(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  expected: string,
  context: string,
): void {
  const value = stringField(record, key, context);
  if (value !== expected) {
    throw new MediaPlanCompileError(`${context}.${key} must be ${expected}`);
  }
}

function expectNumber(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  expected: number,
  context: string,
): void {
  const value = numberField(record, key, context);
  if (value !== expected) {
    throw new MediaPlanCompileError(`${context}.${key} must be ${expected}`);
  }
}

function expectBoolean(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  expected: boolean,
  context: string,
): void {
  const value = booleanField(record, key, context);
  if (value !== expected) {
    throw new MediaPlanCompileError(`${context}.${key} must be ${String(expected)}`);
  }
}

function safeFilterToken(value: string, context: string): void {
  if (!/^[a-z0-9][a-z0-9._+-]{0,63}$/.test(value)) {
    throw new MediaPlanCompileError(`${context} contains an unsafe FFmpeg color token`);
  }
}

function decimal(value: number): string {
  const rounded = Math.round(value * 1000) / 1000;
  if (Number.isInteger(rounded)) return String(rounded);
  return rounded.toFixed(3).replace(/0+$/, '').replace(/\.$/, '');
}

function millisecondsAsSeconds(value: number): string {
  return (value / 1000).toFixed(3);
}
