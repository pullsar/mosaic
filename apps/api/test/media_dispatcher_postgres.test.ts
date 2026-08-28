import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {
  FFMPEG_MEDIA_PROCESSORS,
  PostgresMediaDispatcher,
} from '../src/media_dispatcher.js';
import {PostgresMediaRepository} from '../src/media_repository.js';
import {planMediaNormalization} from '../src/media_normalization.js';
import {TRANSCRIPT_MEDIA_PROCESSOR} from '../src/media_transcript.js';
import {PostgresRepository} from '../src/repository.js';

const databaseUrl = process.env.DATABASE_URL;

async function runMigration(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', 'src/db/migrate.ts', 'up'], {
      cwd: new URL('../', import.meta.url),
      env: process.env,
      stdio: 'inherit',
    });
    child.on('exit', (code) =>
      code === 0 ? resolve() : reject(new Error(`migration up exited ${code}`)),
    );
    child.on('error', reject);
  });
}

function videoPlans() {
  return planMediaNormalization({
    kind: 'video' as const,
    width: 1920,
    height: 1080,
    durationMs: 5_000,
    videoCodec: 'hevc',
    videoProfile: 'Main 10',
    dynamicRange: 'hdr' as const,
    colorPrimaries: 'bt2020',
    colorTransfer: 'smpte2084',
    colorMatrix: 'bt2020nc',
    colorRange: 'limited' as const,
    variableFrameRate: true,
    nominalFrameRate: 59.94,
    rotationDegrees: 0 as const,
    hasAudio: true,
    audioCodec: 'aac',
    audioSampleRateHz: 44_100,
    audioChannels: 2,
    speech: 'none' as const,
  });
}

function audioPlans() {
  return planMediaNormalization({
    kind: 'audio' as const,
    durationMs: 4_000,
    audioCodec: 'pcm_s24le',
    sampleRateHz: 96_000,
    channels: 6,
    speech: 'material' as const,
    languageTag: 'en',
  });
}

