import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  S3MediaDeliveryError,
  S3MediaDeliveryObjectReader,
  type S3MediaDeliveryFetch,
} from '../src/media_delivery_s3_storage.js';

const now = new Date('2026-08-29T19:00:00.000Z');

function reader(fetcher: S3MediaDeliveryFetch): S3MediaDeliveryObjectReader {
  return new S3MediaDeliveryObjectReader({
    endpoint: 'https://storage.example.test',
    bucket: 'media-bucket',
    region: 'auto',
    accessKeyId: 'ACCESS123',
    secretAccessKey: 'secret/with+symbols=',
    requestTimeoutMs: 5_000,
    fetch: fetcher,
    now: () => now,
  });
}

function requestHeaders(init?: RequestInit): Headers {
  return new Headers(init?.headers);
}

test('S3 delivery inspect accepts only Mosaic-published immutable metadata', async () => {
  const value = reader(async (input, init) => {
    assert.equal(init?.method, 'HEAD');
    assert.equal(
      new URL(input.toString()).pathname,
      '/media-bucket/media/asset%20one/output.mp4',
    );
    assert.match(
      requestHeaders(init).get('authorization') ?? '',
      /^AWS4-HMAC-SHA256 /,
    );
    return new Response(null, {
      status: 200,
      headers: {
        'content-length': '10',
        'content-type': 'video/mp4',
        'x-amz-meta-mosaic-sha256': 'a'.repeat(64),
      },
    });
  });

  assert.deepEqual(await value.inspect('media/asset one/output.mp4'), {
    sizeBytes: 10,
    mimeType: 'video/mp4',
  });
});

test('S3 delivery inspect returns null for missing objects and rejects foreign metadata', async () => {
  const missing = reader(async () => new Response(null, {status: 404}));
  assert.equal(await missing.inspect('media/missing/output.mp4'), null);

  const foreign = reader(async () =>
    new Response(null, {
      status: 200,
      headers: {'content-length': '10', 'content-type': 'video/mp4'},
    }),
  );
  await assert.rejects(
    foreign.inspect('media/asset/output.mp4'),
    /lacks valid Mosaic SHA-256 metadata/,
  );
});

test('S3 delivery streams only an exact signed byte range with backpressure', async () => {
  const bytes = Buffer.from('0123456789');
  const value = reader(async (_input, init) => {
    assert.equal(init?.method, 'GET');
    const headers = requestHeaders(init);
    assert.equal(headers.get('range'), 'bytes=2-5');
    const authorization = headers.get('authorization') ?? '';
    assert.match(authorization, /^AWS4-HMAC-SHA256 /);
    assert.match(authorization, /SignedHeaders=[^,]*range/);
    return new Response(bytes.subarray(2, 6), {
      status: 206,
      headers: {
        'content-length': '4',
        'content-range': 'bytes 2-5/10',
        'content-type': 'video/mp4',
      },
    });
  });

  const stream = await value.openRange(
    'media/asset/output.mp4',
    {start: 2, endInclusive: 5},
  );
  const chunks: Buffer[] = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  assert.equal(Buffer.concat(chunks).toString('utf8'), '2345');
});

test('S3 delivery rejects full-body fallback and inconsistent range metadata', async () => {
  const fullBody = reader(async () =>
    new Response(Buffer.from('0123'), {
      status: 200,
      headers: {'content-length': '4', 'content-type': 'video/mp4'},
    }),
  );
  await assert.rejects(
    fullBody.openRange('media/asset/output.mp4', {start: 0, endInclusive: 3}),
    /ranged GET.*HTTP 200/,
  );

  const wrongRange = reader(async () =>
    new Response(Buffer.from('0123'), {
      status: 206,
      headers: {
        'content-length': '4',
        'content-range': 'bytes 1-4/10',
        'content-type': 'video/mp4',
      },
    }),
  );
  await assert.rejects(
    wrongRange.openRange('media/asset/output.mp4', {start: 0, endInclusive: 3}),
    S3MediaDeliveryError,
  );
});

test('S3 delivery rejects unsafe configuration, keys and ranges', async () => {
  assert.throws(
    () => new S3MediaDeliveryObjectReader({
      endpoint: 'http://storage.example.test',
      bucket: 'media-bucket',
      region: 'auto',
      accessKeyId: 'ACCESS123',
      secretAccessKey: 'secret',
    }),
    /HTTPS origin/,
  );
  const value = reader(async () => assert.fail('network should not be reached'));
  await assert.rejects(value.inspect('../escape'), /unsafe path segment/);
  await assert.rejects(
    value.openRange('media/asset/output.mp4', {start: 5, endInclusive: 4}),
    /valid inclusive byte range/,
  );
});
