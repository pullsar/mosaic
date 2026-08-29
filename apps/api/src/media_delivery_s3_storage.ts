import {Readable} from 'node:stream';
import type {
  MediaByteRange,
  MediaDeliveryObjectInspection,
  MediaDeliveryObjectReader,
} from './media_delivery.js';
import {signS3RequestV4} from './s3_sigv4.js';

export type S3MediaDeliveryFetch = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

export interface S3MediaDeliveryObjectReaderOptions {
  endpoint: string | URL;
  bucket: string;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
  requestTimeoutMs?: number;
  fetch?: S3MediaDeliveryFetch;
  now?: () => Date;
}

export class S3MediaDeliveryError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'S3MediaDeliveryError';
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
 * Read-only consumer adapter for immutable S3-compatible media derivatives.
 *
 * It deliberately exposes only HEAD and exact single-range GET. Worker PUT and
 * source-materialization APIs stay in S3CompatibleMediaStorage, so the API
 * process cannot accidentally reuse a write/source path for consumer delivery.
 */
export class S3MediaDeliveryObjectReader implements MediaDeliveryObjectReader {
  private readonly endpoint: URL;
  private readonly bucket: string;
  private readonly region: string;
  private readonly accessKeyId: string;
  private readonly secretAccessKey: string;
  private readonly sessionToken: string | undefined;
  private readonly requestTimeoutMs: number;
  private readonly fetcher: S3MediaDeliveryFetch;
  private readonly now: () => Date;

  constructor(options: S3MediaDeliveryObjectReaderOptions) {
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

  async inspect(
    storageKey: string,
    signal?: AbortSignal,
  ): Promise<MediaDeliveryObjectInspection | null> {
    const key = normalizeStorageKey(storageKey);
    abortIfRequested(signal);
    const response = await this.fetcher(this.objectUrl(key), {
      method: 'HEAD',
      headers: this.signedHeaders('HEAD', key),
      signal: this.requestSignal(signal),
    });
    if (response.status === 404) {
      await discardBody(response);
      return null;
    }
    if (!response.ok) {
      await discardBody(response);
      throw new S3MediaDeliveryError(
        `S3 HEAD ${key} failed with HTTP ${response.status}`,
      );
    }
    await discardBody(response);
    const sizeBytes = requiredContentLength(response.headers, key);
    const mimeType = requiredMimeType(response.headers, key);
    const sha256 = response.headers.get('x-amz-meta-mosaic-sha256');
    if (sha256 === null || !/^[0-9a-f]{64}$/.test(sha256)) {
      throw new S3MediaDeliveryError(
        `S3 delivery object ${key} lacks valid Mosaic SHA-256 metadata`,
      );
    }
    return {sizeBytes, mimeType};
  }

  async openRange(
    storageKey: string,
    range: MediaByteRange,
    signal?: AbortSignal,
  ): Promise<Readable> {
    const key = normalizeStorageKey(storageKey);
    validateRange(range);
    abortIfRequested(signal);
    const rangeHeader = `bytes=${range.start}-${range.endInclusive}`;
    const response = await this.fetcher(this.objectUrl(key), {
      method: 'GET',
      headers: this.signedHeaders('GET', key, {range: rangeHeader}),
      signal: this.requestSignal(signal),
    });
    if (response.status !== 206 || response.body === null) {
      await discardBody(response);
      throw new S3MediaDeliveryError(
        `S3 ranged GET ${key} failed with HTTP ${response.status}`,
      );
    }

    const expectedLength = range.endInclusive - range.start + 1;
    if (requiredContentLength(response.headers, key) !== expectedLength) {
      await discardBody(response);
      throw new S3MediaDeliveryError(
        `S3 ranged GET ${key} returned an unexpected Content-Length`,
      );
    }
    assertContentRange(response.headers, key, range);
    requiredMimeType(response.headers, key);
    return webBodyToNodeReadable(response.body);
  }

  private signedHeaders(
    method: string,
    storageKey: string,
    headers?: Readonly<Record<string, string>>,
  ): Headers {
    const signed = signS3RequestV4({
      method,
      url: this.objectUrl(storageKey),
      region: this.region,
      accessKeyId: this.accessKeyId,
      secretAccessKey: this.secretAccessKey,
      payloadSha256: EMPTY_SHA256,
      ...(this.sessionToken === undefined
        ? {}
        : {sessionToken: this.sessionToken}),
      ...(headers === undefined ? {} : {headers}),
      now: this.now(),
    });
    const result = new Headers(signed.headers);
    result.set('authorization', signed.authorization);
    return result;
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

function webBodyToNodeReadable(body: ReadableStream<Uint8Array>): Readable {
  const reader = body.getReader();
  return Readable.from(
    (async function* () {
      try {
        while (true) {
          const {done, value} = await reader.read();
          if (done) return;
          if (value.byteLength > 0) yield Buffer.from(value);
        }
      } finally {
        await reader.cancel().catch(() => undefined);
      }
    })(),
  );
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
  if (segments.some((segment) => !segment || segment === '.' || segment === '..')) {
    throw new TypeError('S3 storageKey contains an unsafe path segment');
  }
  return value;
}

function validateRange(range: MediaByteRange): void {
  if (
    !Number.isSafeInteger(range.start) ||
    !Number.isSafeInteger(range.endInclusive) ||
    range.start < 0 ||
    range.endInclusive < range.start
  ) {
    throw new TypeError('S3 media delivery range must be a valid inclusive byte range');
  }
}

function assertContentRange(
  headers: Headers,
  storageKey: string,
  range: MediaByteRange,
): void {
  const raw = headers.get('content-range');
  const match = raw === null ? null : /^bytes (\d+)-(\d+)\/(\d+)$/.exec(raw);
  if (match === null) {
    throw new S3MediaDeliveryError(
      `S3 ranged object ${storageKey} has no valid Content-Range`,
    );
  }
  const start = Number(match[1]);
  const endInclusive = Number(match[2]);
  const total = Number(match[3]);
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(endInclusive) ||
    !Number.isSafeInteger(total) ||
    start !== range.start ||
    endInclusive !== range.endInclusive ||
    total <= endInclusive
  ) {
    throw new S3MediaDeliveryError(
      `S3 ranged object ${storageKey} returned an unexpected Content-Range`,
    );
  }
}

function requiredContentLength(headers: Headers, storageKey: string): number {
  const raw = headers.get('content-length');
  const value = raw === null ? Number.NaN : Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new S3MediaDeliveryError(
      `S3 delivery object ${storageKey} has no valid Content-Length`,
    );
  }
  return value;
}

function requiredMimeType(headers: Headers, storageKey: string): string {
  const raw = headers.get('content-type')?.split(';', 1)[0]?.trim().toLowerCase();
  if (raw === undefined || !MIME_PATTERN.test(raw)) {
    throw new S3MediaDeliveryError(
      `S3 delivery object ${storageKey} has no valid Content-Type`,
    );
  }
  return raw;
}

function encodeS3PathSegment(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
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

function boundedPositiveInteger(value: number, name: string, maximum: number): number {
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new TypeError(`${name} must be a positive safe integer <= ${maximum}`);
  }
  return value;
}

function abortIfRequested(signal?: AbortSignal): void {
  if (signal?.aborted) {
    const error = new Error('S3 media delivery aborted');
    error.name = 'AbortError';
    throw error;
  }
}

async function discardBody(response: Response): Promise<void> {
  if (response.body !== null) await response.body.cancel().catch(() => undefined);
}
