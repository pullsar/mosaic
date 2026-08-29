import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {MediaIdentityConflictError, PostgresMediaRepository} from '../src/media_repository.js';
import {PostgresRepository} from '../src/repository.js';

const databaseUrl = process.env.DATABASE_URL;

async function runMigration(command: 'up' | 'down' = 'up'): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', 'src/db/migrate.ts', command], {
      cwd: new URL('../', import.meta.url),
      env: process.env,
      stdio: 'inherit',
    });
    child.on('exit', (code) =>
      code === 0 ? resolve() : reject(new Error(`migration ${command} exited ${code}`)),
    );
    child.on('error', reject);
  });
}

test('PostgreSQL foundation preserves identity and event idempotency', {skip: !databaseUrl}, async () => {
  await runMigration();
  const pool = new Pool({connectionString: databaseUrl});
  const repo = new PostgresRepository(pool);
  const suffix = Date.now().toString(36);
  const actorId = `actor_${suffix}`;
  const userId = `user_${suffix}`;
  const eventId = `evt_${suffix}`;

  try {
    await repo.createActor(actorId);
    await repo.bindActorToUser(actorId, userId);
    const merge = await pool.query<{user_id: string}>(
      'select user_id from actor_user_merges where actor_id = $1',
      [actorId],
    );
    assert.equal(merge.rows[0]?.user_id, userId);

    const event = {
      eventId,
      event: 'play_started',
      version: 1,
      occurredAt: new Date().toISOString(),
      actorId,
      sessionId: `session_${suffix}`,
      payload: {},
    };
    assert.equal(await repo.insertEvent(event), 'inserted');
    assert.equal(await repo.insertEvent(event), 'duplicate');

    const received = await pool.query<{received_at: Date}>(
      'select received_at from interaction_events where event_id = $1',
      [eventId],
    );
    assert.ok(received.rows[0]?.received_at instanceof Date);
  } finally {
    await pool.end();
  }
});

