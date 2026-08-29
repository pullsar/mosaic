import {createHash} from 'node:crypto';
import type {Pool} from 'pg';
import {canonicalJson, type CanonicalJsonValue} from './media.js';

export const CANVAS_ASSET_SCHEMA_VERSION = 1;
export const MAX_CANVAS_ELEMENTS = 128;
export const MAX_CANVAS_DOCUMENT_BYTES = 64 * 1024;

export type CanvasTone = 'foreground' | 'muted' | 'accent' | 'surface';
export type CanvasLineCap = 'round' | 'butt' | 'square';

export interface CanvasLineElement {
  type: 'line';
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  width: number;
  cap: CanvasLineCap;
  tone: CanvasTone;
}

export interface CanvasRectElement {
  type: 'rect';
  x: number;
  y: number;
  width: number;
  height: number;
  strokeWidth: number;
  radius: number;
  fill: boolean;
  tone: CanvasTone;
}

export interface CanvasCircleElement {
  type: 'circle';
  x: number;
  y: number;
  radius: number;
  strokeWidth: number;
  fill: boolean;
  tone: CanvasTone;
}

export interface CanvasLabelElement {
  type: 'label';
  x: number;
  y: number;
  text: string;
  scale: number;
  tone: CanvasTone;
}

export type CanvasElement =
  | CanvasLineElement
  | CanvasRectElement
  | CanvasCircleElement
  | CanvasLabelElement;

export interface CanvasAssetDocument {
  schemaVersion: 1;
  id: string;
  elements: readonly CanvasElement[];
  semanticLabel?: string;
}

export interface CanvasAssetRecord {
  id: string;
  schemaVersion: 1;
  state: 'ready' | 'revoked';
  contentSha256: string;
  document: CanvasAssetDocument;
}

export class CanvasAssetIdentityConflictError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CanvasAssetIdentityConflictError';
  }
}

export class CanvasAssetIntegrityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CanvasAssetIntegrityError';
  }
}

type CanvasRow = {
  id: string;
  schema_version: number;
  state: 'ready' | 'revoked';
  content_sha256: string;
  document: unknown;
};

export interface CanvasAssetResolver {
  resolveReady(assetId: string): Promise<CanvasAssetDocument | null>;
}

export class PostgresCanvasAssetRepository implements CanvasAssetResolver {
  constructor(private readonly pool: Pool) {}

  async register(
    input: unknown,
  ): Promise<{status: 'inserted' | 'duplicate'; asset: CanvasAssetRecord}> {
    const document = normalizeCanvasAssetDocument(input);
    const serialized = canonicalJson(document);
    const contentSha256 = sha256(serialized);
    const inserted = await this.pool.query<CanvasRow>(
      `insert into canvas_assets (
         id, schema_version, state, content_sha256, document
       ) values ($1, $2, 'ready', $3, $4::jsonb)
       on conflict (id) do nothing
       returning id, schema_version, state, content_sha256, document`,
      [
        document.id,
        CANVAS_ASSET_SCHEMA_VERSION,
        contentSha256,
        serialized,
      ],
    );
    const row = inserted.rows[0];
    if (row !== undefined) {
      return {status: 'inserted', asset: recordFromRow(row)};
    }

    const existing = await this.get(document.id);
    if (existing === null) {
      throw new Error(`Canvas asset ${document.id} disappeared after conflict`);
    }
    if (
      existing.state !== 'ready' ||
      existing.contentSha256 !== contentSha256 ||
      canonicalJson(existing.document) !== serialized
    ) {
      throw new CanvasAssetIdentityConflictError(
        `Canvas asset ${document.id} is immutable once registered`,
      );
    }
    return {status: 'duplicate', asset: existing};
  }

  async get(assetId: string): Promise<CanvasAssetRecord | null> {
    const id = canvasAssetId(assetId);
    const result = await this.pool.query<CanvasRow>(
      `select id, schema_version, state, content_sha256, document
       from canvas_assets
       where id = $1`,
      [id],
    );
    const row = result.rows[0];
    return row === undefined ? null : recordFromRow(row);
  }

  async resolveReady(assetId: string): Promise<CanvasAssetDocument | null> {
    const record = await this.get(assetId);
    return record?.state === 'ready' ? record.document : null;
  }

  async revoke(assetId: string): Promise<boolean> {
    const result = await this.pool.query(
      `update canvas_assets
       set state = 'revoked', revoked_at = now()
       where id = $1 and state = 'ready'`,
      [canvasAssetId(assetId)],
    );
    return result.rowCount === 1;
  }
}

