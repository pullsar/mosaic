import {createReadStream} from 'node:fs';
import {mkdir, open, stat, unlink} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {dirname, isAbsolute, join, relative, resolve, sep} from 'node:path';
import {
  MediaOutputPublicationError,
  type MediaOutputPublisher,
} from './media_ffmpeg_worker.js';

export interface MediaStoredObject {
  storageKey: string;
  sizeBytes: number;
  sha256: string;
  mimeType: string;
}

export interface MediaObjectPutRequest extends MediaStoredObject {
  sourcePath: string;
  signal?: AbortSignal;
}

export interface MediaObjectStore {
  /// Must atomically create `storageKey`, or return metadata for the existing
  /// immutable object at that key. It must never overwrite existing bytes.
  putFileIfAbsent(request: MediaObjectPutRequest): Promise<MediaStoredObject>;
}

export interface MediaOutputPublisherOptions {
  hashFile?: (path: string, signal?: AbortSignal) => Promise<string>;
}

export function createMediaOutputPublisher(
  store: MediaObjectStore,
  options: MediaOutputPublisherOptions = {},
): MediaOutputPublisher {
  const hashFile = options.hashFile ?? sha256File;
  return async (request) => {
    abortIfRequested(request.signal);
    const local = await stat(request.outputPath);
    if (!local.isFile() || !Number.isSafeInteger(local.size) || local.size <= 0) {
      throw new MediaOutputPublicationError('Verified media output is not a non-empty regular file');
    }
    if (local.size !== request.verifiedOutput.sizeBytes) {
      throw new MediaOutputPublicationError(
        `Verified media size changed before publication: ${local.size} != ${request.verifiedOutput.sizeBytes}`,
      );
    }
    const sha256 = await hashFile(request.outputPath, request.signal);
    abortIfRequested(request.signal);
    const expected: MediaStoredObject = {
      storageKey: request.storageKey,
      sizeBytes: local.size,
      sha256,
      mimeType: request.verifiedOutput.mimeType,
    };
    const stored = await store.putFileIfAbsent({
      ...expected,
      sourcePath: request.outputPath,
      ...(request.signal === undefined ? {} : {signal: request.signal}),
    });
    if (
      stored.storageKey !== expected.storageKey ||
      stored.sizeBytes !== expected.sizeBytes ||
      stored.sha256 !== expected.sha256 ||
      stored.mimeType !== expected.mimeType
    ) {
      throw new MediaOutputPublicationError(
        `Immutable media object collision at ${request.storageKey}`,
      );
    }
  };
}

export async function sha256File(path: string, signal?: AbortSignal): Promise<string> {
  abortIfRequested(signal);
  const hash = createHash('sha256');
  const stream = createReadStream(path);
  const abort = (): void => {
    stream.destroy(abortError());
  };
  signal?.addEventListener('abort', abort, {once: true});
  try {
    for await (const chunk of stream) {
      abortIfRequested(signal);
      hash.update(chunk);
    }
    return hash.digest('hex');
  } finally {
    signal?.removeEventListener('abort', abort);
    stream.destroy();
  }
}

export interface LocalMediaObjectStoreOptions {
  rootPath: string;
  hashFile?: (path: string, signal?: AbortSignal) => Promise<string>;
}

/// CI/development implementation with create-only filesystem semantics.
/// Production can supply an S3/R2/GCS implementation behind the same contract.
export class LocalMediaObjectStore implements MediaObjectStore {
  private readonly rootPath: string;
  private readonly hashFile: (path: string, signal?: AbortSignal) => Promise<string>;

  constructor(options: LocalMediaObjectStoreOptions) {
    if (!options.rootPath || !isAbsolute(options.rootPath)) {
      throw new TypeError('Local media object-store rootPath must be absolute');
    }
    this.rootPath = resolve(options.rootPath);
    this.hashFile = options.hashFile ?? sha256File;
  }

