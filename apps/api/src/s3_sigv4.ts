import {createHash, createHmac} from 'node:crypto';

export interface S3SignedRequest {
  authorization: string;
  headers: Readonly<Record<string, string>>;
  signedHeaders: string;
}

export interface SignS3RequestV4Input {
  method: string;
  url: URL;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
  payloadSha256: string;
  headers?: Readonly<Record<string, string>>;
  now: Date;
}

/**
 * Deliberately narrow SigV4 implementation for S3 media requests with no query
 * string. Keeping this surface small avoids a general AWS client in the worker;
 * AWS's published S3 calculation vectors lock the canonicalization in tests.
 */
export function signS3RequestV4(input: SignS3RequestV4Input): S3SignedRequest {
  if (input.url.protocol !== 'https:' || input.url.username || input.url.password) {
    throw new TypeError('S3 signed request URL must use HTTPS and contain no credentials');
  }
  if (input.url.search || input.url.hash) {
    throw new TypeError('S3 media requests do not support query strings or fragments');
  }
  const method = requiredToken(input.method, 'S3 method').toUpperCase();
  const region = requiredToken(input.region, 'S3 region');
  const accessKeyId = requiredToken(input.accessKeyId, 'S3 access key ID');
  const secretAccessKey = requiredSecret(input.secretAccessKey, 'S3 secret access key');
  const sessionToken = optionalSecret(input.sessionToken, 'S3 session token');
  validateSha256(input.payloadSha256, 'payload sha256');
  if (!Number.isFinite(input.now.getTime())) {
    throw new TypeError('S3 signing date must be valid');
  }

  const amzDate = input.now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const headers: Record<string, string> = {};
  for (const [name, value] of Object.entries(input.headers ?? {})) {
    const lower = canonicalHeaderName(name);
    if (lower === 'authorization' || lower === 'host') {
      throw new TypeError(`S3 request header ${name} is managed by the signer`);
    }
    headers[lower] = canonicalHeaderValue(value);
  }
  headers['x-amz-content-sha256'] = input.payloadSha256;
  headers['x-amz-date'] = amzDate;
  if (sessionToken !== undefined) headers['x-amz-security-token'] = sessionToken;

  const canonicalEntries: ReadonlyArray<readonly [string, string]> = [
    ['host', canonicalHeaderValue(input.url.host)],
    ...Object.entries(headers),
  ].sort(([left], [right]) => left.localeCompare(right));
  const signedHeaders = canonicalEntries.map(([name]) => name).join(';');
  const canonicalHeaders = canonicalEntries
    .map(([name, value]) => `${name}:${value}\n`)
    .join('');
  const canonicalRequest = [
    method,
    input.url.pathname || '/',
    '',
    canonicalHeaders,
    signedHeaders,
    input.payloadSha256,
  ].join('\n');
  const scope = `${dateStamp}/${region}/s3/aws4_request`;
  const stringToSign = [
    'AWS4-HMAC-SHA256',
    amzDate,
    scope,
    sha256Text(canonicalRequest),
  ].join('\n');
  const dateKey = hmacSha256(`AWS4${secretAccessKey}`, dateStamp);
  const regionKey = hmacSha256(dateKey, region);
  const serviceKey = hmacSha256(regionKey, 's3');
  const signingKey = hmacSha256(serviceKey, 'aws4_request');
  const signature = createHmac('sha256', signingKey)
    .update(stringToSign, 'utf8')
    .digest('hex');
  const authorization =
    `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope},` +
    `SignedHeaders=${signedHeaders},Signature=${signature}`;

  return Object.freeze({
    authorization,
    headers: Object.freeze({...headers}),
    signedHeaders,
  });
}

function canonicalHeaderName(name: string): string {
  const normalized = name.trim().toLowerCase();
  if (!/^[a-z0-9!#$%&'*+.^_`|~-]+$/.test(normalized)) {
    throw new TypeError(`Invalid S3 request header name ${name}`);
  }
  return normalized;
}

function canonicalHeaderValue(value: string): string {
  if (/\r|\n|\u0000/.test(value)) {
    throw new TypeError('S3 request header contains an unsafe character');
  }
  return value.trim().replace(/[\t ]+/g, ' ');
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

function validateSha256(value: string, name: string): void {
  if (!/^[0-9a-f]{64}$/.test(value)) {
    throw new TypeError(`${name} must be a lowercase SHA-256 hex digest`);
  }
}

function sha256Text(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}

function hmacSha256(key: string | Buffer, value: string): Buffer {
  return createHmac('sha256', key).update(value, 'utf8').digest();
}
