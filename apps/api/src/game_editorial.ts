export const requiredEditorialChecks = Object.freeze([
  'answer_proof', 'visible_clue', 'semantic_leakage', 'input_reveal',
  'fresh_structure', 'sound_masking', 'asset_rights', 'accessibility',
  'moderation', 'performance',
] as const);

export type EditorialCheck = typeof requiredEditorialChecks[number];

export interface EditorialDraft {
  readonly draftHash: string;
  readonly generatorVersion: string;
  readonly solverVersion: string;
  readonly structuralSignature: string;
  readonly mediaAssetIds: readonly string[];
}

export interface EditorialDecision {
  readonly reviewerId: string;
  readonly approvedAt: string;
  readonly checks: Readonly<Record<EditorialCheck, boolean>>;
}

export interface ApprovedEditorialDraft extends EditorialDraft {
  readonly decision: EditorialDecision;
}

/** Fails closed unless every human review gate has an explicit affirmative result. */
export function approveEditorialDraft(
  draft: EditorialDraft,
  decision: EditorialDecision,
): ApprovedEditorialDraft {
  requireText(draft.draftHash, 'draftHash');
  requireText(draft.generatorVersion, 'generatorVersion');
  requireText(draft.solverVersion, 'solverVersion');
  requireText(draft.structuralSignature, 'structuralSignature');
  if (draft.mediaAssetIds.length === 0 || draft.mediaAssetIds.some((id) => !validText(id))) {
    throw new Error('editorial_media_assets_required');
  }
  requireText(decision.reviewerId, 'reviewerId');
  if (!Number.isFinite(Date.parse(decision.approvedAt))) throw new Error('editorial_approval_time_invalid');
  for (const check of requiredEditorialChecks) {
    if (decision.checks[check] !== true) throw new Error(`editorial_check_incomplete:${check}`);
  }
  return Object.freeze({
    ...draft,
    mediaAssetIds: Object.freeze([...draft.mediaAssetIds]),
    decision: Object.freeze({...decision, checks: Object.freeze({...decision.checks})}),
  });
}

export function assertApprovedDraftMatches(
  approved: ApprovedEditorialDraft,
  draftHash: string,
): void {
  if (approved.draftHash !== draftHash) throw new Error('editorial_draft_hash_mismatch');
}

function validText(value: string): boolean {
  return value.trim().length > 0 && value.length <= 200;
}
function requireText(value: string, name: string): void {
  if (!validText(value)) throw new Error(`${name}_invalid`);
}