test('PostgreSQL media lifecycle is immutable, leased and stale-worker safe', {skip: !databaseUrl}, async () => {
  await runMigration();
  const pool = new Pool({connectionString: databaseUrl});
  const identityRepo = new PostgresRepository(pool);
  const mediaRepo = new PostgresMediaRepository(pool);
  const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  const actorId = `actor_media_${suffix}`;
  const assetId = `asset_${suffix}`;
  const sourceSha256 = 'a'.repeat(64);
  const source = {
    storageKey: `quarantine/${assetId}/source.mov`,
    sourceSha256,
    mimeType: 'video/quicktime',
    sizeBytes: 12_345_678,
    width: 1920,
    height: 1080,
    durationMs: 7_000,
    metadata: {videoCodec: 'hevc', dynamicRange: 'hdr', variableFrameRate: true},
  } as const;
  const playbackPlan = {
    version: 1,
    purpose: 'playback',
    processor: 'ffmpeg-normalize-v1',
    parameters: {
      container: 'mp4',
      videoCodec: 'h264',
      audioCodec: 'aac',
      dynamicRange: 'sdr',
      maxFps: 30,
    },
  } as const;
  const playbackOutput = {
    storageKey: `public/${assetId}/playback.mp4`,
    mimeType: 'video/mp4',
    sizeBytes: 2_500_000,
    width: 1280,
    height: 720,
    durationMs: 7_000,
    container: 'mp4',
    videoCodec: 'h264',
    videoProfile: 'main',
    audioCodec: 'aac',
    colorSpace: 'bt709',
    dynamicRange: 'sdr',
    metadata: {frameRate: 30},
  } as const;

  try {
    await identityRepo.createActor(actorId);
    assert.equal(await mediaRepo.createAsset(assetId, actorId, 'video'), 'inserted');
    assert.equal(await mediaRepo.createAsset(assetId, actorId, 'video'), 'duplicate');

    const attached = await mediaRepo.attachSource(assetId, source);
    assert.equal(attached.state, 'uploaded');
    assert.equal(attached.sourceStorageKey, source.storageKey);
    assert.equal((await mediaRepo.attachSource(assetId, source)).sourceSha256, sourceSha256);
    await assert.rejects(
      mediaRepo.attachSource(assetId, {...source, storageKey: `other/${assetId}.mov`}),
      MediaIdentityConflictError,
    );

    const registered = await mediaRepo.registerDerivative(assetId, playbackPlan);
    assert.equal(registered.status, 'inserted');
    assert.equal((await mediaRepo.registerDerivative(assetId, playbackPlan)).status, 'duplicate');

    const firstClaim = await mediaRepo.claimDerivative(
      assetId,
      registered.derivative.derivativeKey,
      60_000,
      `claim_a_${suffix}`,
    );
    assert.ok(firstClaim);
    assert.equal(firstClaim.derivative.attemptCount, 1);
    assert.equal(
      await mediaRepo.claimDerivative(
        assetId,
        registered.derivative.derivativeKey,
        60_000,
        `claim_b_${suffix}`,
      ),
      null,
    );
    await assert.rejects(
      mediaRepo.markDerivativeReady(
        assetId,
        registered.derivative.derivativeKey,
        `wrong_${suffix}`,
        playbackOutput,
      ),
      MediaIdentityConflictError,
    );

    const ready = await mediaRepo.markDerivativeReady(
      assetId,
      registered.derivative.derivativeKey,
      firstClaim.claimToken,
      playbackOutput,
    );
    assert.equal(ready.state, 'ready');
    assert.equal(ready.videoCodec, 'h264');
    assert.equal(
      (
        await mediaRepo.markDerivativeReady(
          assetId,
          registered.derivative.derivativeKey,
          firstClaim.claimToken,
          playbackOutput,
        )
      ).state,
      'ready',
    );
    await assert.rejects(
      mediaRepo.markDerivativeFailed(
        assetId,
        registered.derivative.derivativeKey,
        firstClaim.claimToken,
        'late_failure',
      ),
      MediaIdentityConflictError,
    );

    const retryPlan = {
      ...playbackPlan,
      parameters: {...playbackPlan.parameters, maxFps: 24},
    } as const;
    const retryDerivative = (await mediaRepo.registerDerivative(assetId, retryPlan)).derivative;
    const staleClaim = await mediaRepo.claimDerivative(
      assetId,
      retryDerivative.derivativeKey,
      60_000,
      `stale_${suffix}`,
    );
    assert.ok(staleClaim);
    await pool.query(
      `update media_derivatives
       set lease_expires_at = now() - interval '1 second'
       where asset_id = $1 and derivative_key = $2`,
      [assetId, retryDerivative.derivativeKey],
    );
    const replacementClaim = await mediaRepo.claimDerivative(
      assetId,
      retryDerivative.derivativeKey,
      60_000,
      `replacement_${suffix}`,
    );
    assert.ok(replacementClaim);
    assert.equal(replacementClaim.derivative.attemptCount, 2);
    await assert.rejects(
      mediaRepo.markDerivativeReady(
        assetId,
        retryDerivative.derivativeKey,
        staleClaim.claimToken,
        playbackOutput,
      ),
      MediaIdentityConflictError,
    );
    assert.equal(
      (
        await mediaRepo.markDerivativeFailed(
          assetId,
          retryDerivative.derivativeKey,
          replacementClaim.claimToken,
          'transcode_failed',
        )
      ).state,
      'failed',
    );

    const finalClaim = await mediaRepo.claimDerivative(
      assetId,
      retryDerivative.derivativeKey,
      60_000,
      `final_${suffix}`,
    );
    assert.ok(finalClaim);
    assert.equal(await mediaRepo.revokeAsset(assetId), true);
    assert.equal((await mediaRepo.getAsset(assetId))?.state, 'revoked');
    assert.equal(
      (await mediaRepo.getDerivative(assetId, retryDerivative.derivativeKey))?.state,
      'revoked',
    );
    await assert.rejects(
      mediaRepo.markDerivativeReady(
        assetId,
        retryDerivative.derivativeKey,
        finalClaim.claimToken,
        playbackOutput,
      ),
      MediaIdentityConflictError,
    );
    await assert.rejects(
      mediaRepo.registerDerivative(assetId, playbackPlan),
      MediaIdentityConflictError,
    );
  } finally {
    await pool.end();
  }
});

