import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {test} from 'node:test';
import {Pool} from 'pg';
import {
  MediaPublicationBlockedError,
  PostgresMediaPublicationGate,
} from '../src/media_publication.js';
import {planMediaNormalization} from '../src/media_normalization.js';
import {PostgresMediaRepository} from '../src/media_repository.js';
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

function blockedReason(error: unknown): string | undefined {
  return error instanceof MediaPublicationBlockedError ? error.reason : undefined;
}

test(
  'PostgreSQL publication gate never promotes HEVC/HDR source-only video and revalidates delivery metadata',
  {skip: !databaseUrl},
  async () => {
    await runMigration();
    const pool = new Pool({connectionString: databaseUrl});
    const identityRepo = new PostgresRepository(pool);
    const mediaRepo = new PostgresMediaRepository(pool);
    const gate = new PostgresMediaPublicationGate(pool);
    const suffix = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    const actorId = `actor_publication_${suffix}`;
    const sourceOnlyId = `asset_source_only_${suffix}`;
    const assetId = `asset_publishable_${suffix}`;
    const sourceSha256 = 'c'.repeat(64);
    const source = {
      storageKey: `quarantine/${assetId}/source.mov`,
      sourceSha256,
      mimeType: 'video/quicktime',
      sizeBytes: 8_000_000,
      width: 1920,
      height: 1080,
      durationMs: 5_000,
      metadata: {
        videoCodec: 'hevc',
        videoProfile: 'Main 10',
        dynamicRange: 'hdr',
        colorTransfer: 'smpte2084',
      },
    } as const;

    try {
      await identityRepo.createActor(actorId);

      await mediaRepo.createAsset(sourceOnlyId, actorId, 'video');
      await mediaRepo.attachSource(sourceOnlyId, {
        ...source,
        storageKey: `quarantine/${sourceOnlyId}/source.mov`,
      });
      await assert.rejects(
        gate.promoteReady(sourceOnlyId),
        (error) => blockedReason(error) === 'playback_not_ready',
      );
      assert.equal((await mediaRepo.getAsset(sourceOnlyId))?.state, 'uploaded');

      await mediaRepo.createAsset(assetId, actorId, 'video');
      await mediaRepo.attachSource(assetId, source);
      const plans = videoPlans();
      const playbackPlan = plans.find((plan) => plan.purpose === 'playback');
      const posterPlan = plans.find((plan) => plan.purpose === 'poster');
      assert.ok(playbackPlan);
      assert.ok(posterPlan);

      const playback = (await mediaRepo.registerDerivative(assetId, playbackPlan)).derivative;
      const poster = (await mediaRepo.registerDerivative(assetId, posterPlan)).derivative;
      const playbackClaim = await mediaRepo.claimDerivative(
        assetId,
        playback.derivativeKey,
        60_000,
        `claim_playback_${suffix}`,
      );
      const posterClaim = await mediaRepo.claimDerivative(
        assetId,
        poster.derivativeKey,
        60_000,
        `claim_poster_${suffix}`,
      );
      assert.ok(playbackClaim);
      assert.ok(posterClaim);

      await mediaRepo.markDerivativeReady(
        assetId,
        playback.derivativeKey,
        playbackClaim.claimToken,
        {
          storageKey: `media/${assetId}/attempts/${playbackClaim.claimToken}.mp4`,
          mimeType: 'video/mp4',
          sizeBytes: 2_000_000,
          width: 1280,
          height: 720,
          durationMs: 5_000,
          container: 'mp4',
          videoCodec: 'h264',
          videoProfile: 'main',
          audioCodec: 'aac',
          colorSpace: 'bt709',
          dynamicRange: 'sdr',
        },
      );
      await mediaRepo.markDerivativeReady(
        assetId,
        poster.derivativeKey,
        posterClaim.claimToken,
        {
          storageKey: `media/${assetId}/attempts/${posterClaim.claimToken}.jpg`,
          mimeType: 'image/jpeg',
          sizeBytes: 120_000,
          width: 1280,
          height: 720,
          dynamicRange: 'sdr',
        },
      );

      const promoted = await gate.promoteReady(assetId);
      assert.equal(promoted.primary.videoCodec, 'h264');
      assert.equal(promoted.primary.dynamicRange, 'sdr');
      assert.equal(promoted.poster?.mimeType, 'image/jpeg');
      assert.equal((await mediaRepo.getAsset(assetId))?.state, 'ready');
      assert.equal((await gate.resolveReady(assetId)).primary.derivativeKey, playback.derivativeKey);

      await pool.query(
        `update media_derivatives
         set video_codec = 'hevc', video_profile = 'main10',
             color_space = 'bt2020nc', dynamic_range = 'hdr'
         where asset_id = $1 and derivative_key = $2`,
        [assetId, playback.derivativeKey],
      );
      await assert.rejects(
        gate.resolveReady(assetId),
        (error) => blockedReason(error) === 'playback_incompatible',
      );
    } finally {
      await pool.end();
    }
  },
);