test(
  'PostgreSQL dispatcher atomically distributes supported media work across workers',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const identityRepo = new PostgresRepository(pool);
    const mediaRepo = new PostgresMediaRepository(pool);
    const dispatcherA = new PostgresMediaDispatcher(pool, mediaRepo);
    const dispatcherB = new PostgresMediaDispatcher(pool, mediaRepo);
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_dispatch_${suffix}`;

    try {
      await identityRepo.createActor(actorId);

      const videoAssetIds = [`video_a_${suffix}`, `video_b_${suffix}`];
      for (const [index, assetId] of videoAssetIds.entries()) {
        await mediaRepo.createAsset(assetId, actorId, 'video');
        await mediaRepo.attachSource(assetId, {
          storageKey: `quarantine/${assetId}/source.mov`,
          sourceSha256: String(index + 1).repeat(64),
          mimeType: 'video/quicktime',
          sizeBytes: 10_000 + index,
          width: 1920,
          height: 1080,
          durationMs: 5_000,
          metadata: {verified: true},
        });
        for (const plan of videoPlans()) {
          await mediaRepo.registerDerivative(assetId, plan);
        }
      }

      const audioAssetId = `audio_${suffix}`;
      await mediaRepo.createAsset(audioAssetId, actorId, 'audio');
      await mediaRepo.attachSource(audioAssetId, {
        storageKey: `quarantine/${audioAssetId}/source.wav`,
        sourceSha256: 'c'.repeat(64),
        mimeType: 'audio/wav',
        sizeBytes: 20_000,
        durationMs: 4_000,
        metadata: {verified: true},
      });
      const audioRegistered = [];
      for (const plan of audioPlans()) {
        audioRegistered.push((await mediaRepo.registerDerivative(audioAssetId, plan)).derivative);
      }

      const [first, second] = await Promise.all([
        dispatcherA.claimNext(FFMPEG_MEDIA_PROCESSORS, 60_000, `claim_a_${suffix}`),
        dispatcherB.claimNext(FFMPEG_MEDIA_PROCESSORS, 60_000, `claim_b_${suffix}`),
      ]);
      assert.ok(first);
      assert.ok(second);
      assert.notDeepEqual(
        [first.derivative.assetId, first.derivative.derivativeKey],
        [second.derivative.assetId, second.derivative.derivativeKey],
      );
      assert.equal(first.derivative.purpose, 'playback');
      assert.equal(second.derivative.purpose, 'playback');

      const claims = [first, second];
      for (let index = 0; index < 3; index += 1) {
        const claim = await dispatcherA.claimNext(
          FFMPEG_MEDIA_PROCESSORS,
          60_000,
          `claim_more_${index}_${suffix}`,
        );
        assert.ok(claim);
        claims.push(claim);
      }
      assert.deepEqual(
        claims.map((claim) => claim.derivative.purpose).sort(),
        ['audio', 'playback', 'playback', 'poster', 'poster'],
      );
      assert.equal(
        await dispatcherA.claimNext(
          FFMPEG_MEDIA_PROCESSORS,
          60_000,
          `claim_none_${suffix}`,
        ),
        null,
      );

      const caption = audioRegistered.find((derivative) => derivative.purpose === 'captions');
      assert.ok(caption);
      assert.equal(
        (await mediaRepo.getDerivative(audioAssetId, caption.derivativeKey))?.state,
        'pending',
      );

      const reclaimTarget = claims[0]!;
      await pool.query(
        `update media_derivatives
         set lease_expires_at = now() - interval '1 second'
         where asset_id = $1 and derivative_key = $2`,
        [reclaimTarget.derivative.assetId, reclaimTarget.derivative.derivativeKey],
      );
      const reclaimed = await dispatcherB.claimNext(
        FFMPEG_MEDIA_PROCESSORS,
        60_000,
        `claim_replacement_${suffix}`,
      );
      assert.ok(reclaimed);
      assert.equal(reclaimed.derivative.assetId, reclaimTarget.derivative.assetId);
      assert.equal(reclaimed.derivative.derivativeKey, reclaimTarget.derivative.derivativeKey);
      assert.equal(reclaimed.derivative.attemptCount, 2);
    } finally {
      await pool.end();
    }
  },
);

test(
  'PostgreSQL dispatcher excludes revoked and source-stale work and validates processor/lease input',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const identityRepo = new PostgresRepository(pool);
    const mediaRepo = new PostgresMediaRepository(pool);
    const dispatcher = new PostgresMediaDispatcher(pool, mediaRepo);
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_dispatch_guard_${suffix}`;

    try {
      await identityRepo.createActor(actorId);

      const revokedAsset = `revoked_${suffix}`;
      await mediaRepo.createAsset(revokedAsset, actorId, 'video');
      await mediaRepo.attachSource(revokedAsset, {
        storageKey: `quarantine/${revokedAsset}/source.mov`,
        sourceSha256: 'd'.repeat(64),
        mimeType: 'video/quicktime',
        sizeBytes: 100,
        width: 1920,
        height: 1080,
        durationMs: 5_000,
      });
      await mediaRepo.registerDerivative(revokedAsset, videoPlans()[0]!);
      await mediaRepo.revokeAsset(revokedAsset);

      const staleAsset = `stale_${suffix}`;
      await mediaRepo.createAsset(staleAsset, actorId, 'video');
      await mediaRepo.attachSource(staleAsset, {
        storageKey: `quarantine/${staleAsset}/source.mov`,
        sourceSha256: 'e'.repeat(64),
        mimeType: 'video/quicktime',
        sizeBytes: 100,
        width: 1920,
        height: 1080,
        durationMs: 5_000,
      });
      await mediaRepo.registerDerivative(staleAsset, videoPlans()[0]!);
      await pool.query(
        `update media_assets set source_sha256 = $2 where id = $1`,
        [staleAsset, 'f'.repeat(64)],
      );

      assert.equal(
        await dispatcher.claimNext(FFMPEG_MEDIA_PROCESSORS, 60_000, `none_${suffix}`),
        null,
      );
      await assert.rejects(
        dispatcher.claimNext([], 60_000, `bad_processors_${suffix}`),
        /processors must contain between/,
      );
      await assert.rejects(
        dispatcher.claimNext(FFMPEG_MEDIA_PROCESSORS, 0, `bad_lease_${suffix}`),
        /leaseMs must be/,
      );
    } finally {
      await pool.end();
    }
  },
);

