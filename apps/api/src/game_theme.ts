import {createHash} from 'node:crypto';
import type {Pool} from 'pg';
import {canonicalJson} from './media.js';

const MAX_IDENTIFIER_LENGTH = 200;
const MAX_COLLECTION_SIZE = 64;
const MAX_VARIANTS = 32;
const MAX_MEDIA_PER_VARIANT = 16;
const MAX_AUDIO_DURATION_MS = 180_000;

export interface GameFamilyReference {
  id: string;
  revisionId: string;
}

export interface GamePresentationReference {
  themeId: string;
  themeRevisionId: string;
  variantId: string;
}

export interface GameFamilyManifest extends GameFamilyReference {
  playRevisions: readonly {playId: string; revisionId: string}[];
  requiredPlatformFlags: readonly string[];
  compatibleThemes: readonly {themeId: string; themeRevisionId: string}[];
}

export type GameThemeMediaKind = 'image' | 'audio';
export type GameThemeMediaRole = 'background' | 'bed' | 'effect';

export interface GameThemeMedia {
  assetId: string;
  kind: GameThemeMediaKind;
  role: GameThemeMediaRole;
  gain: number;
  durationMs: number;
}

export interface GameThemeVariant {
  id: string;
  familyRevisions: readonly GameFamilyReference[];
  media: readonly GameThemeMedia[];
  contrastRatio: number;
  targetExclusions: readonly string[];
  suppressMusicAndEffects: boolean;
}

export interface GameThemeManifest {
  id: string;
  revisionId: string;
  variants: readonly GameThemeVariant[];
}

export interface GameThemeAssetReadiness {
  assertReady(assetIds: readonly string[]): Promise<void>;
}

export class GameThemeIdentityConflictError extends Error {
  constructor(identity: string) {
    super(`Game theme registry identity has immutable content: ${identity}`);
    this.name = 'GameThemeIdentityConflictError';
  }
}

/** Persists canonical family and theme revisions without permitting mutation. */
export class PostgresGameThemeRegistry {
  constructor(
    private readonly pool: Pool,
    private readonly assetReadiness?: GameThemeAssetReadiness,
  ) {}

  async publishFamily(value: unknown): Promise<GameFamilyManifest> {
    const manifest = normalizeGameFamilyManifest(value);
    await this.publish('game_family_revisions', manifest, `${manifest.id}/${manifest.revisionId}`);
    return manifest;
  }

  async publishTheme(value: unknown): Promise<GameThemeManifest> {
    const manifest = normalizeGameThemeManifest(value);
    const assetIds = manifest.variants.flatMap((variant) => variant.media.map((media) => media.assetId));
    await this.assetReadiness?.assertReady(assetIds);
    await this.publish('game_theme_revisions', manifest, `${manifest.id}/${manifest.revisionId}`);
    return manifest;
  }

  private async publish(
    table: 'game_family_revisions' | 'game_theme_revisions',
    manifest: GameFamilyManifest | GameThemeManifest,
    identity: string,
  ): Promise<void> {
    const document = canonicalJson(manifest);
    const hash = createHash('sha256').update(document, 'utf8').digest('hex');
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      const existing = await client.query<{content_sha256: string; document: unknown}>(
        `select content_sha256, document from ${table} where id = $1 and revision_id = $2 for update`,
        [manifest.id, manifest.revisionId],
      );
      if (existing.rowCount === 1) {
        const row = existing.rows[0];
        if (!row || row.content_sha256 !== hash || canonicalJson(row.document) !== document) {
          throw new GameThemeIdentityConflictError(identity);
        }
      } else {
        await client.query(
          `insert into ${table} (id, revision_id, content_sha256, document)
           values ($1, $2, $3, $4::jsonb)`,
          [manifest.id, manifest.revisionId, hash, document],
        );
      }
      await client.query('commit');
    } catch (error) {
      await client.query('rollback').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  }
}

