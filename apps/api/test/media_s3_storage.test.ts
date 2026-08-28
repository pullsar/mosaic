import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtemp, readFile, stat, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {
  createS3MediaSourceMaterializer,
  S3CompatibleMediaStorage,
  S3MediaStorageError,
  type S3Fetch,
} from '../src/media_s3_storage.js';
import type {MediaAssetRecord} from '../src/media_repository.js';

const now = new Date('2026-08-28T11:00:00.000Z');

function digest(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

function storage(fetcher: S3Fetch): S3CompatibleMediaStorage {
  return new S3CompatibleMediaStorage({
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

function headers(init?: RequestInit): Headers {
  return new Headers(init?.headers);
}

test('S3 store publishes create-only bytes then verifies immutable HEAD metadata', async () => {
  const work = await mkdtemp(join(tmpdir(), 'mosaic-s3-put-'));
  const sourcePath = join(work, 'output.m4a');
  const bytes = Buffer.from('normalized-audio');
  const sha256 = digest(bytes);
  await writeFile(sourcePath, bytes);
  const methods: string[] = [];

  const store = storage(async (input, init) => {
    const url = new URL(input.toString());
    const method = init?.method ?? 'GET';
    methods.push(method);
    if (method === 'PUT') {
      assert.equal(url.pathname, '/media-bucket/media/asset%20one/output.m4a');
      const requestHeaders = headers(init);
      assert.equal(requestHeaders.get('if-none-match'), '*');
      assert.equal(requestHeaders.get('content-type'), 'audio/mp4');
      assert.equal(requestHeaders.get('x-amz-meta-mosaic-sha256'), sha256);
      assert.match(requestHeaders.get('authorization') ?? '', /^AWS4-HMAC-SHA256 /);
      const uploaded = Buffer.from(await new Response(init?.body).arrayBuffer());
      assert.deepEqual(uploaded, bytes);
      return new Response(null, {status: 200});
    }
    assert.equal(method, 'HEAD');
    return new Response(null, {
      status: 200,
      headers: {
        'content-length': String(bytes.length),
        'content-type': 'audio/mp4',
        'x-amz-meta-mosaic-sha256': sha256,
      },
    });
  });

  const stored = await store.putFileIfAbsent({
    storageKey: 'media/asset one/output.m4a',
    sourcePath,
    sizeBytes: bytes.length,
    sha256,
    mimeType: 'audio/mp4',
  });
  assert.deepEqual(stored, {
    storageKey: 'media/asset one/output.m4a',
    sizeBytes: bytes.length,
    sha256,
    mimeType: 'audio/mp4',
  });
  assert.deepEqual(methods, ['PUT', 'HEAD']);
});

test('S3 store treats conditional PUT conflict as idempotent only for exact metadata', async () => {
  const work = await mkdtemp(join(tmpdir(), 'mosaic-s3-retry-'));
  const sourcePath = join(work, 'output.mp4');
  const bytes = Buffer.from('compatible-video');
  const sha256 = digest(bytes);
  await writeFile(sourcePath, bytes);

  const exact = storage(async (_input, init) => {
    if (init?.method === 'PUT') return new Response(null, {status: 412});
    return new Response(null, {
      status: 200,
      headers: {
        'content-length': String(bytes.length),
        'content-type': 'video/mp4',
        'x-amz-meta-mosaic-sha256': sha256,
      },
    });
  });
  const request = {
    storageKey: 'media/asset/derivative.mp4',
    sourcePath,
    sizeBytes: bytes.length,
    sha256,
    mimeType: 'video/mp4',
  } as const;
  assert.equal((await exact.putFileIfAbsent(request)).sha256, sha256);

  const collision = storage(async (_input, init) => {
    if (init?.method === 'PUT') return new Response(null, {status: 412});
    return new Response(null, {
      status: 200,
      headers: {
        'content-length': String(bytes.length),
        'content-type': 'video/mp4',
        'x-amz-meta-mosaic-sha256': '0'.repeat(64),
      },
    });
  });
  await assert.rejects(
    collision.putFileIfAbsent(request),
    (error: unknown) =>
      error instanceof S3MediaStorageError && /collision/.test(error.message),
  );
});

test('S3 source download streams to an exclusive file and revalidates size, MIME and SHA-256', async () => {
  const work = await mkdtemp(join(tmpdir(), 'mosaic-s3-get-'));
  const destinationPath = join(work, 'source.bin');
  const bytes = Buffer.from('verified-source');
  const sha256 = digest(bytes);
  let requestedPath = '';

  const store = storage(async (input, init) => {
    assert.equal(init?.method, 'GET');
    requestedPath = new URL(input.toString()).pathname;
    assert.match(headers(init).get('authorization') ?? '', /^AWS4-HMAC-SHA256 /);
    return new Response(bytes, {
      status: 200,
      headers: {
        'content-length': String(bytes.length),
        'content-type': 'video/quicktime',
      },
    });
  });

  assert.equal(
    await store.downloadVerifiedObject({
      storageKey: 'quarantine/asset ü/source.mov',
      destinationPath,
      sizeBytes: bytes.length,
      sha256,
      mimeType: 'video/quicktime',
    }),
    destinationPath,
  );
  assert.equal(
    requestedPath,
    '/media-bucket/quarantine/asset%20%C3%BC/source.mov',
  );
  assert.deepEqual(await readFile(destinationPath), bytes);
});

test('S3 source corruption fails closed and removes the partial materialization', async () => {
  const work = await mkdtemp(join(tmpdir(), 'mosaic-s3-corrupt-'));
  const destinationPath = join(work, 'source.bin');
  const bytes = Buffer.from('wrong-source');
  const store = storage(async () =>
    new Response(bytes, {
      status: 200,
      headers: {
        'content-length': String(bytes.length),
        'content-type': 'audio/wav',
      },
    }),
  );

  await assert.rejects(
    store.downloadVerifiedObject({
      storageKey: 'quarantine/asset/source.wav',
      destinationPath,
      sizeBytes: bytes.length,
      sha256: '0'.repeat(64),
      mimeType: 'audio/wav',
    }),
    /digest mismatch/,
  );
  await assert.rejects(stat(destinationPath), (error: unknown) =>
    error !== null &&
    typeof error === 'object' &&
    'code' in error &&
    (error as {code?: unknown}).code === 'ENOENT',
  );
});

test('S3 materializer maps immutable asset identity into the isolated attempt directory', async () => {
  const work = await mkdtemp(join(tmpdir(), 'mosaic-s3-materialize-'));
  const observed: {
    download?: Parameters<S3CompatibleMediaStorage['downloadVerifiedObject']>[0];
  } = {};
  const materializer = createS3MediaSourceMaterializer({
    async downloadVerifiedObject(request) {
      observed.download = request;
      await writeFile(request.destinationPath, Buffer.from('source'));
      return request.destinationPath;
    },
  });
  const asset: MediaAssetRecord = {
    id: 'asset_s3',
    ownerActorId: 'actor_s3',
    kind: 'video',
    state: 'uploaded',
    sourceStorageKey: 'quarantine/asset_s3/source.mov',
    sourceSha256: 'a'.repeat(64),
    sourceMimeType: 'video/quicktime',
    sourceSizeBytes: 6,
    sourceWidth: 1920,
    sourceHeight: 1080,
    sourceDurationMs: 1_000,
    sourceMetadata: {},
    errorCode: null,
  };

  const result = await materializer(asset, work);
  assert.equal(result.inputPath, join(work, 'source.bin'));
  const download = observed.download;
  assert.ok(download);
  assert.equal(download.storageKey, asset.sourceStorageKey);
  assert.equal(download.sha256, asset.sourceSha256);
  assert.equal(download.sizeBytes, asset.sourceSizeBytes);
  assert.equal(download.mimeType, asset.sourceMimeType);
});

test('S3 storage rejects unsafe endpoints and ambiguous object keys before I/O', async () => {
  assert.throws(
    () => new S3CompatibleMediaStorage({
      endpoint: 'http://storage.example.test',
      bucket: 'media-bucket',
      region: 'auto',
      accessKeyId: 'ACCESS123',
      secretAccessKey: 'secret',
    }),
    /HTTPS origin/,
  );
  assert.throws(
    () => new S3CompatibleMediaStorage({
      endpoint: 'https://storage.example.test/prefix',
      bucket: 'media-bucket',
      region: 'auto',
      accessKeyId: 'ACCESS123',
      secretAccessKey: 'secret',
    }),
    /HTTPS origin/,
  );

  let fetchCalled = false;
  const store = storage(async () => {
    fetchCalled = true;
    return new Response(null, {status: 500});
  });
  const work = await mkdtemp(join(tmpdir(), 'mosaic-s3-invalid-'));
  const sourcePath = join(work, 'source.bin');
  await writeFile(sourcePath, Buffer.from('x'));
  await assert.rejects(
    store.putFileIfAbsent({
      storageKey: '../escape.bin',
      sourcePath,
      sizeBytes: 1,
      sha256: digest(Buffer.from('x')),
      mimeType: 'application/octet-stream',
    }),
    /unsafe path segment/,
  );
  assert.equal(fetchCalled, false);
});
