import {isAbsolute, resolve} from 'node:path';

export interface LocalMediaStorageConfig {
  storageMode: 'local';
  sourceRoot: string;
  objectRoot: string;
}

export interface S3MediaStorageConfig {
  storageMode: 's3';
  storageTimeoutMs: number;
  s3Endpoint: string;
  s3Bucket: string;
  s3Region: string;
  s3AccessKeyId: string;
  s3SecretAccessKey: string;
  s3SessionToken?: string;
}

export type MediaStorageConfig = LocalMediaStorageConfig | S3MediaStorageConfig;

const DEFAULT_STORAGE_TIMEOUT_MS = 60_000;
const MAX_STORAGE_TIMEOUT_MS = 5 * 60 * 1000;

export function loadMediaStorageConfig(
  env: NodeJS.ProcessEnv = process.env,
): MediaStorageConfig {
  const storageMode = storageModeEnv(env.MEDIA_WORKER_STORAGE_MODE);
  if (storageMode === 'local') {
    return Object.freeze({
      storageMode,
      sourceRoot: requiredAbsoluteEnv(env, 'MEDIA_WORKER_SOURCE_ROOT'),
      objectRoot: requiredAbsoluteEnv(env, 'MEDIA_WORKER_OBJECT_ROOT'),
    });
  }

  const sessionToken = optionalSecretEnv(env.MEDIA_S3_SESSION_TOKEN);
  return Object.freeze({
    storageMode,
    storageTimeoutMs: positiveIntegerEnv(
      env,
      'MEDIA_WORKER_STORAGE_TIMEOUT_MS',
      DEFAULT_STORAGE_TIMEOUT_MS,
      MAX_STORAGE_TIMEOUT_MS,
    ),
    s3Endpoint: requiredHttpsOriginEnv(env, 'MEDIA_S3_ENDPOINT'),
    s3Bucket: requiredEnvText(env, 'MEDIA_S3_BUCKET'),
    s3Region: requiredEnvText(env, 'MEDIA_S3_REGION'),
    s3AccessKeyId: requiredEnvText(env, 'MEDIA_S3_ACCESS_KEY_ID'),
    s3SecretAccessKey: requiredSecretEnv(env, 'MEDIA_S3_SECRET_ACCESS_KEY'),
    ...(sessionToken === undefined ? {} : {s3SessionToken: sessionToken}),
  });
}

export function requiredEnvText(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name]?.trim();
  if (!value || value.includes('\u0000')) {
    throw new Error(`${name} is required and must contain no NUL bytes`);
  }
  return value;
}

export function requiredAbsoluteEnv(env: NodeJS.ProcessEnv, name: string): string {
  const value = requiredEnvText(env, name);
  if (!isAbsolute(value)) throw new Error(`${name} must be an absolute path`);
  return resolve(value);
}

export function positiveIntegerEnv(
  env: NodeJS.ProcessEnv,
  name: string,
  defaultValue: number,
  maximum: number,
): number {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return defaultValue;
  if (!/^\d+$/.test(raw.trim())) {
    throw new Error(`${name} must be a positive integer`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new Error(`${name} must be a positive safe integer <= ${maximum}`);
  }
  return value;
}

export function optionalExecutableEnv(
  value: string | undefined,
  fallback: string,
  name: string,
): string {
  if (value === undefined || value.trim() === '') return fallback;
  const normalized = value.trim();
  if (normalized.includes('\u0000')) {
    throw new Error(`${name} contains a NUL byte`);
  }
  return normalized;
}

function storageModeEnv(value: string | undefined): 'local' | 's3' {
  const normalized = value?.trim().toLowerCase();
  if (normalized === undefined || normalized === '') return 'local';
  if (normalized === 'local' || normalized === 's3') return normalized;
  throw new Error('MEDIA_WORKER_STORAGE_MODE must be local or s3');
}

function requiredSecretEnv(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (!value || /[\r\n\u0000]/.test(value)) {
    throw new Error(`${name} is required and must be a single-line value`);
  }
  return value;
}

function optionalSecretEnv(value: string | undefined): string | undefined {
  if (value === undefined || value === '') return undefined;
  if (/[\r\n\u0000]/.test(value)) {
    throw new Error('MEDIA_S3_SESSION_TOKEN must be a single-line value');
  }
  return value;
}

function requiredHttpsOriginEnv(env: NodeJS.ProcessEnv, name: string): string {
  const raw = requiredEnvText(env, name);
  let url: URL;
  try {
    url = new URL(raw);
  } catch (error) {
    throw new Error(`${name} must be an absolute HTTPS origin`, {cause: error});
  }
  if (
    url.protocol !== 'https:' ||
    url.username ||
    url.password ||
    url.pathname !== '/' ||
    url.search ||
    url.hash
  ) {
    throw new Error(
      `${name} must be an HTTPS origin with no path, credentials, query or fragment`,
    );
  }
  return url.origin;
}
