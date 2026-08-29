import {Readable} from 'node:stream';
import type {
  MediaDeliveryObject,
  MediaDeliverySelection,
} from './media_publication.js';

export type MediaDeliveryVariant = 'primary' | 'poster' | 'captions';

export interface MediaPublicationResolver {
  resolveReady(assetId: string): Promise<MediaDeliverySelection>;
}

export interface MediaDeliveryObjectInspection {
  sizeBytes: number;
  mimeType?: string;
}

export interface MediaDeliveryObjectReader {
  inspect(
    storageKey: string,
    signal?: AbortSignal,
  ): Promise<MediaDeliveryObjectInspection | null>;
  openRange(
    storageKey: string,
    range: MediaByteRange,
    signal?: AbortSignal,
  ): Promise<Readable>;
}

export interface MediaByteRange {
  start: number;
  endInclusive: number;
}

export interface MediaDeliveryDescriptorObject {
  variant: MediaDeliveryVariant;
  url: string;
  mimeType: string;
  sizeBytes: number;
  width: number | null;
  height: number | null;
  durationMs: number | null;
  container: string | null;
  videoCodec: string | null;
  videoProfile: string | null;
  audioCodec: string | null;
  colorSpace: string | null;
  dynamicRange: 'sdr' | 'hdr' | null;
}

export interface MediaDeliveryDescriptor {
  schemaVersion: 1;
  assetId: string;
  kind: 'video' | 'audio';
  primary: MediaDeliveryDescriptorObject;
  poster: MediaDeliveryDescriptorObject | null;
  captions: MediaDeliveryDescriptorObject | null;
}

export interface PreparedMediaContent {
  assetId: string;
  variant: MediaDeliveryVariant;
  mimeType: string;
  sizeBytes: number;
  range: MediaByteRange;
  partial: boolean;
  body: Readable | null;
}

export class MediaDeliveryRangeError extends Error {
  constructor(public readonly sizeBytes: number) {
    super('Requested media byte range is not satisfiable');
    this.name = 'MediaDeliveryRangeError';
  }
}

export class MediaDeliveryIntegrityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'MediaDeliveryIntegrityError';
  }
}

export class MediaDeliveryService {
  constructor(
    private readonly publication: MediaPublicationResolver,
    private readonly reader: MediaDeliveryObjectReader,
  ) {}

  async describe(assetId: string): Promise<MediaDeliveryDescriptor> {
    const selection = await this.publication.resolveReady(requiredText(assetId, 'assetId'));
    return descriptor(selection);
  }

  async prepareContent(
    assetId: string,
    variant: MediaDeliveryVariant,
    rangeHeader?: string,
    includeBody = true,
  ): Promise<PreparedMediaContent> {
    const id = requiredText(assetId, 'assetId');
    const selection = await this.publication.resolveReady(id);
    const object = deliveryObjectForVariant(selection, variant);
    if (object === null) {
      throw new MediaDeliveryIntegrityError(
        `Asset ${id} does not publish delivery variant ${variant}`,
      );
    }
    assertStorageIdentity(id, object);

    const inspected = await this.reader.inspect(object.storageKey);
    if (inspected === null) {
      throw new MediaDeliveryIntegrityError(
        `Published object for ${id}/${variant} is missing from storage`,
      );
    }
    if (inspected.sizeBytes !== object.sizeBytes) {
      throw new MediaDeliveryIntegrityError(
        `Published object size changed for ${id}/${variant}`,
      );
    }
    if (inspected.mimeType !== undefined && inspected.mimeType !== object.mimeType) {
      throw new MediaDeliveryIntegrityError(
        `Published object MIME changed for ${id}/${variant}`,
      );
    }

    const parsed = parseMediaRange(rangeHeader, object.sizeBytes);
    const body = includeBody
      ? await this.reader.openRange(object.storageKey, parsed.range)
      : null;
    return {
      assetId: id,
      variant,
      mimeType: object.mimeType,
      sizeBytes: object.sizeBytes,
      range: parsed.range,
      partial: parsed.partial,
      body,
    };
  }
}

