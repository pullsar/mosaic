import {equal, throws} from 'node:assert/strict';
import {test} from 'node:test';
import {approveEditorialDraft, assertApprovedDraftMatches, requiredEditorialChecks} from '../src/game_editorial.js';

const draft = {draftHash: 'a'.repeat(64), generatorVersion: 'g1', solverVersion: 's1', structuralSignature: 'shape', mediaAssetIds: ['canvas_a']};
const decision = {reviewerId: 'editor_1', approvedAt: '2026-09-11T12:00:00.000Z', checks: Object.fromEntries(requiredEditorialChecks.map((check) => [check, true]))} as Record<string, unknown>;

test('editorial approval requires every review gate and immutable draft hash', () => {
  const approved = approveEditorialDraft(draft, decision as never);
  equal(approved.draftHash, draft.draftHash);
  assertApprovedDraftMatches(approved, draft.draftHash);
  throws(() => assertApprovedDraftMatches(approved, 'b'.repeat(64)), /hash/);
  const missing = {...decision, checks: {...(decision.checks as object), moderation: false}};
  throws(() => approveEditorialDraft(draft, missing as never), /moderation/);
});
