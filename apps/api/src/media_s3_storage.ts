import {createHash} from 'node:crypto';
import {createReadStream} from 'node:fs';
import {open, stat, unlink} from 'node:fs/promises';
import {isAbsolute, join} from 'node:path';
import {Readable} from 'node:stream';
import type {
  MediaObjectPutRequest,
  MediaObjectStore,
  MediaStoredObject,
} from './media_object_store.js';
import type {MediaAssetRecord} from './media_repository.js';
import type {MediaSourceMaterializer} from './media_worker_runtime.js';
import {signS3RequestV4} from './s3_sigv4.js';

export type S3Fetch = (
  input: string | URL | Request,
  init?: RequestInit & {duplex?: 'half'},
) => Promise<Response>;

export interface S3CompatibleMediaStorageOptions {
  endpoint: string | URL;
  bucket: string;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
  requestTimeoutMs?: number;
  fetch?: S3Fetch;
  now?: () => Date;
}

export interface S3VerifiedDownloadRequest {
  storageKey: string;
  destinationPath: string;
  sizeBytes: number;
  sha256: string;
  mimeType?: string;
  signal?: AbortSignal;
}

export class S3MediaStorageError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = 'S3MediaStorageError';
  }
}

const EMPTY_SHA256 =
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const DEFAULT_REQUEST_TIMEOUT_MS = 60_000;
const MAX_REQUEST_TIMEOUT_MS = 5 * 60 * 1000;
const MAX_STORAGE_KEY_BYTES = 1024;
const BUCKET_PATTERN = /^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/;
const MIME_PATTERN = /^[a-z0-9][a-z0-9.+-]*\/[a-z0-9][a-z0-9.+-]*$/;

/**
 * Production S3-compatible storage for both immutable derivative publication
 * and verified source materialization. The endpoint is path-style so the same
 * implementation works with AWS S3 and providers such as Cloudflare R2.
 */
export class S3CompatibleMediaStorage implements MediaObjectStore {
  private readonly endpoint: URL;
  private readonly bucket: string;
  private readonly region: string;
  private readonly accessKeyId: string;
  private readonly secretAccessKey: string;
  private readonly sessionToken: string | undefined;
  private readonly requestTimeoutMs: number;
  private readonly fetcher: S3Fetch;
  private readonly now: () => Date;

  constructor(options: S3CompatibleMediaStorageOptions) {
    this.endpoint = normalizeEndpoint(options.endpoint);
    this.bucket = normalizeBucket(options.bucket);
    this.region = requiredToken(options.region, 'S3 region');
    this.accessKeyId = requiredToken(options.accessKeyId, 'S3 access key ID');
    this.secretAccessKey = requiredSecret(
      options.secretAccessKey,
      'S3 secret access key',
    );
    this.sessionToken = optionalSecret(options.sessionToken, 'S3 session token');
    this.requestTimeoutMs = boundedPositiveInteger(
      options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS,
      'S3 requestTimeoutMs',
      MAX_REQUEST_TIMEOUT_MS,
    );
    this.fetcher = options.fetch ?? globalThis.fetch;
    this.now = options.now ?? (() => new Date());
  }

  async putFileIfAbsent(request: MediaObjectPutRequest): Promise<MediaStoredObject> {
    validateStoredObject(request);
    abortIfRequested(request.signal);
    if (!isAbsolute(request.sourcePath)) {
      throw new TypeError('S3 media sourcePath must be absolute');
    }
    const local = await stat(request.sourcePath);
    if (!local.isFile() || local.size !== request.sizeBytes) {
      throw new S3MediaStorageError(
        `S3 publication source size changed for ${request.storageKey}`,
      );
    }

    const url = this.objectUrl(request.storageKey);
    const signal = this.requestSignal(request.signal);
    const signed = this.sign('PUT', url, request.sha256, {
      'content-length': String(request.sizeBytes),
      'content-type': request.mimeType,
      'if-none-match': '*',
      'x-amz-meta-mosaic-sha256': request.sha256,
    });
    const input = createReadStream(request.sourcePath, {signal});
    let response: Response;
    try {
      response = await this.fetcher(url, {
        method: 'PUT',
        headers: requestHeaders(signed),
        body: Readable.toWeb(input) as ReadableStream<Uint8Array>,
        duplex: 'half',
        signal,
      });
    } finally {
      input.destroy();
    }

    const conditionalConflict = response.status === 409 || response.status === 412;
    if (!response.ok && !conditionalConflict) {
      await discardBody(response);
      throw new S3MediaStorageError(
        `S3 PUT ${request.storageKey} failed with HTTP ${response.status}`,
      );
    }
    await discardBody(response);

    const stored = await this.headObject(request.storageKey, request.signal);
    if (stored === null) {
      throw new S3MediaStorageError(
        conditionalConflict
          ? `S3 immutable object race for ${request.storageKey} did not resolve to an object`
          : `S3 PUT ${request.storageKey} succeeded but HEAD could not resolve it`,
      );
    }
    assertStoredObjectMatches(request, stored);
    return stored;
  }

