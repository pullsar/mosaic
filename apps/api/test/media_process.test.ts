import assert from 'node:assert/strict';
import {test} from 'node:test';
import {MediaProcessError, runMediaProcess} from '../src/media_process.js';

test('process runner preserves shell metacharacters as literal arguments', async () => {
  const literal = 'a;echo definitely-not-a-shell';
  const result = await runMediaProcess(
    {
      executable: process.execPath,
      args: [
        '-e',
        'process.exit(process.argv[1] === "a;echo definitely-not-a-shell" ? 0 : 7)',
        literal,
      ],
    },
    {timeoutMs: 2_000},
  );

  assert.ok(result.durationMs >= 0);
  assert.equal(result.stderrTail, '');
});

test('process runner reports non-zero exit with a bounded stderr tail', async () => {
  await assert.rejects(
    runMediaProcess(
      {
        executable: process.execPath,
        args: ['-e', 'console.error("prefix-" + "x".repeat(200) + "-tail"); process.exit(7)'],
      },
      {timeoutMs: 2_000, maxStderrChars: 32},
    ),
    (error: unknown) => {
      assert.ok(error instanceof MediaProcessError);
      assert.equal(error.kind, 'exit');
      assert.equal(error.exitCode, 7);
      assert.ok(error.stderrTail.length <= 32);
      assert.match(error.stderrTail, /-tail\n?$/);
      return true;
    },
  );
});

test('process runner terminates work that exceeds its timeout', async () => {
  const startedAt = Date.now();
  await assert.rejects(
    runMediaProcess(
      {
        executable: process.execPath,
        args: ['-e', 'setInterval(() => {}, 1000)'],
      },
      {timeoutMs: 100, killGraceMs: 50},
    ),
    (error: unknown) => {
      assert.ok(error instanceof MediaProcessError);
      assert.equal(error.kind, 'timeout');
      return true;
    },
  );
  assert.ok(Date.now() - startedAt < 5_000);
});

test('process runner terminates an in-flight process when aborted', async () => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 75);
  try {
    await assert.rejects(
      runMediaProcess(
        {
          executable: process.execPath,
          args: ['-e', 'setInterval(() => {}, 1000)'],
        },
        {timeoutMs: 2_000, killGraceMs: 50, signal: controller.signal},
      ),
      (error: unknown) => {
        assert.ok(error instanceof MediaProcessError);
        assert.equal(error.kind, 'aborted');
        return true;
      },
    );
  } finally {
    clearTimeout(timer);
  }
});

test('already-aborted work never spawns a child process', async () => {
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    runMediaProcess(
      {executable: 'definitely-does-not-exist', args: []},
      {timeoutMs: 1_000, signal: controller.signal},
    ),
    (error: unknown) => {
      assert.ok(error instanceof MediaProcessError);
      assert.equal(error.kind, 'aborted');
      return true;
    },
  );
});