/** Validates immutable, managed-only registry data before it is published. */
export function normalizeGameFamilyManifest(value: unknown): GameFamilyManifest {
  const input = exactRecord(value, ['id', 'revisionId', 'playRevisions', 'requiredPlatformFlags', 'compatibleThemes'], 'family');
  const playRevisions = array(input.playRevisions, 'family.playRevisions', 1);
  const flags = strings(input.requiredPlatformFlags, 'family.requiredPlatformFlags');
  const compatibleThemes = array(input.compatibleThemes, 'family.compatibleThemes', 0).map((item) => {
    const reference = exactRecord(item, ['themeId', 'themeRevisionId'], 'family.compatibleThemes[]');
    return Object.freeze({
      themeId: identifier(reference.themeId, 'family.compatibleThemes[].themeId'),
      themeRevisionId: identifier(reference.themeRevisionId, 'family.compatibleThemes[].themeRevisionId'),
    });
  });
  const normalizedPlayRevisions = playRevisions.map((item) => {
    const reference = exactRecord(item, ['playId', 'revisionId'], 'family.playRevisions[]');
    return Object.freeze({
      playId: identifier(reference.playId, 'family.playRevisions[].playId'),
      revisionId: identifier(reference.revisionId, 'family.playRevisions[].revisionId'),
    });
  });
  unique(normalizedPlayRevisions.map((item) => `${item.playId}\n${item.revisionId}`), 'family.playRevisions');
  unique(flags, 'family.requiredPlatformFlags');
  unique(compatibleThemes.map((item) => `${item.themeId}\n${item.themeRevisionId}`), 'family.compatibleThemes');
  return Object.freeze({
    id: identifier(input.id, 'family.id'),
    revisionId: identifier(input.revisionId, 'family.revisionId'),
    playRevisions: Object.freeze(normalizedPlayRevisions),
    requiredPlatformFlags: Object.freeze(flags),
    compatibleThemes: Object.freeze(compatibleThemes),
  });
}

/** Validates variants without allowing direct URLs or executable configuration. */
export function normalizeGameThemeManifest(value: unknown): GameThemeManifest {
  const input = exactRecord(value, ['id', 'revisionId', 'variants'], 'theme');
  const variants = array(input.variants, 'theme.variants', 1, MAX_VARIANTS).map((item) => {
    const variant = exactRecord(
      item,
      ['id', 'familyRevisions', 'media', 'contrastRatio', 'targetExclusions', 'suppressMusicAndEffects'],
      'theme.variants[]',
    );
    const families = array(variant.familyRevisions, 'theme.variants[].familyRevisions', 1).map((family) => {
      const reference = exactRecord(family, ['id', 'revisionId'], 'theme.variants[].familyRevisions[]');
      return Object.freeze({
        id: identifier(reference.id, 'theme.variants[].familyRevisions[].id'),
        revisionId: identifier(reference.revisionId, 'theme.variants[].familyRevisions[].revisionId'),
      });
    });
    const media = array(variant.media, 'theme.variants[].media', 1, MAX_MEDIA_PER_VARIANT).map((item) => {
      const media = exactRecord(item, ['assetId', 'kind', 'role', 'gain', 'durationMs'], 'theme.variants[].media[]');
      const kind = mediaKind(media.kind);
      const role = mediaRole(media.role);
      if ((kind === 'image' && role !== 'background') || (kind === 'audio' && role === 'background')) {
        throw new TypeError('theme media kind and role are incompatible');
      }
      const durationMs = boundedInteger(media.durationMs, 'theme.variants[].media[].durationMs', 0, MAX_AUDIO_DURATION_MS);
      if (kind === 'audio' && durationMs < 1) throw new TypeError('audio durationMs must be positive');
      if (kind === 'image' && durationMs !== 0) throw new TypeError('image durationMs must be zero');
      return Object.freeze({
        assetId: managedAssetId(media.assetId),
        kind,
        role,
        gain: gain(media.gain),
        durationMs,
      });
    });
    const targetExclusions = strings(variant.targetExclusions, 'theme.variants[].targetExclusions');
    unique(families.map((item) => `${item.id}\n${item.revisionId}`), 'theme.variants[].familyRevisions');
    unique(media.map((item) => item.assetId), 'theme.variants[].media assetId');
    unique(targetExclusions, 'theme.variants[].targetExclusions');
    if (typeof variant.suppressMusicAndEffects !== 'boolean') {
      throw new TypeError('theme.variants[].suppressMusicAndEffects must be boolean');
    }
    return Object.freeze({
      id: identifier(variant.id, 'theme.variants[].id'),
      familyRevisions: Object.freeze(families),
      media: Object.freeze(media),
      contrastRatio: contrastRatio(variant.contrastRatio),
      targetExclusions: Object.freeze(targetExclusions),
      suppressMusicAndEffects: variant.suppressMusicAndEffects,
    });
  });
  unique(variants.map((variant) => variant.id), 'theme.variants');
  return Object.freeze({
    id: identifier(input.id, 'theme.id'),
    revisionId: identifier(input.revisionId, 'theme.revisionId'),
    variants: Object.freeze(variants),
  });
}