  async headObject(
    storageKey: string,
    signal?: AbortSignal,
  ): Promise<MediaStoredObject | null> {
    const key = normalizeStorageKey(storageKey);
    abortIfRequested(signal);
    const url = this.objectUrl(key);
    const requestSignal = this.requestSignal(signal);
    const signed = this.sign('HEAD', url, EMPTY_SHA256);
    const response = await this.fetcher(url, {
      method: 'HEAD',
      headers: requestHeaders(signed),
      signal: requestSignal,
    });
    if (response.status === 404) {
      await discardBody(response);
      return null;
    }
    if (!response.ok) {
      await discardBody(response);
      throw new S3MediaStorageError(
        `S3 HEAD ${key} failed with HTTP ${response.status}`,
      );
    }
    await discardBody(response);

    const sizeBytes = requiredContentLength(response.headers, key);
    const mimeType = requiredMimeType(response.headers, key);
    const sha256 = response.headers.get('x-amz-meta-mosaic-sha256');
    if (sha256 === null || !/^[0-9a-f]{64}$/.test(sha256)) {
      throw new S3MediaStorageError(
        `S3 object ${key} lacks valid Mosaic SHA-256 metadata`,
      );
    }
    return Object.freeze({storageKey: key, sizeBytes, sha256, mimeType});
  }

  async downloadVerifiedObject(request: S3VerifiedDownloadRequest): Promise<string> {
    const key = normalizeStorageKey(request.storageKey);
    const expectedSize = positiveSafeInteger(request.sizeBytes, 'S3 expected sizeBytes');
    const expectedSha256 = normalizeSha256(request.sha256);
    const expectedMimeType =
      request.mimeType === undefined ? undefined : normalizeMimeType(request.mimeType);
    if (!isAbsolute(request.destinationPath)) {
      throw new TypeError('S3 media destinationPath must be absolute');
    }
    abortIfRequested(request.signal);

    const url = this.objectUrl(key);
    const signal = this.requestSignal(request.signal);
    const signed = this.sign('GET', url, EMPTY_SHA256);
    const response = await this.fetcher(url, {
      method: 'GET',
      headers: requestHeaders(signed),
      signal,
    });
    if (!response.ok || response.body === null) {
      await discardBody(response);
      throw new S3MediaStorageError(
        `S3 GET ${key} failed with HTTP ${response.status}`,
      );
    }

    const remoteSize = requiredContentLength(response.headers, key);
    if (remoteSize !== expectedSize) {
      await discardBody(response);
      throw new S3MediaStorageError(
        `S3 source size mismatch for ${key}: ${remoteSize} != ${expectedSize}`,
      );
    }
    if (expectedMimeType !== undefined) {
      const remoteMimeType = requiredMimeType(response.headers, key);
      if (remoteMimeType !== expectedMimeType) {
        await discardBody(response);
        throw new S3MediaStorageError(
          `S3 source MIME mismatch for ${key}: ${remoteMimeType} != ${expectedMimeType}`,
        );
      }
    }

    const target = await open(request.destinationPath, 'wx', 0o600);
    const reader = response.body.getReader();
    const hash = createHash('sha256');
    let total = 0;
    let completed = false;
    try {
      while (true) {
        abortIfRequested(signal);
        const {done, value} = await reader.read();
        if (done) break;
        if (value.length === 0) continue;
        total += value.length;
        if (total > expectedSize) {
          throw new S3MediaStorageError(
            `S3 source ${key} exceeded verified size ${expectedSize}`,
          );
        }
        hash.update(value);
        let offset = 0;
        while (offset < value.length) {
          abortIfRequested(signal);
          const {bytesWritten} = await target.write(
            value,
            offset,
            value.length - offset,
            null,
          );
          if (bytesWritten <= 0) {
            throw new S3MediaStorageError(
              `S3 source write made no progress for ${key}`,
            );
          }
          offset += bytesWritten;
        }
      }
      if (total !== expectedSize) {
        throw new S3MediaStorageError(
          `S3 source size mismatch for ${key}: ${total} != ${expectedSize}`,
        );
      }
      const actualSha256 = hash.digest('hex');
      if (actualSha256 !== expectedSha256) {
        throw new S3MediaStorageError(
          `S3 source digest mismatch for ${key}`,
        );
      }
      await target.sync();
      completed = true;
      return request.destinationPath;
    } finally {
      await reader.cancel().catch(() => undefined);
      await target.close();
      if (!completed) {
        await unlink(request.destinationPath).catch(() => undefined);
      }
    }
  }

