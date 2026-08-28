import assert from 'node:assert/strict';
import {test} from 'node:test';
import {MediaProcessError, runMediaProcess} from '../src/media_process.js';

test('process runner captures stdout only when explicitly requested', async () => {
  const captured = await runMediaProcess(
    {executable: process.execPath, args: ['-e', 'process.stdout.write("probe-json")']},
    {timeoutMs: 2_000, captureStdout: true, maxStdoutChars: 64},
  );
  assert.equal(captured.stdoutText, 'probe-json');

  const ignored = await runMediaProcess(
    {executable: process.execPath, args: ['-e', 'process.stdout.write("ignored")']},
    {timeoutMs: 2_000},
  );
  assert.equal(ignored.stdoutText, undefined);
});

test('process runner terminates a child whose captured stdout exceeds the configured bound', async () => {
  await assert.rejects(
    runMediaProcess(
      {
        executable: process.execPath,
        args: ['-e', 'process.stdout.write("x".repeat(2000)); setInterval(() => {}, 1000)'],
      },
      {timeoutMs: 2_000, captureStdout: true, maxStdoutChars: 32, killGraceMs: 50},
    ),
    (error: unknown) => {
      assert.ok(error instanceof MediaProcessError);
      assert.equal(error.kind, 'output_limit');
      return true;
    },
  );
});
