import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {
  CanvasAssetIdentityConflictError,
  CanvasAssetIntegrityError,
  MAX_CANVAS_ELEMENTS,
  PostgresCanvasAssetRepository,
  normalizeCanvasAssetDocument,
} from '../src/canvas_asset.js';

const databaseUrl = process.env.DATABASE_URL;

function puzzle(id = 'puzzle_canvas') {
  return {
    schemaVersion: 1,
    id,
    semanticLabel: 'Matchstick equation',
    elements: [
      {type: 'line', x1: 0.1, y1: 0.2, x2: 0.4, y2: 0.2},
      {type: 'rect', x: 0.5, y: 0.2, width: 0.2, height: 0.2, fill: true},
      {type: 'circle', x: 0.3, y: 0.7, radius: 0.08, tone: 'accent'},
      {type: 'label', x: 0.7, y: 0.7, text: '8 − 4 = 4'},
    ],
  };
}

function palette() {
  return {
    background: '#102030',
    foreground: '#F0F0F0',
    accent: '#FFCC00',
    muted: '#8090A0',
    surface: '#405060',
  };
}

function assertPaletteRejected(invalidPalette: unknown): void {
  assert.throws(
    () => normalizeCanvasAssetDocument({...puzzle(), palette: invalidPalette}),
    (error: unknown) =>
      (error instanceof TypeError || error instanceof RangeError) &&
      !/canvas asset contains unsupported field palette/.test(error.message),
  );
}

async function migrateUp(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(
      process.execPath,
      ['--import', 'tsx', 'src/db/migrate.ts', 'up'],
      {
        cwd: new URL('../', import.meta.url),
        env: process.env,
        stdio: 'inherit',
      },
    );
    child.on('exit', (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`migration up exited ${String(code)}`)),
    );
    child.on('error', reject);
  });
}

test('canvas normalization materializes defaults into one bounded schema-v1 document', () => {
  const document = normalizeCanvasAssetDocument(puzzle());
  assert.equal(document.schemaVersion, 1);
  assert.equal(document.id, 'puzzle_canvas');
  assert.equal(document.elements.length, 4);
  assert.deepEqual({...document.elements[0]}, {
    type: 'line',
    x1: 0.1,
    y1: 0.2,
    x2: 0.4,
    y2: 0.2,
    width: 0.012,
    cap: 'round',
    tone: 'foreground',
  });
  assert.deepEqual({...document.elements[1]}, {
    type: 'rect',
    x: 0.5,
    y: 0.2,
    width: 0.2,
    height: 0.2,
    strokeWidth: 0.008,
    radius: 0.02,
    fill: true,
    tone: 'foreground',
  });
  assert.equal(Object.isFrozen(document), true);
  assert.equal(Object.isFrozen(document.elements), true);
  assert.equal(Reflect.has(document, 'palette'), false);
});

test('canvas normalization preserves one immutable semantic palette', () => {
  const sourcePalette = palette();
  const document = normalizeCanvasAssetDocument({
    ...puzzle(),
    palette: sourcePalette,
  });
  const normalizedPalette = Reflect.get(document, 'palette');

  assert.deepEqual(normalizedPalette, palette());
  assert.equal(Object.isFrozen(document), true);
  assert.equal(Object.isFrozen(normalizedPalette), true);
  sourcePalette.background = '#FFFFFF';
  assert.deepEqual(normalizedPalette, palette());
});

test('canvas palette rejects non-objects and incomplete or unknown roles', () => {
  for (const invalidPalette of [null, '#102030', []]) {
    assertPaletteRejected(invalidPalette);
  }

  const {surface: _, ...missingSurface} = palette();
  assertPaletteRejected(missingSurface);
  assertPaletteRejected({...palette(), highlight: '#FFFFFF'});
});

test('canvas palette accepts only canonical opaque RGB colors', () => {
  const invalidColors = {
    background: '#FFF',
    foreground: '#abcdef',
    accent: '#FFFFFFFF',
    muted: 'FFFFFF',
    surface: '#GGGGGG',
  } as const;
  for (const [role, invalidColor] of Object.entries(invalidColors)) {
    assertPaletteRejected({...palette(), [role]: invalidColor});
  }
});