  private sign(
    method: string,
    url: URL,
    payloadSha256: string,
    headers?: Readonly<Record<string, string>>,
  ) {
    return signS3RequestV4({
      method,
      url,
      region: this.region,
      accessKeyId: this.accessKeyId,
      secretAccessKey: this.secretAccessKey,
      payloadSha256,
      ...(this.sessionToken === undefined
        ? {}
        : {sessionToken: this.sessionToken}),
      ...(headers === undefined ? {} : {headers}),
      now: this.now(),
    });
  }

  private objectUrl(storageKey: string): URL {
    const key = normalizeStorageKey(storageKey);
    const encoded = [this.bucket, ...key.split('/')]
      .map(encodeS3PathSegment)
      .join('/');
    return new URL(`/${encoded}`, this.endpoint);
  }

  private requestSignal(signal?: AbortSignal): AbortSignal {
    const timeout = AbortSignal.timeout(this.requestTimeoutMs);
    return signal === undefined ? timeout : AbortSignal.any([signal, timeout]);
  }
}

export function createS3MediaSourceMaterializer(
  storage: Pick<S3CompatibleMediaStorage, 'downloadVerifiedObject'>,
): MediaSourceMaterializer {
  return async (asset: MediaAssetRecord, workDirectory, signal) => {
    if (
      asset.sourceStorageKey === null ||
      asset.sourceSha256 === null ||
      asset.sourceSizeBytes === null ||
      asset.sourceMimeType === null
    ) {
      throw new S3MediaStorageError(
        `Media asset ${asset.id} has no verified S3 source`,
      );
    }
    const destinationPath = join(workDirectory, 'source.bin');
    await storage.downloadVerifiedObject({
      storageKey: asset.sourceStorageKey,
      destinationPath,
      sizeBytes: asset.sourceSizeBytes,
      sha256: asset.sourceSha256,
      mimeType: asset.sourceMimeType,
      ...(signal === undefined ? {} : {signal}),
    });
    return {inputPath: destinationPath};
  };
}

function normalizeEndpoint(value: string | URL): URL {
  let endpoint: URL;
  try {
    endpoint = new URL(value.toString());
  } catch (error) {
    throw new TypeError('S3 endpoint must be an absolute HTTPS URL', {cause: error});
  }
  if (
    endpoint.protocol !== 'https:' ||
    endpoint.username ||
    endpoint.password ||
    endpoint.search ||
    endpoint.hash ||
    endpoint.pathname !== '/'
  ) {
    throw new TypeError(
      'S3 endpoint must be an HTTPS origin with no credentials, path, query or fragment',
    );
  }
  return endpoint;
}

function normalizeBucket(value: string): string {
  const bucket = value.trim();
  if (!BUCKET_PATTERN.test(bucket) || bucket.includes('..')) {
    throw new TypeError('S3 bucket must be a DNS-compatible 3-63 character name');
  }
  return bucket;
}

