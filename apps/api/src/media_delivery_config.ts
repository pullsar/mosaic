import {
  loadMediaStorageConfig,
  positiveIntegerEnv,
  requiredAbsoluteEnv,
} from './media_storage_config.js';

export interface DisabledMediaDeliveryStorageConfig {
  storageMode: 'disabled';
}

export interface LocalMediaDeliveryStorageConfig {
  storageMode: 'local';
  objectRoot: string;
}

export interface S3MediaDeliveryStorageConfig {
  storageMode: 's3';
  storageTimeoutMs: number;
  s3Endpoint: string;
  s3Bucket: string;
  s3Region: string;
  s3AccessKeyId: string;
  s3SecretAccessKey: string;
  s3SessionToken?: string;
}

export type MediaDeliveryStorageConfig =
  | DisabledMediaDeliveryStorageConfig
  | LocalMediaDeliveryStorageConfig
  | S3MediaDeliveryStorageConfig;

const DEFAULT_DELIVERY_STORAGE_TIMEOUT_MS = 60_000;
const MAX_DELIVERY_STORAGE_TIMEOUT_MS = 5 * 60 * 1000;

export function loadMediaDeliveryStorageConfig(
  env: NodeJS.ProcessEnv = process.env,
): MediaDeliveryStorageConfig {
  const storageMode = deliveryStorageMode(env.MEDIA_DELIVERY_STORAGE_MODE);
  if (storageMode === 'disabled') return Object.freeze({storageMode});
  if (storageMode === 'local') {
    return Object.freeze({
      storageMode,
      objectRoot: requiredAbsoluteEnv(env, 'MEDIA_DELIVERY_OBJECT_ROOT'),
    });
  }

  const storageTimeoutMs = positiveIntegerEnv(
    env,
    'MEDIA_DELIVERY_STORAGE_TIMEOUT_MS',
    DEFAULT_DELIVERY_STORAGE_TIMEOUT_MS,
    MAX_DELIVERY_STORAGE_TIMEOUT_MS,
  );
  const shared = loadMediaStorageConfig({
    ...env,
    MEDIA_WORKER_STORAGE_MODE: 's3',
    MEDIA_WORKER_STORAGE_TIMEOUT_MS: String(storageTimeoutMs),
  });
  if (shared.storageMode !== 's3') {
    throw new Error('S3 media delivery configuration resolved to a non-S3 mode');
  }
  return Object.freeze({
    storageMode,
    storageTimeoutMs,
    s3Endpoint: shared.s3Endpoint,
    s3Bucket: shared.s3Bucket,
    s3Region: shared.s3Region,
    s3AccessKeyId: shared.s3AccessKeyId,
    s3SecretAccessKey: shared.s3SecretAccessKey,
    ...(shared.s3SessionToken === undefined
      ? {}
      : {s3SessionToken: shared.s3SessionToken}),
  });
}

function deliveryStorageMode(
  value: string | undefined,
): 'disabled' | 'local' | 's3' {
  const normalized = value?.trim().toLowerCase();
  if (normalized === undefined || normalized === '' || normalized === 'disabled') {
    return 'disabled';
  }
  if (normalized === 'local' || normalized === 's3') return normalized;
  throw new Error('MEDIA_DELIVERY_STORAGE_MODE must be disabled, local or s3');
}