test('actor access, consumer and media migrations roll back in order and cleanly reapply', {skip: !databaseUrl}, async () => {
  await runMigration('up');

  await runMigration('down');
  const imagePurposeDownPool = new Pool({connectionString: databaseUrl});
  try {
    const afterImagePurposeDown = await imagePurposeDownPool.query<{
      actor_access_credentials: string | null;
      purpose_check: string | null;
    }>(
      `select to_regclass('public.actor_access_credentials')::text as actor_access_credentials,
              (
                select pg_get_constraintdef(oid)
                from pg_constraint
                where conname = 'media_derivatives_purpose_check'
              ) as purpose_check`,
    );
    assert.equal(
      afterImagePurposeDown.rows[0]?.actor_access_credentials,
      'actor_access_credentials',
    );
    const purposeCheck = afterImagePurposeDown.rows[0]?.purpose_check;
    assert.ok(purposeCheck);
    assert.equal(purposeCheck.includes("'image'"), false);
    assert.equal(purposeCheck.includes("'playback'"), true);
  } finally {
    await imagePurposeDownPool.end();
  }

  await runMigration('down');
  const actorAccessDownPool = new Pool({connectionString: databaseUrl});
  try {
    const afterActorAccessDown = await actorAccessDownPool.query<{
      actor_access_credentials: string | null;
      feed_decisions: string | null;
      media_assets: string | null;
      actors: string | null;
    }>(
      `select to_regclass('public.actor_access_credentials')::text as actor_access_credentials,
              to_regclass('public.feed_decisions')::text as feed_decisions,
              to_regclass('public.media_assets')::text as media_assets,
              to_regclass('public.actors')::text as actors`,
    );
    assert.equal(afterActorAccessDown.rows[0]?.actor_access_credentials, null);
    assert.equal(afterActorAccessDown.rows[0]?.feed_decisions, 'feed_decisions');
    assert.equal(afterActorAccessDown.rows[0]?.media_assets, 'media_assets');
    assert.equal(afterActorAccessDown.rows[0]?.actors, 'actors');
  } finally {
    await actorAccessDownPool.end();
  }

  await runMigration('down');
  const consumerDownPool = new Pool({connectionString: databaseUrl});
  try {
    const afterConsumerDown = await consumerDownPool.query<{
      feed_decisions: string | null;
      media_assets: string | null;
      media_derivatives: string | null;
      actors: string | null;
    }>(
      `select to_regclass('public.feed_decisions')::text as feed_decisions,
              to_regclass('public.media_assets')::text as media_assets,
              to_regclass('public.media_derivatives')::text as media_derivatives,
              to_regclass('public.actors')::text as actors`,
    );
    assert.equal(afterConsumerDown.rows[0]?.feed_decisions, null);
    assert.equal(afterConsumerDown.rows[0]?.media_assets, 'media_assets');
    assert.equal(afterConsumerDown.rows[0]?.media_derivatives, 'media_derivatives');
    assert.equal(afterConsumerDown.rows[0]?.actors, 'actors');
  } finally {
    await consumerDownPool.end();
  }

  await runMigration('down');
  const mediaDownPool = new Pool({connectionString: databaseUrl});
  try {
    const afterMediaDown = await mediaDownPool.query<{
      media_assets: string | null;
      media_derivatives: string | null;
      actors: string | null;
    }>(
      `select to_regclass('public.media_assets')::text as media_assets,
              to_regclass('public.media_derivatives')::text as media_derivatives,
              to_regclass('public.actors')::text as actors`,
    );
    assert.equal(afterMediaDown.rows[0]?.media_assets, null);
    assert.equal(afterMediaDown.rows[0]?.media_derivatives, null);
    assert.equal(afterMediaDown.rows[0]?.actors, 'actors');
  } finally {
    await mediaDownPool.end();
    await runMigration('up');
  }
});