/** Ensures a published frozen reference belongs to the approved immutable matrix. */
export function assertGamePresentationCompatible(
  familyReference: GameFamilyReference,
  presentation: GamePresentationReference,
  families: readonly GameFamilyManifest[],
  themes: readonly GameThemeManifest[],
): void {
  const familyId = identifier(familyReference.id, 'gameFamily.id');
  const familyRevisionId = identifier(familyReference.revisionId, 'gameFamily.revisionId');
  const themeId = identifier(presentation.themeId, 'presentation.themeId');
  const themeRevisionId = identifier(presentation.themeRevisionId, 'presentation.themeRevisionId');
  const variantId = identifier(presentation.variantId, 'presentation.variantId');
  const family = families.find((item) => item.id === familyId && item.revisionId === familyRevisionId);
  if (!family) throw new Error('family_revision_not_found');
  const theme = themes.find((item) => item.id === themeId && item.revisionId === themeRevisionId);
  if (!theme) throw new Error('theme_revision_not_found');
  if (!family.compatibleThemes.some((item) => item.themeId === themeId && item.themeRevisionId === themeRevisionId)) {
    throw new Error('theme_revision_not_approved');
  }
  const variant = theme.variants.find((item) => item.id === variantId);
  if (!variant) throw new Error('theme_variant_not_found');
  if (!variant.familyRevisions.some((item) => item.id === familyId && item.revisionId === familyRevisionId)) {
    throw new Error('theme_variant_not_compatible');
  }
}

function exactRecord(value: unknown, keys: readonly string[], name: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new TypeError(`${name} must be an object`);
  const record = value as Record<string, unknown>;
  const actual = Object.keys(record).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new TypeError(`${name} has unexpected fields`);
  }
  return record;
}

function array(value: unknown, name: string, minimum: number, maximum = MAX_COLLECTION_SIZE): unknown[] {
  if (!Array.isArray(value) || value.length < minimum || value.length > maximum) {
    throw new TypeError(`${name} has an invalid length`);
  }
  return value;
}

function strings(value: unknown, name: string): string[] {
  return array(value, name, 0).map((item) => identifier(item, name));
}

function identifier(value: unknown, name: string): string {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > MAX_IDENTIFIER_LENGTH) {
    throw new TypeError(`${name} must be a bounded identifier`);
  }
  return value;
}

function managedAssetId(value: unknown): string {
  const assetId = identifier(value, 'theme media assetId');
  if (assetId.includes('://') || assetId.includes('/') || assetId.includes('\\')) {
    throw new TypeError('theme media assetId must identify managed media');
  }
  return assetId;
}

function mediaKind(value: unknown): GameThemeMediaKind {
  if (value === 'image' || value === 'audio') return value;
  throw new TypeError('theme media kind is invalid');
}

function mediaRole(value: unknown): GameThemeMediaRole {
  if (value === 'background' || value === 'bed' || value === 'effect') return value;
  throw new TypeError('theme media role is invalid');
}

function boundedInteger(value: unknown, name: string, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new TypeError(`${name} is out of range`);
  }
  return value as number;
}

function gain(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 1) {
    throw new TypeError('theme media gain must be finite from zero to one');
  }
  return value;
}

function contrastRatio(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 3 || value > 21) {
    throw new TypeError('theme contrastRatio must be finite from 3 to 21');
  }
  return value;
}

function unique(values: readonly string[], name: string): void {
  if (new Set(values).size !== values.length) throw new TypeError(`${name} must be unique`);
}
