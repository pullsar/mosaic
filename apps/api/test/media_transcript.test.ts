import assert from 'node:assert/strict';
import {mkdtemp, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {planMediaNormalization} from '../src/media_normalization.js';
import {
  processClaimedTranscriptDerivative,
  transcriptPlanContract,
  TranscriptWorkerError,
  verifyWebVttOutput,
} from '../src/media_transcript.js';
import {
  MediaIdentityConflictError,
  type MediaDerivativeClaim,
  type MediaDerivativeOutput,
  type MediaDerivativeRecord,
} from '../src/media_repository.js';
import {MediaProcessError, type MediaProcessRunner} from '../src/media_process.js';

function captionPlan(languageTag = 'en-US') {
  const plan = planMediaNormalization({
    kind: 'audio' as const,
    durationMs: 4_000,
    audioCodec: 'pcm_s16le',
    sampleRateHz: 44_100,
    channels: 2,
    speech: 'material' as const,
    languageTag,
  }).find((value) => value.purpose === 'captions');
  assert.ok(plan);
  return plan;
}

function claim(languageTag = 'en-US'): MediaDerivativeClaim {
  const plan = captionPlan(languageTag);
  return {
    claimToken: 'transcript-claim',
    derivative: {
      assetId: 'asset_transcript',
      derivativeKey: 'mdv1_transcript',
      purpose: 'captions',
      state: 'processing',
      sourceSha256: 'a'.repeat(64),
      planVersion: plan.version,
      plan,
      attemptCount: 1,
      leaseExpiresAt: new Date(Date.now() + 30 * 60 * 1000),
      storageKey: null,
      mimeType: null,
      sizeBytes: null,
      width: null,
      height: null,
      durationMs: null,
      container: null,
      videoCodec: null,
      videoProfile: null,
      audioCodec: null,
      colorSpace: null,
      dynamicRange: null,
      errorCode: null,
      outputMetadata: {},
      completedAt: null,
    },
  };
}

class FakeTranscriptRepository {
  constructor(public current: MediaDerivativeRecord) {}

  readyCalls = 0;
  stale = false;

  async getDerivative(): Promise<MediaDerivativeRecord | null> {
    return this.current;
  }

  async markDerivativeReady(
    _assetId: string,
    _derivativeKey: string,
    token: string,
    output: MediaDerivativeOutput,
  ): Promise<MediaDerivativeRecord> {
    if (this.stale) throw new MediaIdentityConflictError('replaced');
    assert.equal(token, 'transcript-claim');
    this.readyCalls += 1;
    this.current = {
      ...this.current,
      state: 'ready',
      leaseExpiresAt: null,
      storageKey: output.storageKey,
      mimeType: output.mimeType,
      sizeBytes: output.sizeBytes,
      durationMs: output.durationMs ?? null,
      outputMetadata: output.metadata ?? {},
      errorCode: null,
      completedAt: new Date(),
    };
    return this.current;
  }
}

test('transcript plan contract preserves authored language while reducing whisper locale to primary subtag', () => {
  assert.deepEqual(transcriptPlanContract(captionPlan('en-US')), {
    durationMs: 4_000,
    language: 'en-US',
    whisperLanguage: 'en',
  });
  assert.deepEqual(transcriptPlanContract(captionPlan('auto')), {
    durationMs: 4_000,
    language: 'auto',
    whisperLanguage: 'auto',
  });
});

test('transcript plan contract rejects a non-caption processor', () => {
  const audio = planMediaNormalization({
    kind: 'audio' as const,
    durationMs: 1_000,
    audioCodec: 'aac',
    sampleRateHz: 48_000,
    channels: 1,
    speech: 'none' as const,
  })[0];
  assert.ok(audio);
  assert.throws(
    () => transcriptPlanContract(audio),
    (error: unknown) =>
      error instanceof TranscriptWorkerError &&
      error.errorCode === 'transcript_plan_invalid',
  );
});

test('WebVTT verifier accepts cue identifiers/settings and returns bounded metadata', async () => {
  const work = await mkdtemp(join(tmpdir(), 'mosaic-vtt-'));
  const output = join(work, 'captions.vtt');
  const text = [
    'WEBVTT',
    '',
    'cue-1',
    '00:00.000 --> 00:01.250 align:start position:0%',
    'Hello world.',
    '',
    '00:01.250 --> 00:03.900',
    'Second cue.',
    '',
  ].join('\n');
  await writeFile(output, text, 'utf8');

  const verified = await verifyWebVttOutput(output, 4_000, 'en-US');
  assert.equal(verified.mimeType, 'text/vtt');
  assert.equal(verified.durationMs, 4_000);
  assert.deepEqual(verified.metadata, {cueCount: 2, language: 'en-US'});
  assert.equal(verified.sizeBytes, Buffer.byteLength(text));
});

test('WebVTT verifier rejects unsafe structure, non-monotonic cues and duration escape', async () => {
  const work = await mkdtemp(join(tmpdir(), 'mosaic-vtt-invalid-'));
  const output = join(work, 'captions.vtt');

  await writeFile(output, 'NOTVTT\n\n00:00.000 --> 00:01.000\ntext\n');
  await assert.rejects(() => verifyWebVttOutput(output, 4_000, 'en'), /must begin with WEBVTT/);

  await writeFile(
    output,
    'WEBVTT\n\n00:02.000 --> 00:03.000\na\n\n00:01.000 --> 00:02.000\nb\n',
  );
  await assert.rejects(() => verifyWebVttOutput(output, 4_000, 'en'), /not monotonic/);

  await writeFile(output, 'WEBVTT\n\n00:00.000 --> 00:10.000\nlate\n');
  await assert.rejects(() => verifyWebVttOutput(output, 4_000, 'en'), /exceeds source duration/);

  await writeFile(output, 'WEBVTT\n\nNOTE hidden metadata\nnot a cue\n');
  await assert.rejects(() => verifyWebVttOutput(output, 4_000, 'en'), /only cues/);
});

test('claimed transcript processing prepares mono PCM, invokes whisper, verifies, publishes and completes exact claim', async () => {
  const claimed = claim();
  const repository = new FakeTranscriptRepository(claimed.derivative);
  const work = await mkdtemp(join(tmpdir(), 'mosaic-transcript-'));
  const source = join(work, 'source.m4a');
  await writeFile(source, Buffer.from('source'));
  const invocations: Array<{executable: string; args: readonly string[]}> = [];

  const runProcess: MediaProcessRunner = async (invocation) => {
    invocations.push(invocation);
    if (invocation.executable === '/usr/bin/ffmpeg') {
      assert.deepEqual(invocation.args.slice(-8), [
        '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', '-f', 'wav',
      ].slice(0, 8));
      const output = invocation.args.at(-1);
      assert.ok(output);
      await writeFile(output, Buffer.from('wav'));
    } else {
      assert.equal(invocation.executable, '/opt/whisper/whisper-cli');
      const outputIndex = invocation.args.indexOf('--output-file');
      assert.notEqual(outputIndex, -1);
      const outputBase = invocation.args[outputIndex + 1];
      assert.ok(outputBase);
      const languageIndex = invocation.args.indexOf('--language');
      assert.equal(invocation.args[languageIndex + 1], 'en');
      await writeFile(
        `${outputBase}.vtt`,
        'WEBVTT\n\n00:00.000 --> 00:03.500\nHello from Mosaic.\n',
        'utf8',
      );
    }
    return {durationMs: 1, stderrTail: ''};
  };

  let published = false;
  const result = await processClaimedTranscriptDerivative(
    repository,
    claimed,
    {inputPath: source, workDirectory: work},
    async (request) => {
      published = true;
      assert.equal(request.verifiedOutput.mimeType, 'text/vtt');
      assert.match(request.storageKey, /\.vtt$/);
      assert.equal(request.verifiedOutput.metadata?.language, 'en-US');
    },
    {
      ffmpegExecutable: '/usr/bin/ffmpeg',
      whisperExecutable: '/opt/whisper/whisper-cli',
      whisperModelPath: '/models/ggml-base.en.bin',
      prepareTimeoutMs: 10_000,
      whisperTimeoutMs: 20_000,
      runProcess,
    },
  );

  assert.equal(result.status, 'ready');
  assert.equal(repository.readyCalls, 1);
  assert.equal(published, true);
  assert.equal(invocations.length, 2);
});

test('transcript engine timeout maps to a stable failure code before publication', async () => {
  const claimed = claim();
  const repository = new FakeTranscriptRepository(claimed.derivative);
  const work = await mkdtemp(join(tmpdir(), 'mosaic-transcript-timeout-'));
  const source = join(work, 'source.wav');
  await writeFile(source, Buffer.from('source'));
  let call = 0;

  await assert.rejects(
    () => processClaimedTranscriptDerivative(
      repository,
      claimed,
      {inputPath: source, workDirectory: work},
      async () => assert.fail('publication must not run'),
      {
        whisperModelPath: '/models/model.bin',
        prepareTimeoutMs: 10_000,
        whisperTimeoutMs: 10_000,
        runProcess: async (invocation) => {
          call += 1;
          if (call === 1) {
            const output = invocation.args.at(-1);
            assert.ok(output);
            await writeFile(output, Buffer.from('wav'));
            return {durationMs: 1, stderrTail: ''};
          }
          throw new MediaProcessError('timeout', 'too slow');
        },
      },
    ),
    (error: unknown) =>
      error instanceof TranscriptWorkerError &&
      error.errorCode === 'transcript_engine_timeout',
  );
});

test('stale transcript completion never overwrites a replacement claim', async () => {
  const claimed = claim();
  const repository = new FakeTranscriptRepository(claimed.derivative);
  repository.stale = true;
  const work = await mkdtemp(join(tmpdir(), 'mosaic-transcript-stale-'));
  const source = join(work, 'source.wav');
  await writeFile(source, Buffer.from('source'));
  let call = 0;
  const result = await processClaimedTranscriptDerivative(
    repository,
    claimed,
    {inputPath: source, workDirectory: work},
    async () => undefined,
    {
      whisperModelPath: '/models/model.bin',
      prepareTimeoutMs: 10_000,
      whisperTimeoutMs: 10_000,
      runProcess: async (invocation) => {
        call += 1;
        if (call === 1) {
          const output = invocation.args.at(-1);
          assert.ok(output);
          await writeFile(output, Buffer.from('wav'));
        } else {
          const outputIndex = invocation.args.indexOf('--output-file');
          const outputBase = invocation.args[outputIndex + 1];
          assert.ok(outputBase);
          await writeFile(
            `${outputBase}.vtt`,
            'WEBVTT\n\n00:00.000 --> 00:01.000\ntext\n',
          );
        }
        return {durationMs: 1, stderrTail: ''};
      },
    },
  );
  assert.equal(result.status, 'stale');
});
