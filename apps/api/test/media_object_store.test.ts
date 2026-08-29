import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {
  createMediaOutputPublisher,
  LocalMediaObjectStore,
  sha256File,
  type MediaObjectStore,
} from '../src/media_object_store.js';
import {MediaOutputPublicationError} from '../src/media_ffmpeg_worker.js';
import {planMediaNormalization} from '../src/media_normalization.js';

function plan() {
  const value = planMediaNormalization({
    kind: 'audio' as const,
    durationMs: 1_000,
    audioCodec: 'aac',
    sampleRateHz: 48_000,
    channels: 2,
    speech: 'none' as const,
  })[0];
  assert.ok(value);
  return value;
}

function publicationRequest(outputPath: string, storageKey: string, sizeBytes: number) {
  return {
    assetId: 'asset',
    derivativeKey: 'mdv1',
    claimToken: 'claim-a',
    outputPath,
    storageKey,
    plan: plan(),
    verifiedOutput: {
      mimeType: 'audio/mp4',
      sizeBytes,
      durationMs: 1_000,
      container: 'mp4',
      audioCodec: 'aac',
    },
  };
}

test('local object store publishes create-only bytes and exact retry is idempotent', async () => {
  const root = await mkdtemp(join(tmpdir(), 'mosaic-store-'));
  const work = await mkdtemp(join(tmpdir(), 'mosaic-work-'));
  const source = join(work, 'audio.m4a');
  await writeFile(source, Buffer.from('normalized-audio'));
  const store = new LocalMediaObjectStore({rootPath: root});
  const publish = createMediaOutputPublisher(store);
  const request = publicationRequest(source, 'media/asset/attempts/claim-a.m4a', 16);

  await publish(request);
  await publish(request);

  assert.equal(
    await readFile(join(root, 'media/asset/attempts/claim-a.m4a'), 'utf8'),
    'normalized-audio',
  );
});

test('same immutable key with different bytes is rejected rather than overwritten', async () => {
  const root = await mkdtemp(join(tmpdir(), 'mosaic-store-'));
  const work = await mkdtemp(join(tmpdir(), 'mosaic-work-'));
  const first = join(work, 'first.m4a');
  const second = join(work, 'second.m4a');
  await writeFile(first, Buffer.from('first-content'));
  await writeFile(second, Buffer.from('other-content'));
  const store = new LocalMediaObjectStore({rootPath: root});
  const publish = createMediaOutputPublisher(store);
  const key = 'media/asset/attempts/claim-a.m4a';

  await publish(publicationRequest(first, key, 13));
  await assert.rejects(
    publish(publicationRequest(second, key, 13)),
    /Immutable media object collision/,
  );
  assert.equal(await readFile(join(root, key), 'utf8'), 'first-content');
});

test('publisher rejects a local artifact whose verified size changed before publication', async () => {
  const work = await mkdtemp(join(tmpdir(), 'mosaic-work-'));
  const source = join(work, 'audio.m4a');
  await writeFile(source, Buffer.from('changed'));
  let putCalled = false;
  const store: MediaObjectStore = {
    async putFileIfAbsent(request) {
      putCalled = true;
      return request;
    },
  };
  const publish = createMediaOutputPublisher(store);

  await assert.rejects(
    publish(publicationRequest(source, 'media/asset/attempts/claim-a.m4a', 999)),
    /Verified media size changed/,
  );
  assert.equal(putCalled, false);
});

test('publisher rejects object-store metadata mismatch even if put reports success', async () => {
  const work = await mkdtemp(join(tmpdir(), 'mosaic-work-'));
  const source = join(work, 'audio.m4a');
  await writeFile(source, Buffer.from('normalized-audio'));
  const store: MediaObjectStore = {
    async putFileIfAbsent(request) {
      return {...request, sha256: '0'.repeat(64)};
    },
  };
  const publish = createMediaOutputPublisher(store);

  await assert.rejects(
    publish(publicationRequest(source, 'media/asset/attempts/claim-a.m4a', 16)),
    MediaOutputPublicationError,
  );
});

test('local store rejects traversal and absolute storage keys', async () => {
  const root = await mkdtemp(join(tmpdir(), 'mosaic-store-'));
  const work = await mkdtemp(join(tmpdir(), 'mosaic-work-'));
  const source = join(work, 'audio.m4a');
  await writeFile(source, Buffer.from('normalized-audio'));
  const store = new LocalMediaObjectStore({rootPath: root});
  const digest = await sha256File(source);
  const base = {
    sourcePath: source,
    sizeBytes: 16,
    sha256: digest,
    mimeType: 'audio/mp4',
  };

  await assert.rejects(
    store.putFileIfAbsent({...base, storageKey: '../escape.m4a'}),
    /escapes the configured object-store root/,
  );
  await assert.rejects(
    store.putFileIfAbsent({...base, storageKey: '/absolute.m4a'}),
    /relative key/,
  );
});

test('local store detects source mutation between publisher hash and completed copy', async () => {
  const root = await mkdtemp(join(tmpdir(), 'mosaic-store-'));
  const work = await mkdtemp(join(tmpdir(), 'mosaic-work-'));
  const source = join(work, 'audio.m4a');
  await writeFile(source, Buffer.from('normalized-audio'));
  const store = new LocalMediaObjectStore({rootPath: root});
  const publish = createMediaOutputPublisher(store, {
    hashFile: async (path, signal) => {
      const digest = await sha256File(path, signal);
      await writeFile(path, Buffer.from('mutated-content!'));
      return digest;
    },
  });

  await assert.rejects(
    publish(publicationRequest(source, 'media/asset/attempts/claim-a.m4a', 16)),
    /Published bytes changed while writing/,
  );
});
