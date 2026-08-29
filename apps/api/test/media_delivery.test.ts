import assert from 'node:assert/strict';
import {Readable} from 'node:stream';
import {test} from 'node:test';
import {
  MediaDeliveryIntegrityError,
  MediaDeliveryRangeError,
  MediaDeliveryService,
  parseMediaRange,
  type MediaByteRange,
  type MediaDeliveryObjectReader,
  type MediaPublicationResolver,
} from '../src/media_delivery.js';
import type {
  MediaDeliveryObject,
  MediaDeliverySelection,
} from '../src/media_publication.js';

function object(
  purpose: MediaDeliveryObject['purpose'],
  derivativeKey = `mdv1_${purpose}`,
): MediaDeliveryObject {
  const extension = purpose === 'playback'
    ? '.mp4'
    : purpose === 'poster'
      ? '.jpg'
      : purpose === 'audio'
        ? '.m4a'
        : '.vtt';
  return {
    derivativeKey,
    purpose,
    storageKey: `media/asset%20one/derivatives/${derivativeKey}/attempts/claim-a${extension}`,
    mimeType: purpose === 'playback'
      ? 'video/mp4'
      : purpose === 'poster'
        ? 'image/jpeg'
        : purpose === 'audio'
          ? 'audio/mp4'
          : 'text/vtt',
    sizeBytes: 10,
    width: purpose === 'playback' || purpose === 'poster' ? 1280 : null,
    height: purpose === 'playback' || purpose === 'poster' ? 720 : null,
    durationMs: purpose === 'playback' || purpose === 'audio' ? 1_000 : null,
    container: purpose === 'playback' || purpose === 'audio' ? 'mp4' : null,
    videoCodec: purpose === 'playback' ? 'h264' : null,
    videoProfile: purpose === 'playback' ? 'main' : null,
    audioCodec: purpose === 'playback' || purpose === 'audio' ? 'aac' : null,
    colorSpace: purpose === 'playback' ? 'bt709' : null,
    dynamicRange: purpose === 'playback' || purpose === 'poster' ? 'sdr' : null,
  };
}

function selection(primary = object('playback')): MediaDeliverySelection {
  return {
    assetId: 'asset one',
    kind: primary.purpose === 'audio' ? 'audio' : 'video',
    sourceSha256: 'a'.repeat(64),
    primary,
    poster: primary.purpose === 'audio' ? null : object('poster'),
    captions: object('captions'),
  };
}

class Resolver implements MediaPublicationResolver {
  calls = 0;
  constructor(public value: MediaDeliverySelection = selection()) {}
  async resolveReady(assetId: string): Promise<MediaDeliverySelection> {
    this.calls += 1;
    assert.equal(assetId, 'asset one');
    return this.value;
  }
}

class Reader implements MediaDeliveryObjectReader {
  inspections = 0;
  opens: Array<{storageKey: string; range: MediaByteRange}> = [];
  bytes = Buffer.from('0123456789');

  async inspect(): Promise<{sizeBytes: number; mimeType: string}> {
    this.inspections += 1;
    return {sizeBytes: this.bytes.length, mimeType: 'video/mp4'};
  }

  async openRange(storageKey: string, range: MediaByteRange): Promise<Readable> {
    this.opens.push({storageKey, range});
    return Readable.from(this.bytes.subarray(range.start, range.endInclusive + 1));
  }
}

test('descriptor exposes stable API paths without source or storage identities', async () => {
  const resolver = new Resolver();
  const reader = new Reader();
  const descriptor = await new MediaDeliveryService(resolver, reader).describe(' asset one ');

  assert.equal(descriptor.schemaVersion, 1);
  assert.equal(descriptor.primary.url, '/v1/assets/asset%20one/content/primary');
  assert.equal(descriptor.poster?.url, '/v1/assets/asset%20one/content/poster');
  assert.equal(descriptor.captions?.url, '/v1/assets/asset%20one/content/captions');
  const encoded = JSON.stringify(descriptor);
  assert.equal(encoded.includes('storageKey'), false);
  assert.equal(encoded.includes('sourceSha256'), false);
  assert.equal(encoded.includes('media/asset'), false);
  assert.equal(reader.inspections, 0);
});

test('content revalidates publication and storage before opening one bounded range', async () => {
  const resolver = new Resolver();
  const reader = new Reader();
  const service = new MediaDeliveryService(resolver, reader);

  await service.describe('asset one');
  const content = await service.prepareContent('asset one', 'primary', 'bytes=2-5');
  assert.equal(resolver.calls, 2);
  assert.equal(reader.inspections, 1);
  assert.deepEqual(content.range, {start: 2, endInclusive: 5});
  assert.equal(content.partial, true);
  assert.ok(content.body);
  const chunks: Buffer[] = [];
  for await (const chunk of content.body) chunks.push(Buffer.from(chunk));
  assert.equal(Buffer.concat(chunks).toString('utf8'), '2345');
  assert.deepEqual(reader.opens, [{
    storageKey: object('playback').storageKey,
    range: {start: 2, endInclusive: 5},
  }]);
});

test('HEAD-style preparation validates storage without allocating a body stream', async () => {
  const reader = new Reader();
  const content = await new MediaDeliveryService(new Resolver(), reader).prepareContent(
    'asset one',
    'primary',
    undefined,
    false,
  );
  assert.equal(content.body, null);
  assert.equal(reader.inspections, 1);
  assert.equal(reader.opens.length, 0);
});

test('tampered database storage identity fails closed before object-store I/O', async () => {
  const bad = selection({...object('playback'), storageKey: 'media/other/derivatives/mdv1_playback/attempts/claim.mp4'});
  const reader = new Reader();
  await assert.rejects(
    new MediaDeliveryService(new Resolver(bad), reader).prepareContent(
      'asset one',
      'primary',
    ),
    MediaDeliveryIntegrityError,
  );
  assert.equal(reader.inspections, 0);
  assert.equal(reader.opens.length, 0);
});

test('stored size or MIME drift fails closed before streaming', async () => {
  const reader = new Reader();
  reader.inspect = async () => ({sizeBytes: 9, mimeType: 'video/mp4'});
  await assert.rejects(
    new MediaDeliveryService(new Resolver(), reader).prepareContent('asset one', 'primary'),
    /size changed/,
  );

  const mimeReader = new Reader();
  mimeReader.inspect = async () => ({sizeBytes: 10, mimeType: 'application/octet-stream'});
  await assert.rejects(
    new MediaDeliveryService(new Resolver(), mimeReader).prepareContent('asset one', 'primary'),
    /MIME changed/,
  );
});

test('range parser supports full, bounded, open-ended and suffix forms only', () => {
  assert.deepEqual(parseMediaRange(undefined, 10), {
    range: {start: 0, endInclusive: 9},
    partial: false,
  });
  assert.deepEqual(parseMediaRange('bytes=2-5', 10).range, {start: 2, endInclusive: 5});
  assert.deepEqual(parseMediaRange('bytes=7-', 10).range, {start: 7, endInclusive: 9});
  assert.deepEqual(parseMediaRange('bytes=-3', 10).range, {start: 7, endInclusive: 9});
  assert.deepEqual(parseMediaRange('bytes=8-99', 10).range, {start: 8, endInclusive: 9});
  for (const invalid of ['items=0-1', 'bytes=', 'bytes=8-2', 'bytes=10-', 'bytes=0-1,3-4']) {
    assert.throws(() => parseMediaRange(invalid, 10), MediaDeliveryRangeError);
  }
});
