import {
  normalizeMediaDerivativePlan,
  type CanonicalJsonValue,
  type MediaDerivativePlan,
} from './media.js';
import type {
  VerifiedColorRange,
  VerifiedDynamicRange,
  VerifiedRotationDegrees,
} from './media_normalization.js';

export const MEDIA_IMAGE_POLICY_VERSION = 1;
export const FFMPEG_IMAGE_PROCESSOR = 'ffmpeg-image-normalize-v1';

export interface VerifiedImageSourceMetadata {
  kind: 'image';
  width: number;
  height: number;
  rotationDegrees: VerifiedRotationDegrees;
  dynamicRange: VerifiedDynamicRange;
  colorPrimaries?: string;
  colorTransfer?: string;
  colorMatrix?: string;
  colorRange?: VerifiedColorRange;
  hasAlpha: boolean;
}

export function planImageNormalization(
  source: VerifiedImageSourceMetadata,
): MediaDerivativePlan {
  if (source.kind !== 'image') {
    throw new TypeError('Managed image planner requires image source metadata');
  }
  positiveInteger(source.width, 'width');
  positiveInteger(source.height, 'height');
  if (![0, 90, 180, 270].includes(source.rotationDegrees)) {
    throw new TypeError(`Unsupported rotationDegrees: ${String(source.rotationDegrees)}`);
  }
  if (source.dynamicRange !== 'sdr' && source.dynamicRange !== 'hdr') {
    throw new TypeError(`Unsupported dynamicRange: ${String(source.dynamicRange)}`);
  }
  if (source.hasAlpha) {
    throw new TypeError(
      'Managed JPEG image profile does not support alpha; preserve the source until an alpha-safe profile is available',
    );
  }

  const colorPrimaries = optionalToken(source.colorPrimaries, 'colorPrimaries');
  const colorTransfer = optionalToken(source.colorTransfer, 'colorTransfer');
  const colorMatrix = optionalToken(source.colorMatrix, 'colorMatrix');
  const colorRange = optionalColorRange(source.colorRange);
  const suppliedColor = [colorPrimaries, colorTransfer, colorMatrix]
    .filter((value) => value !== null)
    .length;
  if (suppliedColor !== 0 && suppliedColor !== 3) {
    throw new TypeError(
      'Verified image color primaries, transfer and matrix must be all present or all absent',
    );
  }
  if (source.dynamicRange === 'hdr' && suppliedColor !== 3) {
    throw new TypeError(
      'Verified HDR image requires color primaries, transfer and matrix metadata',
    );
  }

  const sourceTraits: Record<string, CanonicalJsonValue> = {
    width: source.width,
    height: source.height,
    rotationDegrees: source.rotationDegrees,
    dynamicRange: source.dynamicRange,
    hasAlpha: false,
  };
  if (colorPrimaries !== null) sourceTraits.colorPrimaries = colorPrimaries;
  if (colorTransfer !== null) sourceTraits.colorTransfer = colorTransfer;
  if (colorMatrix !== null) sourceTraits.colorMatrix = colorMatrix;
  if (colorRange !== null) sourceTraits.colorRange = colorRange;

  const plan = normalizeMediaDerivativePlan({
    version: MEDIA_IMAGE_POLICY_VERSION,
    purpose: 'image',
    processor: FFMPEG_IMAGE_PROCESSOR,
    parameters: {
      source: sourceTraits,
      output: {
        format: 'jpeg',
        quality: 82,
        dynamicRange: 'sdr',
        colorSpace: 'srgb',
        maxLongEdge: 1280,
        evenDimensions: true,
        orientation: 'pixels-normalized',
      },
    },
  });
  freezeCanonical(plan.parameters);
  return Object.freeze(plan);
}

function optionalToken(value: string | undefined, name: string): string | null {
  if (value === undefined) return null;
  const normalized = value.trim().toLowerCase();
  if (!normalized || !/^[a-z0-9][a-z0-9._+-]{0,63}$/.test(normalized)) {
    throw new TypeError(`${name} contains unsupported characters`);
  }
  return normalized;
}

function optionalColorRange(
  value: VerifiedColorRange | undefined,
): VerifiedColorRange | null {
  if (value === undefined) return null;
  if (value !== 'limited' && value !== 'full') {
    throw new TypeError(`Unsupported colorRange: ${String(value)}`);
  }
  return value;
}

function positiveInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new TypeError(`${name} must be a positive safe integer`);
  }
}

function freezeCanonical(value: CanonicalJsonValue): void {
  if (Array.isArray(value)) {
    for (const item of value) freezeCanonical(item);
    Object.freeze(value);
    return;
  }
  if (value !== null && typeof value === 'object') {
    for (const item of Object.values(value)) freezeCanonical(item);
    Object.freeze(value);
  }
}
