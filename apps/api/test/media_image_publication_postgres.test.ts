import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {mediaAttemptStorageKey} from '../src/media_ffmpeg_worker.js';
import {planImageNormalization} from '../src/media_image_normalization.js';
import {
  MediaPublicationBlockedError,
  PostgresMediaPublicationGate,
} from '../src/media_publication.js';
import {PostgresMediaRepository} from '../src/media_repository.js';
import {PostgresRepository} from '../src/repository.js';

const databaseUrl = process.env.DATABASE_URL;

async function runMigration(): Promise<void> {
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

function blockedReason(error: unknown): string | undefined {
  return error instanceof MediaPublicationBlockedError ? error.reason : undefined;
}

test(
  'PostgreSQL publication promotes only current compatible managed image output',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const identityRepo = new PostgresRepository(pool);
    const mediaRepo = new PostgresMediaRepository(pool);
    const gate = new PostgresMediaPublicationGate(pool);
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_image_publication_${suffix}`;
    const assetId = `asset_image_publication_${suffix}`;
    const sourceSha256 = 'e'.repeat(64);

    try {
      await identityRepo.createActor(actorId);
      await mediaRepo.createAsset(assetId, actorId, 'image');
      await mediaRepo.attachSource(assetId, {
        storageKey: `quarantine/${assetId}/source.heic`,
        sourceSha256,
        mimeType: 'image/heic',
        sizeBytes: 4_000_000,
        width: 2400,
        height: 1600,
        metadata: {
          rotationDegrees: 0,
          dynamicRange: 'sdr',
          hasAlpha: false,
        },
      });

      await assert.rejects(
        gate.promoteReady(assetId),
        (error) => blockedReason(error) === 'image_not_ready',
      );

      const plan = planImageNormalization({
        kind: 'image',
        width: 2400,
        height: 1600,
        rotationDegrees: 0,
        dynamicRange: 'sdr',
        hasAlpha: false,
      });
      const derivative = (await mediaRepo.registerDerivative(assetId, plan)).derivative;
      const claim = await mediaRepo.claimDerivative(
        assetId,
        derivative.derivativeKey,
        60_000,
        `claim_image_${suffix}`,
      );
      assert.ok(claim);
      await mediaRepo.markDerivativeReady(
        assetId,
        derivative.derivativeKey,
        claim.claimToken,
        {
          storageKey: mediaAttemptStorageKey(
            assetId,
            derivative.derivativeKey,
            claim.claimToken,
            'image',
          ),
          mimeType: 'image/jpeg',
          sizeBytes: 180_000,
          width: 1280,
          height: 854,
          dynamicRange: 'sdr',
        },
      );

      const promoted = await gate.promoteReady(assetId);
      assert.equal(promoted.kind, 'image');
      assert.equal(promoted.primary.purpose, 'image');
      assert.equal(promoted.primary.mimeType, 'image/jpeg');
      assert.equal(promoted.poster, null);
      assert.equal(promoted.captions, null);
      assert.equal((await mediaRepo.getAsset(assetId))?.state, 'ready');

      await pool.query(
        `update media_derivatives
         set mime_type = 'image/png'
         where asset_id = $1 and derivative_key = $2`,
        [assetId, derivative.derivativeKey],
      );
      await assert.rejects(
        gate.resolveReady(assetId),
        (error) => blockedReason(error) === 'image_incompatible',
      );

      await pool.query(
        `update media_assets set state = 'revoked', updated_at = now()
         where id = $1`,
        [assetId],
      );
      await assert.rejects(
        gate.resolveReady(assetId),
        (error) => blockedReason(error) === 'asset_revoked',
      );
    } finally {
      await pool.end();
    }
  },
);