test('canvas palette enforces readable foreground and accent contrast', () => {
  assertPaletteRejected({
    ...palette(),
    background: '#FFFFFF',
    foreground: '#FFFFFF',
    accent: '#000000',
  });
  assertPaletteRejected({
    ...palette(),
    background: '#FFFFFF',
    foreground: '#777777',
    accent: '#000000',
  });
  assertPaletteRejected({
    ...palette(),
    background: '#FFFFFF',
    foreground: '#000000',
    accent: '#A0A0A0',
  });
});

test('canvas validation rejects ambiguous, oversized and out-of-bounds documents', () => {
  assert.throws(
    () => normalizeCanvasAssetDocument({...puzzle(), futureField: true}),
    /unsupported field futureField/,
  );
  assert.throws(
    () => normalizeCanvasAssetDocument({
      ...puzzle(),
      elements: Array.from({length: MAX_CANVAS_ELEMENTS + 1}, () => ({
        type: 'label', x: 0.5, y: 0.5, text: 'x',
      })),
    }),
    /1-128 entries/,
  );
  assert.throws(
    () => normalizeCanvasAssetDocument({
      ...puzzle(),
      elements: [{type: 'rect', x: 0.9, y: 0.2, width: 0.2, height: 0.2}],
    }),
    /rectangle must remain inside canvas/,
  );
  assert.throws(
    () => normalizeCanvasAssetDocument({
      ...puzzle(),
      elements: [{type: 'circle', x: 0.03, y: 0.5, radius: 0.08}],
    }),
    /circle must remain inside canvas/,
  );
  assert.throws(
    () => normalizeCanvasAssetDocument({
      ...puzzle(),
      elements: [{type: 'label', x: 0.5, y: 0.5, text: 'x'.repeat(241)}],
    }),
    /1-240 printable characters/,
  );
});

test(
  'PostgreSQL canvas catalog is exact-retry safe, immutable, revocable and tamper-evident',
  {skip: !databaseUrl},
  async () => {
    await migrateUp();
    const pool = new Pool({connectionString: databaseUrl});
    const repo = new PostgresCanvasAssetRepository(pool);
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const assetId = `canvas_${suffix}`;
    const secondId = `canvas_revoke_${suffix}`;
    try {
      const first = await repo.register(puzzle(assetId));
      assert.equal(first.status, 'inserted');
      const retry = await repo.register({
        ...puzzle(assetId),
        elements: [
          {type: 'line', x1: 0.1, y1: 0.2, x2: 0.4, y2: 0.2, width: 0.012, cap: 'round', tone: 'foreground'},
          {type: 'rect', x: 0.5, y: 0.2, width: 0.2, height: 0.2, fill: true, strokeWidth: 0.008, radius: 0.02, tone: 'foreground'},
          {type: 'circle', x: 0.3, y: 0.7, radius: 0.08, strokeWidth: 0.008, fill: false, tone: 'accent'},
          {type: 'label', x: 0.7, y: 0.7, text: '8 − 4 = 4', scale: 0.08, tone: 'foreground'},
        ],
      });
      assert.equal(retry.status, 'duplicate');
      assert.equal(retry.asset.contentSha256, first.asset.contentSha256);
      await assert.rejects(
        repo.register({...puzzle(assetId), semanticLabel: 'Changed meaning'}),
        CanvasAssetIdentityConflictError,
      );
      assert.equal((await repo.resolveReady(assetId))?.id, assetId);

      await pool.query(
        `update canvas_assets
         set document = jsonb_set(document, '{semanticLabel}', '"tampered"'::jsonb)
         where id = $1`,
        [assetId],
      );
      await assert.rejects(repo.resolveReady(assetId), CanvasAssetIntegrityError);

      await repo.register(puzzle(secondId));
      assert.equal(await repo.revoke(secondId), true);
      assert.equal(await repo.resolveReady(secondId), null);
      await assert.rejects(repo.register(puzzle(secondId)), CanvasAssetIdentityConflictError);
    } finally {
      await pool.query('delete from canvas_assets where id = any($1::text[])', [
        [assetId, secondId],
      ]).catch(() => undefined);
      await pool.end();
    }
  },
);