function normalizeStorageKey(value: string): string {
  if (
    !value ||
    value.includes('\u0000') ||
    value.includes('\\') ||
    value.startsWith('/') ||
    value.endsWith('/') ||
    Buffer.byteLength(value, 'utf8') > MAX_STORAGE_KEY_BYTES
  ) {
    throw new TypeError('S3 storageKey must be a bounded non-empty relative object key');
  }
  const segments = value.split('/');
  if (
    segments.some(
      (segment) => segment.length === 0 || segment === '.' || segment === '..',
    )
  ) {
    throw new TypeError('S3 storageKey contains an unsafe path segment');
  }
  return value;
}

function encodeS3PathSegment(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

function requestHeaders(signed: {
  authorization: string;
  headers: Readonly<Record<string, string>>;
}): Headers {
  const headers = new Headers(signed.headers);
  headers.set('authorization', signed.authorization);
  return headers;
}

function assertStoredObjectMatches(
  expected: MediaStoredObject,
  actual: MediaStoredObject,
): void {
  if (
    actual.storageKey !== expected.storageKey ||
    actual.sizeBytes !== expected.sizeBytes ||
    actual.sha256 !== expected.sha256 ||
    actual.mimeType !== expected.mimeType
  ) {
    throw new S3MediaStorageError(
      `Immutable S3 media object collision at ${expected.storageKey}`,
    );
  }
}

function validateStoredObject(value: MediaStoredObject): void {
  normalizeStorageKey(value.storageKey);
  positiveSafeInteger(value.sizeBytes, 'S3 media sizeBytes');
  normalizeSha256(value.sha256);
  normalizeMimeType(value.mimeType);
}

function normalizeSha256(value: string): string {
  if (!/^[0-9a-f]{64}$/.test(value)) {
    throw new TypeError('S3 media sha256 must be a lowercase SHA-256 hex digest');
  }
  return value;
}

function normalizeMimeType(value: string): string {
  if (!MIME_PATTERN.test(value)) {
    throw new TypeError('S3 media mimeType must be normalized');
  }
  return value;
}

function requiredContentLength(headers: Headers, storageKey: string): number {
  const raw = headers.get('content-length');
  if (raw === null || !/^\d+$/.test(raw)) {
    throw new S3MediaStorageError(
      `S3 object ${storageKey} has no valid Content-Length`,
    );
  }
  return positiveSafeInteger(Number(raw), `S3 object ${storageKey} Content-Length`);
}

function requiredMimeType(headers: Headers, storageKey: string): string {
  const raw = headers.get('content-type');
  if (raw === null) {
    throw new S3MediaStorageError(`S3 object ${storageKey} has no Content-Type`);
  }
  return normalizeMimeType(raw.trim().toLowerCase());
}

function requiredToken(value: string, name: string): string {
  const normalized = value.trim();
  if (!normalized || !/^[A-Za-z0-9._-]+$/.test(normalized)) {
    throw new TypeError(`${name} contains invalid characters`);
  }
  return normalized;
}

function requiredSecret(value: string, name: string): string {
  if (!value || /[\r\n\u0000]/.test(value)) {
    throw new TypeError(`${name} is required and must be a single-line value`);
  }
  return value;
}

function optionalSecret(value: string | undefined, name: string): string | undefined {
  if (value === undefined || value === '') return undefined;
  return requiredSecret(value, name);
}

function positiveSafeInteger(value: number, name: string): number {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new TypeError(`${name} must be a positive safe integer`);
  }
  return value;
}

function boundedPositiveInteger(
  value: number,
  name: string,
  maximum: number,
): number {
  const normalized = positiveSafeInteger(value, name);
  if (normalized > maximum) {
    throw new TypeError(`${name} must be <= ${maximum}`);
  }
  return normalized;
}

function abortIfRequested(signal?: AbortSignal): void {
  if (!signal?.aborted) return;
  if (signal.reason instanceof Error) throw signal.reason;
  const error = new Error('S3 media operation aborted');
  error.name = 'AbortError';
  throw error;
}

async function discardBody(response: Response): Promise<void> {
  await response.body?.cancel().catch(() => undefined);
}
