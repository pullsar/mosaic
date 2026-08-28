import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createTranscriptProcessRunner} from '../src/media_transcript_process.js';
import type {MediaProcessInvocation, MediaProcessRunner} from '../src/media_process.js';

test('transcript process runner injects bounded whisper threads without touching FFmpeg', async () => {
  const calls: MediaProcessInvocation[] = [];
  const base: MediaProcessRunner = async (invocation) => {
    calls.push(invocation);
    return {durationMs: 1, stderrTail: ''};
  };
  const runner = createTranscriptProcessRunner({
    whisperExecutable: '/opt/whisper/whisper-cli',
    whisperThreads: 8,
    runProcess: base,
  });

  await runner(
    {executable: '/usr/bin/ffmpeg', args: ['-i', 'source.wav', 'out.wav']},
    {timeoutMs: 1_000},
  );
  await runner(
    {
      executable: '/opt/whisper/whisper-cli',
      args: ['--model', '/models/model.bin', '--file', 'out.wav'],
    },
    {timeoutMs: 1_000},
  );

  assert.deepEqual(calls[0], {
    executable: '/usr/bin/ffmpeg',
    args: ['-i', 'source.wav', 'out.wav'],
  });
  assert.deepEqual(calls[1], {
    executable: '/opt/whisper/whisper-cli',
    args: [
      '--model',
      '/models/model.bin',
      '--file',
      'out.wav',
      '--threads',
      '8',
    ],
  });
});

test('transcript process runner rejects duplicate or unsafe thread configuration', async () => {
  assert.throws(
    () => createTranscriptProcessRunner({
      whisperExecutable: 'whisper-cli',
      whisperThreads: 65,
    }),
    /whisperThreads/,
  );

  const runner = createTranscriptProcessRunner({
    whisperExecutable: 'whisper-cli',
    whisperThreads: 4,
    runProcess: async () => ({durationMs: 1, stderrTail: ''}),
  });
  await assert.rejects(
    runner(
      {executable: 'whisper-cli', args: ['--threads', '2']},
      {timeoutMs: 1_000},
    ),
    /already contains a thread override/,
  );
});
