import {createHash} from 'node:crypto';

export type MediaAssetKind = 'image' | 'video' | 'audio';
export type MediaAssetState = 'registered' | 'uploaded' | 'processing' | 'ready' | 'failed' | 'revoked';
export type MediaDerivativePurpose = 'playback' | 'poster' | 'audio' | 'captions';
export type MediaDerivativeState = 'pending' | 'processing' | 'ready' | 'failed' | 'revoked';

export type CanonicalJsonValue =
  | null
  | boolean
  | number
  | string
  | readonly CanonicalJsonValue[]
  | {readonly [key: string]: CanonicalJsonValue};

export interface MediaDerivativePlan {
  version: number;
  purpose: MediaDerivativePurpose;
  processor: string;
  parameters: {readonly [key: string]: CanonicalJsonValue};
}

const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const DERIVATIVE_KEY_PREFIX = 'mdv1';
const PURPOSES = new Set<MediaDerivativePurpose>(['playback', 'poster', 'audio', 'captions']);

export function normalizeSha256(value: string): string {
  const normalized = value.trim().toLowerCase();
  if (!SHA256_PATTERN.test(normalized)) {
    throw new TypeError('sourceSha256 must be a 64-character hexadecimal SHA-256 digest');
  }
  return normalized;
}

export function normalizeMediaDerivativePlan(plan: MediaDerivativePlan): MediaDerivativePlan {
  if (!Number.isSafeInteger(plan.version) || plan.version <= 0) {
    throw new TypeError('Media derivative plan version must be a positive safe integer');
  }
  if (!PURPOSES.has(plan.purpose)) {
    throw new TypeError(`Unsupported media derivative purpose: ${String(plan.purpose)}`);
  }
  const processor = plan.processor.trim();
  if (!processor) throw new TypeError('Media derivative processor identity must not be empty');
  const parameters = canonicalize(plan.parameters);
  if (!isCanonicalJsonObject(parameters)) {
    throw new TypeError('Media derivative parameters must be a JSON object');
  }
  return {version: plan.version, purpose: plan.purpose, processor, parameters};
}

export function mediaDerivativeKey(sourceSha256: string, plan: MediaDerivativePlan): string {
  const source = normalizeSha256(sourceSha256);
  const normalizedPlan = normalizeMediaDerivativePlan(plan);
  const digest = createHash('sha256')
    .update(`${DERIVATIVE_KEY_PREFIX}\n${source}\n${canonicalJson(normalizedPlan)}`, 'utf8')
    .digest('hex');
  return `${DERIVATIVE_KEY_PREFIX}_${digest}`;
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

function isCanonicalJsonObject(
  value: CanonicalJsonValue,
): value is {readonly [key: string]: CanonicalJsonValue} {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function canonicalize(value: unknown): CanonicalJsonValue {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new TypeError('Canonical JSON does not allow non-finite numbers');
    return Object.is(value, -0) ? 0 : value;
  }
  if (Array.isArray(value)) {
    const normalized: CanonicalJsonValue[] = [];
    for (let index = 0; index < value.length; index += 1) {
      if (!(index in value)) throw new TypeError('Canonical JSON does not allow sparse arrays');
      normalized.push(canonicalize(value[index]));
    }
    return normalized;
  }
  if (typeof value === 'object') {
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      throw new TypeError('Canonical JSON accepts only plain objects');
    }
    const normalized = Object.create(null) as Record<string, CanonicalJsonValue>;
    const keys = Reflect.ownKeys(value);
    if (keys.some((key) => typeof key !== 'string')) {
      throw new TypeError('Canonical JSON accepts only string object keys');
    }
    for (const key of (keys as string[]).sort()) {
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      if (!descriptor?.enumerable || !('value' in descriptor)) {
        throw new TypeError('Canonical JSON accepts only enumerable data properties');
      }
      normalized[key] = canonicalize(descriptor.value);
    }
    return normalized;
  }
  throw new TypeError(`Canonical JSON does not allow ${typeof value}`);
}
