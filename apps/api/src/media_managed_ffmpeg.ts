import {
  compileFfmpegInvocation as compileBaseFfmpegInvocation,
  MediaPlanCompileError,
  supportsFfmpegPlan as supportsBaseFfmpegPlan,
  type FfmpegCompilerOptions,
  type FfmpegExpectedOutput,
  type FfmpegInvocation,
  type FfmpegInvocationPaths,
} from './media_ffmpeg.js';
import {
  normalizeMediaDerivativePlan,
  type CanonicalJsonValue,
  type MediaDerivativePlan,
} from './media.js';
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
  if (plan.processor !== FFMPEG_IMAGE_PROCESSOR) {
    return compileBaseFfmpegInvocation(plan, paths, options);
  }
  const normalized = normalizeMediaDerivativePlan(plan);
  return compileBaseFfmpegInvocation(imageExecutionPlan(normalized), paths, options);
}

/**
 * Managed authored images have their own persisted purpose/processor/identity,
 * but intentionally reuse the already verified single-frame JPEG execution and
 * FFprobe policy. The adapter is ephemeral; no image row is ever persisted as a
 * video poster derivative. Existing plans pass through by reference.
 */
export function mediaOutputVerificationPlan(
  plan: MediaDerivativePlan,
): MediaDerivativePlan {
  if (plan.processor !== FFMPEG_IMAGE_PROCESSOR) return plan;
  return imageExecutionPlan(normalizeMediaDerivativePlan(plan));
}

function imageExecutionPlan(plan: MediaDerivativePlan): MediaDerivativePlan {
  if (plan.purpose !== 'image') {
    throw new MediaPlanCompileError(
      `Processor ${FFMPEG_IMAGE_PROCESSOR} cannot compile purpose ${plan.purpose}`,
    );
  }
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
  positiveInteger(source.width, 'image source.width');
  positiveInteger(source.height, 'image source.height');
  const rotationDegrees = rotation(source.rotationDegrees, 'image source.rotationDegrees');
  const dynamicRange = enumValue(
    source.dynamicRange,
    ['sdr', 'hdr'] as const,
    'image source.dynamicRange',
  );
  if (source.hasAlpha !== false) {
    throw new MediaPlanCompileError('image source.hasAlpha must be false');
  }
  assertExpectedOutput(output);

  const posterSource: Record<string, CanonicalJsonValue> = {
    durationMs: 1,
    rotationDegrees,
    dynamicRange,
  };
  for (const key of [
    'colorPrimaries',
    'colorTransfer',
    'colorMatrix',
    'colorRange',
  ] as const) {
    const value = source[key];
    if (value !== undefined) posterSource[key] = value;
  }

  return normalizeMediaDerivativePlan({
    version: plan.version,
    purpose: 'poster',
    processor: 'ffmpeg-poster-v1',
    parameters: {
      source: posterSource,
      output: {
        format: 'jpeg',
        quality: 82,
        dynamicRange: 'sdr',
        colorSpace: 'srgb',
        maxLongEdge: 1280,
        evenDimensions: true,
        orientation: 'pixels-normalized',
      },
      timestampMs: 0,
    },
  });
}

function assertExpectedOutput(
  output: Readonly<Record<string, CanonicalJsonValue>>,
): void {
  const expected: Readonly<Record<string, CanonicalJsonValue>> = {
    format: 'jpeg',
    quality: 82,
    dynamicRange: 'sdr',
    colorSpace: 'srgb',
    maxLongEdge: 1280,
    evenDimensions: true,
    orientation: 'pixels-normalized',
  };
  for (const [key, value] of Object.entries(expected)) {
    if (output[key] !== value) {
      throw new MediaPlanCompileError(
        `image output.${key} must be ${String(value)}`,
      );
    }
  }
}

function recordValue(
  value: unknown,
  context: string,
): Readonly<Record<string, CanonicalJsonValue>> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new MediaPlanCompileError(`${context} must be an object`);
  }
  return value as Readonly<Record<string, CanonicalJsonValue>>;
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

function positiveInteger(value: CanonicalJsonValue | undefined, name: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) {
    throw new MediaPlanCompileError(`${name} must be a positive safe integer`);
  }
  return value;
}

function rotation(
  value: CanonicalJsonValue | undefined,
  name: string,
): 0 | 90 | 180 | 270 {
  if (value !== 0 && value !== 90 && value !== 180 && value !== 270) {
    throw new MediaPlanCompileError(`${name} must be 0, 90, 180 or 270`);
  }
  return value;
}

function enumValue<T extends string>(
  value: CanonicalJsonValue | undefined,
  allowed: readonly T[],
  name: string,
): T {
  if (typeof value !== 'string' || !allowed.includes(value as T)) {
    throw new MediaPlanCompileError(
      `${name} must be one of ${allowed.join(', ')}`,
    );
  }
  return value as T;
}