export function normalizeCanvasAssetDocument(input: unknown): CanvasAssetDocument {
  const root = record(input, 'canvas asset');
  exactKeys(root, ['schemaVersion', 'id', 'elements', 'semanticLabel'], 'canvas asset');
  if (root.schemaVersion !== CANVAS_ASSET_SCHEMA_VERSION) {
    throw new TypeError(
      `canvas asset schemaVersion must be ${CANVAS_ASSET_SCHEMA_VERSION}`,
    );
  }
  const id = canvasAssetId(root.id);
  if (!Array.isArray(root.elements)) {
    throw new TypeError('canvas asset elements must be an array');
  }
  if (root.elements.length === 0 || root.elements.length > MAX_CANVAS_ELEMENTS) {
    throw new RangeError(
      `canvas asset elements must contain 1-${MAX_CANVAS_ELEMENTS} entries`,
    );
  }
  const elements = Object.freeze(
    root.elements.map((value, index) => normalizeElement(value, index)),
  );
  const semanticLabel = root.semanticLabel === undefined
    ? undefined
    : boundedText(root.semanticLabel, 'semanticLabel', 500);
  const document: CanvasAssetDocument = Object.freeze({
    schemaVersion: 1,
    id,
    elements,
    ...(semanticLabel === undefined ? {} : {semanticLabel}),
  });
  const serialized = canonicalJson(document);
  if (Buffer.byteLength(serialized, 'utf8') > MAX_CANVAS_DOCUMENT_BYTES) {
    throw new RangeError(
      `canvas asset document exceeds ${MAX_CANVAS_DOCUMENT_BYTES} UTF-8 bytes`,
    );
  }
  return document;
}

function normalizeElement(value: unknown, index: number): CanvasElement {
  const element = record(value, `elements[${index}]`);
  const type = textEnum(
    element.type,
    ['line', 'rect', 'circle', 'label'] as const,
    `elements[${index}].type`,
  );
  const tone = element.tone === undefined
    ? 'foreground'
    : textEnum(
        element.tone,
        ['foreground', 'muted', 'accent', 'surface'] as const,
        `elements[${index}].tone`,
      );
  switch (type) {
    case 'line': {
      exactKeys(
        element,
        ['type', 'x1', 'y1', 'x2', 'y2', 'width', 'cap', 'tone'],
        `elements[${index}]`,
      );
      const normalized: CanvasLineElement = Object.freeze({
        type: 'line',
        x1: unit(element.x1, `elements[${index}].x1`),
        y1: unit(element.y1, `elements[${index}].y1`),
        x2: unit(element.x2, `elements[${index}].x2`),
        y2: unit(element.y2, `elements[${index}].y2`),
        width: element.width === undefined
          ? 0.012
          : positiveUnit(element.width, `elements[${index}].width`),
        cap: element.cap === undefined
          ? 'round'
          : textEnum(
              element.cap,
              ['round', 'butt', 'square'] as const,
              `elements[${index}].cap`,
            ),
        tone,
      });
      return normalized;
    }
    case 'rect': {
      exactKeys(
        element,
        [
          'type',
          'x',
          'y',
          'width',
          'height',
          'strokeWidth',
          'radius',
          'fill',
          'tone',
        ],
        `elements[${index}]`,
      );
      const x = unit(element.x, `elements[${index}].x`);
      const y = unit(element.y, `elements[${index}].y`);
      const width = positiveUnit(element.width, `elements[${index}].width`);
      const height = positiveUnit(element.height, `elements[${index}].height`);
      if (x + width > 1 || y + height > 1) {
        throw new RangeError(`elements[${index}] rectangle must remain inside canvas`);
      }
      return Object.freeze({
        type: 'rect',
        x,
        y,
        width,
        height,
        strokeWidth: element.strokeWidth === undefined
          ? 0.008
          : positiveUnit(
              element.strokeWidth,
              `elements[${index}].strokeWidth`,
            ),
        radius: element.radius === undefined
          ? 0.02
          : unit(element.radius, `elements[${index}].radius`),
        fill: element.fill === undefined
          ? false
          : boolean(element.fill, `elements[${index}].fill`),
        tone,
      });
    }
    case 'circle': {
      exactKeys(
        element,
        ['type', 'x', 'y', 'radius', 'strokeWidth', 'fill', 'tone'],
        `elements[${index}]`,
      );
      const x = unit(element.x, `elements[${index}].x`);
      const y = unit(element.y, `elements[${index}].y`);
      const radius = positiveUnit(element.radius, `elements[${index}].radius`);
      if (x - radius < 0 || x + radius > 1 || y - radius < 0 || y + radius > 1) {
        throw new RangeError(`elements[${index}] circle must remain inside canvas`);
      }
      return Object.freeze({
        type: 'circle',
        x,
        y,
        radius,
        strokeWidth: element.strokeWidth === undefined
          ? 0.008
          : positiveUnit(
              element.strokeWidth,
              `elements[${index}].strokeWidth`,
            ),
        fill: element.fill === undefined
          ? false
          : boolean(element.fill, `elements[${index}].fill`),
        tone,
      });
    }
    case 'label': {
      exactKeys(
        element,
        ['type', 'x', 'y', 'text', 'scale', 'tone'],
        `elements[${index}]`,
      );
      return Object.freeze({
        type: 'label',
        x: unit(element.x, `elements[${index}].x`),
        y: unit(element.y, `elements[${index}].y`),
        text: boundedText(element.text, `elements[${index}].text`, 240),
        scale: element.scale === undefined
          ? 0.08
          : positiveUnit(element.scale, `elements[${index}].scale`),
        tone,
      });
    }
  }
}