test(
  'PostgreSQL transcript dispatch atomically distributes caption work and remains isolated from FFmpeg workers',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const identityRepo = new PostgresRepository(pool);
    const mediaRepo = new PostgresMediaRepository(pool);
    const dispatcherA = new PostgresMediaDispatcher(pool, mediaRepo);
    const dispatcherB = new PostgresMediaDispatcher(pool, mediaRepo);
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_transcript_dispatch_${suffix}`;

    try {
      await identityRepo.createActor(actorId);
      const captionPlans = audioPlans().filter(
        (plan) => plan.processor === TRANSCRIPT_MEDIA_PROCESSOR,
      );
      assert.equal(captionPlans.length, 1);

      const expected = new Map<string, string>();
      for (let index = 0; index < 2; index += 1) {
        const assetId = `transcript_${index}_${suffix}`;
        await mediaRepo.createAsset(assetId, actorId, 'audio');
        await mediaRepo.attachSource(assetId, {
          storageKey: `quarantine/${assetId}/source.wav`,
          sourceSha256: String(index + 7).repeat(64),
          mimeType: 'audio/wav',
          sizeBytes: 20_000 + index,
          durationMs: 4_000,
          metadata: {verified: true},
        });
        const registered = await mediaRepo.registerDerivative(assetId, captionPlans[0]!);
        expected.set(assetId, registered.derivative.derivativeKey);
      }

      // The suite shares one PostgreSQL database, so an FFmpeg claim may consume
      // unrelated work left by another test. The invariant is that it cannot
      // mutate either caption created above.
      await dispatcherA.claimNext(
        FFMPEG_MEDIA_PROCESSORS,
        60_000,
        `ffmpeg_probe_${suffix}`,
      );
      for (const [assetId, derivativeKey] of expected) {
        assert.equal(
          (await mediaRepo.getDerivative(assetId, derivativeKey))?.state,
          'pending',
        );
      }

      const [first, second] = await Promise.all([
        dispatcherA.claimNext(
          [TRANSCRIPT_MEDIA_PROCESSOR],
          60_000,
          `transcript_claim_a_${suffix}`,
        ),
        dispatcherB.claimNext(
          [TRANSCRIPT_MEDIA_PROCESSOR],
          60_000,
          `transcript_claim_b_${suffix}`,
        ),
      ]);
      assert.ok(first);
      assert.ok(second);
      assert.notDeepEqual(
        [first.derivative.assetId, first.derivative.derivativeKey],
        [second.derivative.assetId, second.derivative.derivativeKey],
      );
      for (const claim of [first, second]) {
        assert.equal(claim.derivative.purpose, 'captions');
        assert.equal(claim.derivative.plan.processor, TRANSCRIPT_MEDIA_PROCESSOR);
        assert.equal(claim.derivative.state, 'processing');
      }

      const observed = new Set<string>();
      const recordExpected = (claim: typeof first): void => {
        if (!expected.has(claim.derivative.assetId)) return;
        assert.equal(
          claim.derivative.derivativeKey,
          expected.get(claim.derivative.assetId),
        );
        observed.add(claim.derivative.assetId);
      };
      recordExpected(first);
      recordExpected(second);

      const eligible = await pool.query<{count: string}>(
        `select count(*)::text as count
         from media_derivatives d
         join media_assets a on a.id = d.asset_id
         where a.state <> 'revoked'
           and a.source_sha256 = d.source_sha256
           and d.plan->>'processor' = $1
           and (
             d.state in ('pending', 'failed')
             or (d.state = 'processing' and d.lease_expires_at <= now())
           )`,
        [TRANSCRIPT_MEDIA_PROCESSOR],
      );
      const remainingEligible = Number(eligible.rows[0]?.count ?? '0');
      assert.ok(Number.isSafeInteger(remainingEligible) && remainingEligible >= 0);

      for (
        let index = 0;
        index < remainingEligible && observed.size < expected.size;
        index += 1
      ) {
        const claim = await dispatcherA.claimNext(
          [TRANSCRIPT_MEDIA_PROCESSOR],
          60_000,
          `transcript_drain_${index}_${suffix}`,
        );
        assert.ok(claim);
        assert.equal(claim.derivative.purpose, 'captions');
        assert.equal(claim.derivative.plan.processor, TRANSCRIPT_MEDIA_PROCESSOR);
        recordExpected(claim);
      }

      assert.deepEqual(
        [...observed].sort(),
        [...expected.keys()].sort(),
      );
    } finally {
      await pool.end();
    }
  },
);
