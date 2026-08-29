import {createReadStream} from 'node:fs';
import {stat} from 'node:fs/promises';
import {isAbsolute, join, relative, resolve, sep} from 'node:path';
import type {
  MediaByteRange,
  MediaDeliveryObjectInspection,
  MediaDeliveryObjectReader,
} from './media_delivery.js';

const MAX_STORAGE_KEY_BYTES = 1024;

export class LocalMediaDeliveryObjectReader implements MediaDeliveryObjectReader {
  private readonly rootPath: string;

  constructor(rootPath: string) {
    if (!rootPath || !isAbsolute(rootPath)) {
      throw new TypeError('Local media delivery object root must be absolute');
    }
    this.rootPath = resolve(rootPath);
  }

  async inspect(storageKey: string): Promise<MediaDeliveryObjectInspection | null> {
    const target = this.objectPath(storageKey);
    try {
      const info = await stat(target);
      if (!info.isFile() || !Number.isSafeInteger(info.size) || info.size <= 0) {
        return null;
      }
      return {sizeBytes: info.size};
    } catch (error) {
      if (isNotFound(error)) return null;
      throw error;
    }
  }

  async openRange(
    storageKey: string,
    range: MediaByteRange,
    signal?: AbortSignal,
  ) {
    const target = this.objectPath(storageKey);
    const info = await stat(target);
    if (
      !info.isFile() ||
      !Number.isSafeInteger(info.size) ||
      info.size <= 0 ||
      !validRange(range, info.size)
    ) {
      throw new RangeError('Local media delivery range exceeds the immutable object');
    }
    return createReadStream(target, {
      start: range.start,
      end: range.endInclusive,
      ...(signal === undefined ? {} : {signal}),
    });
  }

  private objectPath(storageKey: string): string {
    const normalized = normalizeStorageKey(storageKey);
    const target = resolve(join(this.rootPath, ...normalized.split('/')));
    const rel = relative(this.rootPath, target);
    if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
      throw new TypeError('Media delivery storageKey escapes the configured object root');
    }
    return target;
  }
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
    throw new TypeError('Media delivery storageKey must be a bounded relative key');
  }
  const segments = value.split('/');
  if (segments.some((segment) => segment.length === 0 || segment === '.' || segment === '..')) {
    throw new TypeError('Media delivery storageKey contains an unsafe path segment');
  }
  return value;
}

function validRange(range: MediaByteRange, sizeBytes: number): boolean {
  return Number.isSafeInteger(range.start) &&
    Number.isSafeInteger(range.endInclusive) &&
    range.start >= 0 &&
    range.endInclusive >= range.start &&
    range.endInclusive < sizeBytes;
}

function isNotFound(error: unknown): boolean {
  return error !== null &&
    typeof error === 'object' &&
    'code' in error &&
    (error as {code?: unknown}).code === 'ENOENT';
}
