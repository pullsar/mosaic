import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {checkPlayCompatibility} from '../src/contracts/compatibility.js';

const m0Capabilities = {
  schemaVersions: [1],
  presentationTypes: ['text', 'image'],
  inputTypes: ['tap', 'single_choice'],
  validatorTypes: ['none', 'equals'],
  platformFlags: [],
};

test('server matcher accepts pinned v1 compatibility fixture', async () => {
  const raw = JSON.parse(
    await readFile('../../packages/play_schema/fixtures/compat/v1_baseline_guess.json', 'utf8'),
  );
  assert.deepEqual(checkPlayCompatibility(raw, m0Capabilities), {
    compatible: true,
    missing: [],
  });
});

test('server matcher fails closed for a future required primitive', async () => {
  const raw = JSON.parse(
    await readFile('../../packages/play_schema/fixtures/compat/v1_baseline_guess.json', 'utf8'),
  ) as Record<string, unknown>;
  const states = structuredClone(raw.states) as Record<string, Record<string, unknown>>;
  const firstStateId = Object.keys(states)[0];
  assert.ok(firstStateId);
  const state = states[firstStateId] as Record<string, unknown>;
  state.input = {...(state.input as Record<string, unknown>), type: 'future_spin'};

  const decision = checkPlayCompatibility({...raw, states}, m0Capabilities);
  assert.equal(decision.compatible, false);
  assert.equal(decision.reason, 'unsupported_capability');
  assert.deepEqual(decision.missing, ['input:future_spin']);
});

test('language-neutral contract artifacts remain parseable JSON', async () => {
  for (const path of [
    '../../contracts/play-v1.schema.json',
    '../../contracts/client-capabilities-v1.schema.json',
  ]) {
    const value = JSON.parse(await readFile(path, 'utf8')) as Record<string, unknown>;
    assert.equal(typeof value.$schema, 'string');
    assert.equal(typeof value.type, 'string');
  }
});
