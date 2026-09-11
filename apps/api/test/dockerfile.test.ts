import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';

test('API image build context includes curated Echo Architect audio', async () => {
  const dockerfile = await readFile(new URL('../Dockerfile', import.meta.url), 'utf8');

  assert.match(
    dockerfile,
    /COPY --chown=node:node apps\/api\/curated_assets \.\/curated_assets/,
  );
});