function record(value: unknown, name: string): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${name} must be an object`);
  }
  return value as Record<string, unknown>;
}

function exactKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
  name: string,
): void {
  const known = new Set(allowed);
  for (const key of Object.keys(value)) {
    if (!known.has(key)) throw new TypeError(`${name} contains unsupported field ${key}`);
  }
}

function canvasAssetId(value: unknown): string {
  return boundedText(value, 'canvas asset id', 200);
}

function boundedText(value: unknown, name: string, maxLength: number): string {
  if (typeof value !== 'string') throw new TypeError(`${name} must be a string`);
  const normalized = value.trim();
  if (
    normalized.length === 0 ||
    normalized.length > maxLength ||
    /[\u0000-\u001F\u007F]/.test(normalized)
  ) {
    throw new TypeError(`${name} must be 1-${maxLength} printable characters`);
  }
  return normalized;
}

function number(value: unknown, name: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new TypeError(`${name} must be a finite number`);
  }
  return Object.is(value, -0) ? 0 : value;
}

function unit(value: unknown, name: string): number {
  const normalized = number(value, name);
  if (normalized < 0 || normalized > 1) {
    throw new RangeError(`${name} must be between 0 and 1`);
  }
  return normalized;
}

function positiveUnit(value: unknown, name: string): number {
  const normalized = number(value, name);
  if (normalized <= 0 || normalized > 1) {
    throw new RangeError(`${name} must be greater than 0 and at most 1`);
  }
  return normalized;
}

function boolean(value: unknown, name: string): boolean {
  if (typeof value !== 'boolean') throw new TypeError(`${name} must be boolean`);
  return value;
}

function textEnum<T extends string>(
  value: unknown,
  allowed: readonly T[],
  name: string,
): T {
  if (typeof value !== 'string' || !allowed.includes(value as T)) {
    throw new TypeError(`${name} must be one of ${allowed.join(', ')}`);
  }
  return value as T;
}

function recordFromRow(row: CanvasRow): CanvasAssetRecord {
  if (row.schema_version !== CANVAS_ASSET_SCHEMA_VERSION) {
    throw new CanvasAssetIntegrityError(
      `Canvas asset ${row.id} has unsupported schema version ${row.schema_version}`,
    );
  }
  if (row.state !== 'ready' && row.state !== 'revoked') {
    throw new CanvasAssetIntegrityError(`Canvas asset ${row.id} has invalid state`);
  }
  const document = normalizeCanvasAssetDocument(row.document);
  if (document.id !== row.id) {
    throw new CanvasAssetIntegrityError(`Canvas asset ${row.id} document identity changed`);
  }
  const contentSha256 = sha256(canonicalJson(document));
  if (contentSha256 !== row.content_sha256) {
    throw new CanvasAssetIntegrityError(`Canvas asset ${row.id} content hash changed`);
  }
  return Object.freeze({
    id: row.id,
    schemaVersion: 1,
    state: row.state,
    contentSha256,
    document,
  });
}

function sha256(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex');
}
