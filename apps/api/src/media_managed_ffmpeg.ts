import {isAbsolute} from 'node:path';
import {
  compileFfmpegInvocation as compileBaseFfmpegInvocation,
  MediaPlanCompileError,
  supportsFfmpegPlan as supportsBaseFfmpegPlan,
  type FfmpegCompilerOptions,
  type FfmpegExpectedOutput,
  type FfmpegInvocation,
  type FfmpegInvocationPaths,
} from './media_ffmpeg.js';
import {normalizeMediaDerivativePlan, type CanonicalJsonValue, type MediaDerivativePlan} from './media.js';
import {FFMPEG_IMAGE_PROCESSOR} from './media_image_normalization.js';

export {MediaPlanCompileError};
export type {FfmpegExpectedOutput};

export function supportsFfmpegPlan(plan: MediaDerivativePlan): boolean {
  return plan.processor === FFMPEG_IMAGE_PROCESSOR || supportsBaseFfmpegPlan(plan);
}

export function compileFfmpegInvocation(
  plan: MediaDerivativePlan,
  paths: FfmpegInvocationPaths,
  options: FfmpegCompilerOptions = {},
): FfmpegInvocation {
  const normalized = normalizeMediaDerivativePlan(plan);
  if (normalized.processor !== FFMPEG_IMAGE_PROCESSOR) {
    return compileBaseFfmpegInvocation(normalized, paths, options);
  }
  return compileManagedImage(normalized, paths, options);
}

/**
 * The existing FFprobe poster verifier already enforces the exact still-image
 * output topology we need (single MJPEG frame, bounded even dimensions, SDR).
 * Verification dispatch is processor-based, so image plans are presented to
 * that verifier with only the processor identity adapted. The immutable image
 * plan itself is never rewritten or persisted as a poster plan.
 */
export function mediaOutputVerificationPlan(
  plan: MediaDerivativePlan,
): MediaDerivativePlan {
  const normalized = normalizeMediaDerivativePlan(plan);
  if (normalized.processor !== FFMPEG_IMAGE_PROCESSOR) return normalized;
  return Object.freeze({...normalized, processor: 'ffmpeg-poster-v1'});
}

function compileManagedImage(
  plan: MediaDerivativePlan,
  paths: FfmpegInvocationPaths,
  options: FfmpegCompilerOptions,
): FfmpegInvocation {
  if (plan.purpose !== 'image') {
    throw new MediaPlanCompileError(
      `Processor ${FFMPEG_IMAGE_PROCESSOR} cannot compile purpose ${plan.purpose}`,
    );
  }
  const inputPath = absoluteMediaPath(paths.inputPath, 'inputPath');
  const outputPath = absoluteMediaPath(paths.outputPath, 'outputPath');
  if (inputPath === outputPath) {
    throw new MediaPlanCompileError('FFmpeg inputPath and outputPath must be different');
  }
  const executable = executableName(options.executable ?? 'ffmpeg');
  const parameters = recordValue(plan.parameters, 'image parameters');
  exactKeys(parameters, ['source', 'output'], 'image parameters');
  const source = recordField(parameters, 'source', 'image parameters');
  const output = recordField(parameters, 'output', 'image parameters');
  exactKeys(
    source,
    [
      'width',
      'height',
      'rotationDegrees',
      'dynamicRange',
      'colorPrimaries',
      'colorTransfer',
      'colorMatrix',
      'colorRange',
      'hasAlpha',
    ],
    'image source',
  );
  exactKeys(
    output,
    [
      'format',
      'quality',
      'dynamicRange',
      'colorSpace',
      'maxLongEdge',
      'evenDimensions',
      'orientation',
    ],
    'image output',
  );

  positiveIntegerField(source, 'width', 'image source');
  positiveIntegerField(source, 'height', 'image source');
  rotationField(source, 'rotationDegrees', 'image source');
  const dynamicRange = enumStringField(
    source,
    'dynamicRange',
    ['sdr', 'hdr'],
    'image source',
  );
  expectBoolean(source, 'hasAlpha', false, 'image source');
  const color = sourceColor(source, dynamicRange, 'image source');

  expectString(output, 'format', 'jpeg', 'image output');
  expectNumber(output, 'quality', 86, 'image output');
  expectString(output, 'dynamicRange', 'sdr', 'image output');
  expectString(output, 'colorSpace', 'srgb', 'image output');
  const maxLongEdge = positiveIntegerField(output, 'maxLongEdge', 'image output');
  expectBoolean(output, 'evenDimensions', true, 'image output');
  expectString(output, 'orientation', 'pixels-normalized', 'image output');

  const filters = [
    ...colorFilters(color),
    boundedScaleFilter(maxLongEdge, maxLongEdge),
    'setsar=1',
    'format=yuvj420p',
  ];
  const args = [
    '-hide_banner',
    '-loglevel',
    'error',
    '-nostdin',
    '-y',
    '-i',
    inputPath,
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
  return Object.freeze({
    executable,
    args: Object.freeze(args),
    expectedOutput: Object.freeze({
      mimeType: 'image/jpeg',
      dynamicRange: 'sdr' as const,
    }),
  });
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
          throw new MediaPlanCompileError(
            `${context}.colorRange must be limited or full`,
          );
        })();
  const supplied = [primaries, transfer, matrix]
    .filter((value) => value !== null)
    .length;
  if (supplied !== 0 && supplied !== 3) {
    throw new MediaPlanCompileError(
      `${context} color primaries/transfer/matrix must be all present or all absent`,
    );
  }
  if (dynamicRange === 'hdr' && supplied !== 3) {
    throw new MediaPlanCompileError(
      `${context} HDR source requires explicit primaries, transfer and matrix`,
    );
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
    `zscale=${[
      ...inputParts,
      'p=bt709',
      't=bt709',
      'm=bt709',
      'r=limited',
    ].join(':')}`,
  ];
}