export function parseMediaRange(
  header: string | undefined,
  sizeBytes: number,
): {range: MediaByteRange; partial: boolean} {
  if (!Number.isSafeInteger(sizeBytes) || sizeBytes <= 0) {
    throw new MediaDeliveryIntegrityError('Published object size is invalid');
  }
  if (header === undefined) {
    return {
      range: {start: 0, endInclusive: sizeBytes - 1},
      partial: false,
    };
  }

  const value = header.trim();
  if (value.includes(',')) throw new MediaDeliveryRangeError(sizeBytes);
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (match === null) throw new MediaDeliveryRangeError(sizeBytes);
  const startRaw = match[1] ?? '';
  const endRaw = match[2] ?? '';
  if (startRaw === '' && endRaw === '') throw new MediaDeliveryRangeError(sizeBytes);

  if (startRaw === '') {
    const suffixLength = safeRangeInteger(endRaw, sizeBytes);
    if (suffixLength <= 0) throw new MediaDeliveryRangeError(sizeBytes);
    const length = Math.min(suffixLength, sizeBytes);
    return {
      range: {start: sizeBytes - length, endInclusive: sizeBytes - 1},
      partial: true,
    };
  }

  const start = safeRangeInteger(startRaw, sizeBytes);
  if (start >= sizeBytes) throw new MediaDeliveryRangeError(sizeBytes);
  const requestedEnd = endRaw === ''
    ? sizeBytes - 1
    : safeRangeInteger(endRaw, sizeBytes);
  if (requestedEnd < start) throw new MediaDeliveryRangeError(sizeBytes);
  return {
    range: {start, endInclusive: Math.min(requestedEnd, sizeBytes - 1)},
    partial: true,
  };
}

function descriptor(selection: MediaDeliverySelection): MediaDeliveryDescriptor {
  return Object.freeze({
    schemaVersion: 1,
    assetId: selection.assetId,
    kind: selection.kind,
    primary: publicObject(selection.assetId, 'primary', selection.primary),
    poster: selection.poster === null
      ? null
      : publicObject(selection.assetId, 'poster', selection.poster),
    captions: selection.captions === null
      ? null
      : publicObject(selection.assetId, 'captions', selection.captions),
  });
}

function publicObject(
  assetId: string,
  variant: MediaDeliveryVariant,
  object: MediaDeliveryObject,
): MediaDeliveryDescriptorObject {
  return Object.freeze({
    variant,
    url: `/v1/assets/${encodeURIComponent(assetId)}/content/${variant}`,
    mimeType: object.mimeType,
    sizeBytes: object.sizeBytes,
    width: object.width,
    height: object.height,
    durationMs: object.durationMs,
    container: object.container,
    videoCodec: object.videoCodec,
    videoProfile: object.videoProfile,
    audioCodec: object.audioCodec,
    colorSpace: object.colorSpace,
    dynamicRange: object.dynamicRange,
  });
}

function deliveryObjectForVariant(
  selection: MediaDeliverySelection,
  variant: MediaDeliveryVariant,
): MediaDeliveryObject | null {
  switch (variant) {
    case 'primary':
      return selection.primary;
    case 'poster':
      return selection.poster;
    case 'captions':
      return selection.captions;
  }
}

function assertStorageIdentity(assetId: string, object: MediaDeliveryObject): void {
  const asset = encodeURIComponent(assetId);
  const derivative = encodeURIComponent(object.derivativeKey);
  const prefix = `media/${asset}/derivatives/${derivative}/attempts/`;
  const extension = switchExtension(object.purpose);
  if (!object.storageKey.startsWith(prefix) || !object.storageKey.endsWith(extension)) {
    throw new MediaDeliveryIntegrityError(
      `Published storage identity is invalid for ${assetId}/${object.purpose}`,
    );
  }
  const attempt = object.storageKey.slice(prefix.length, -extension.length);
  if (attempt.length === 0 || attempt.includes('/')) {
    throw new MediaDeliveryIntegrityError(
      `Published storage attempt identity is invalid for ${assetId}/${object.purpose}`,
    );
  }
}

function switchExtension(purpose: MediaDeliveryObject['purpose']): string {
  switch (purpose) {
    case 'playback':
      return '.mp4';
    case 'poster':
      return '.jpg';
    case 'audio':
      return '.m4a';
    case 'captions':
      return '.vtt';
  }
}

function safeRangeInteger(value: string, sizeBytes: number): number {
  if (!/^\d+$/.test(value)) throw new MediaDeliveryRangeError(sizeBytes);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new MediaDeliveryRangeError(sizeBytes);
  }
  return parsed;
}

function requiredText(value: string, name: string): string {
  const normalized = value.trim();
  if (!normalized || normalized.length > 200 || normalized.includes('\u0000')) {
    throw new TypeError(`${name} must be 1-200 characters with no NUL bytes`);
  }
  return normalized;
}