  async putFileIfAbsent(request: MediaObjectPutRequest): Promise<MediaStoredObject> {
    abortIfRequested(request.signal);
    validateStoredObject(request);
    if (!isAbsolute(request.sourcePath)) {
      throw new TypeError('Media object sourcePath must be absolute');
    }
    const targetPath = this.objectPath(request.storageKey);
    await mkdir(dirname(targetPath), {recursive: true});

    let target;
    try {
      target = await open(targetPath, 'wx', 0o640);
    } catch (error) {
      if (isAlreadyExists(error)) {
        return await this.existingObject(request, targetPath);
      }
      throw error;
    }

    let completed = false;
    const input = createReadStream(request.sourcePath);
    const abort = (): void => {
      input.destroy(abortError());
    };
    request.signal?.addEventListener('abort', abort, {once: true});
    try {
      for await (const chunk of input) {
        abortIfRequested(request.signal);
        if (!Buffer.isBuffer(chunk)) {
          throw new MediaOutputPublicationError('Media source stream returned a non-buffer chunk');
        }
        let offset = 0;
        while (offset < chunk.length) {
          abortIfRequested(request.signal);
          const {bytesWritten} = await target.write(
            chunk,
            offset,
            chunk.length - offset,
            null,
          );
          if (bytesWritten <= 0) {
            throw new MediaOutputPublicationError(
              `Failed to make progress while writing ${request.storageKey}`,
            );
          }
          offset += bytesWritten;
        }
      }
      await target.sync();
      completed = true;
    } finally {
      request.signal?.removeEventListener('abort', abort);
      input.destroy();
      await target.close();
      if (!completed) {
        await unlink(targetPath).catch(() => undefined);
      }
    }

    const stored = await this.existingObject(request, targetPath);
    if (stored.sha256 !== request.sha256 || stored.sizeBytes !== request.sizeBytes) {
      await unlink(targetPath).catch(() => undefined);
      throw new MediaOutputPublicationError(
        `Published bytes changed while writing ${request.storageKey}`,
      );
    }
    return stored;
  }

  private async existingObject(
    request: MediaObjectPutRequest,
    targetPath: string,
  ): Promise<MediaStoredObject> {
    const info = await stat(targetPath);
    if (!info.isFile() || !Number.isSafeInteger(info.size) || info.size <= 0) {
      throw new MediaOutputPublicationError(
        `Existing media object is not a non-empty regular file: ${request.storageKey}`,
      );
    }
    const sha256 = await this.hashFile(targetPath, request.signal);
    return {
      storageKey: request.storageKey,
      sizeBytes: info.size,
      sha256,
      mimeType: request.mimeType,
    };
  }

  private objectPath(storageKey: string): string {
    if (!storageKey || storageKey.includes('\u0000') || storageKey.startsWith('/')) {
      throw new TypeError('Media storageKey must be a non-empty relative key');
    }
    const target = resolve(join(this.rootPath, ...storageKey.split('/')));
    const rel = relative(this.rootPath, target);
    if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
      throw new TypeError('Media storageKey escapes the configured object-store root');
    }
    return target;
  }
}

function validateStoredObject(value: MediaStoredObject): void {
  if (!value.storageKey || value.storageKey.includes('\u0000')) {
    throw new TypeError('Media storageKey must be non-empty and contain no NUL bytes');
  }
  if (!Number.isSafeInteger(value.sizeBytes) || value.sizeBytes <= 0) {
    throw new TypeError('Media sizeBytes must be a positive safe integer');
  }
  if (!/^[0-9a-f]{64}$/.test(value.sha256)) {
    throw new TypeError('Media sha256 must be a lowercase SHA-256 hex digest');
  }
  if (!/^[a-z0-9][a-z0-9.+-]*\/[a-z0-9][a-z0-9.+-]*$/.test(value.mimeType)) {
    throw new TypeError('Media mimeType must be a normalized MIME type');
  }
}

function abortIfRequested(signal?: AbortSignal): void {
  if (signal?.aborted) throw abortError();
}

function abortError(): Error {
  const error = new Error('Media publication aborted');
  error.name = 'AbortError';
  return error;
}

function isAlreadyExists(error: unknown): boolean {
  return (
    error !== null &&
    typeof error === 'object' &&
    'code' in error &&
    (error as {code?: unknown}).code === 'EEXIST'
  );
}
