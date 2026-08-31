import assert from 'node:assert/strict';
import {mkdir, mkdtemp, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {test} from 'node:test';
import {LocalMediaDeliveryObjectReader} from '../src/media_delivery_local_storage.js';

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'mosaic-delivery-local-'));
  const key = 'media/asset/derivatives/mdv1_test/attempts/claim.mp4';
  const target = join(root, ...key.split('/'));
  await mkdir(dirname(target), {recursive: true});
  await writeFile(target, Buffer.from('0123456789'));
  return {root, key};
}

test('local delivery reader inspects and streams only the requested immutable range', async () => {
  const {root, key} = await fixture();
  const reader = new LocalMediaDeliveryObjectReader(root);
  assert.deepEqual(await reader.inspect(key), {sizeBytes: 10});
  const stream = await reader.openRange(key, {start: 2, endInclusive: 5});
  const chunks: Buffer[] = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  assert.equal(Buffer.concat(chunks).toString('utf8'), '2345');
});

test('local delivery reader treats missing/non-file objects as unavailable', async () => {
  const {root} = await fixture();
  const reader = new LocalMediaDeliveryObjectReader(root);
  assert.equal(await reader.inspect('media/missing/object.mp4'), null);
});

test('local delivery reader rejects traversal and out-of-bounds ranges before streaming', async () => {
  const {root, key} = await fixture();
  const reader = new LocalMediaDeliveryObjectReader(root);
  await assert.rejects(reader.inspect('../escape'), /unsafe path segment/);
  await assert.rejects(
    reader.openRange(key, {start: 0, endInclusive: 10}),
    /range exceeds/,
  );
});