function boundedScaleFilter(maxWidth: number, maxHeight: number): string {
  return `scale=w='min(iw,${maxWidth})':h='min(ih,${maxHeight})':force_original_aspect_ratio=decrease:force_divisible_by=2`;
}

function absoluteMediaPath(value: string, name: string): string {
  if (!value || value.includes('\u0000') || !isAbsolute(value)) {
    throw new MediaPlanCompileError(
      `${name} must be a non-empty absolute filesystem path`,
    );
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

function isCanonicalRecord(
  value: unknown,
): value is Readonly<Record<string, CanonicalJsonValue>> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function recordValue(
  value: unknown,
  context: string,
): Readonly<Record<string, CanonicalJsonValue>> {
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
      throw new MediaPlanCompileError(
        `${context} contains unsupported field ${key}`,
      );
    }
  }
}

function optionalStringField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): string | null {
  const value = record[key];
  if (value === undefined) return null;
  if (typeof value !== 'string' || !value) {
    throw new MediaPlanCompileError(
      `${context}.${key} must be a non-empty string when present`,
    );
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

function positiveIntegerField(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  context: string,
): number {
  const value = numberField(record, key, context);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new MediaPlanCompileError(
      `${context}.${key} must be a positive safe integer`,
    );
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
    throw new MediaPlanCompileError(
      `${context}.${key} must be 0, 90, 180 or 270`,
    );
  }
  return value;
}

function enumStringField<T extends string>(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  allowed: readonly T[],
  context: string,
): T {
  const value = record[key];
  if (typeof value !== 'string' || !allowed.includes(value as T)) {
    throw new MediaPlanCompileError(
      `${context}.${key} must be one of ${allowed.join(', ')}`,
    );
  }
  return value as T;
}

function expectString(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  expected: string,
  context: string,
): void {
  if (record[key] !== expected) {
    throw new MediaPlanCompileError(
      `${context}.${key} must be ${expected}`,
    );
  }
}

function expectNumber(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  expected: number,
  context: string,
): void {
  if (record[key] !== expected) {
    throw new MediaPlanCompileError(
      `${context}.${key} must be ${expected}`,
    );
  }
}

function expectBoolean(
  record: Readonly<Record<string, CanonicalJsonValue>>,
  key: string,
  expected: boolean,
  context: string,
): void {
  if (record[key] !== expected) {
    throw new MediaPlanCompileError(
      `${context}.${key} must be ${String(expected)}`,
    );
  }
}

function safeFilterToken(value: string, context: string): void {
  if (!/^[a-z0-9][a-z0-9._+-]{0,63}$/.test(value)) {
    throw new MediaPlanCompileError(
      `${context} contains unsafe FFmpeg filter metadata`,
    );
  }
}
