import type {CanvasAssetDocument} from './canvas_asset.js';

export interface StarterPlayIntegrityDocument {
  readonly id?: unknown;
  readonly revisionId?: unknown;
  readonly format?: unknown;
  readonly classification?: unknown;
  readonly assets?: unknown;
  readonly entryState?: unknown;
  readonly states?: unknown;
}

export interface StarterPlayIntegrityInput {
  readonly id: string;
  readonly revisionId: string;
  readonly document: StarterPlayIntegrityDocument;
}

export type CatalogIntegrityReview =
  | {
      readonly kind: 'single_choice';
      readonly playId: string;
      readonly revisionId: string;
      readonly prompt: string;
      readonly answer: string;
      readonly revealStartsWith: string;
      readonly semanticEvidence: readonly string[];
    }
  | {
      readonly kind: 'preference';
      readonly playId: string;
      readonly revisionId: string;
      readonly prompt: string;
      readonly optionIds: readonly string[];
      readonly revealEvidence: readonly string[];
      readonly semanticEvidence: readonly string[];
    }
  | {
      readonly kind: 'matchstick';
      readonly playId: string;
      readonly revisionId: string;
      readonly prompt: string;
      readonly sourceAssetId: string;
      readonly solvedAssetId: string;
      readonly sourceSegments: readonly string[];
      readonly sourceEquation: string;
      readonly destinations: readonly MatchstickDestination[];
      readonly answerDestinationId: string;
      readonly solvedEquation: string;
    };

export interface MatchstickDestination {
  readonly id: string;
  readonly from: string;
  readonly to: string;
  readonly equation: string;
}

export interface ProductionCatalogIntegrityFixture {
  readonly plays: readonly StarterPlayIntegrityInput[];
  readonly canvasAssets: readonly CanvasAssetDocument[];
  readonly reviews: readonly CatalogIntegrityReview[];
}

type PlayState = {
  readonly presentation?: {
    readonly layers?: readonly {
      readonly type?: unknown;
      readonly role?: unknown;
      readonly value?: unknown;
      readonly assetId?: unknown;
    }[];
  };
  readonly input?: {
    readonly type?: unknown;
    readonly options?: readonly {readonly id?: unknown; readonly label?: unknown}[];
    readonly targets?: readonly {readonly id?: unknown}[];
  };
  readonly validation?: {readonly type?: unknown; readonly value?: unknown};
};

export function moveSegment(
  occupied: ReadonlySet<string>,
  from: string,
  to: string,
): ReadonlySet<string> {
  if (!occupied.has(from) || occupied.has(to) || from === to) {
    throw new Error('invalid_segment_move');
  }
  const next = new Set(occupied);
  next.delete(from);
  next.add(to);
  return next;
}

export function assertProductionCatalogIntegrity(
  fixture: ProductionCatalogIntegrityFixture,
): void {
  const playByIdentity = new Map<string, StarterPlayIntegrityInput>();
  for (const play of fixture.plays) {
    const identity = `${play.id}\u0000${play.revisionId}`;
    if (playByIdentity.has(identity)) {
      throw new Error(`duplicate_play_identity:${play.id}/${play.revisionId}`);
    }
    playByIdentity.set(identity, play);
  }
  const reviewedIdentities = new Set<string>();
  for (const review of fixture.reviews) {
    const identity = `${review.playId}\u0000${review.revisionId}`;
    if (reviewedIdentities.has(identity)) {
      throw new Error(
        `duplicate_review_identity:${review.playId}/${review.revisionId}`,
      );
    }
    reviewedIdentities.add(identity);
  }
  if (
    reviewedIdentities.size !== playByIdentity.size ||
    fixture.reviews.length !== fixture.plays.length ||
    [...playByIdentity.keys()].some((identity) => !reviewedIdentities.has(identity))
  ) {
    throw new Error('review_count_mismatch');
  }
  const assetById = new Map(fixture.canvasAssets.map((asset) => [asset.id, asset]));
  for (const review of fixture.reviews) {
    const play = playByIdentity.get(`${review.playId}\u0000${review.revisionId}`);
    if (play === undefined) {
      throw new Error(
        `missing_reviewed_revision:${review.playId}/${review.revisionId}`,
      );
    }
    const states = record(play.document.states, `${review.playId}.states`);
    const entryStateId = string(play.document.entryState, `${review.playId}.entryState`);
    const entryState = record(states[entryStateId], `${review.playId}.${entryStateId}`);
    const primaryAssetId = firstAssetId(play.document.assets, review.playId);
    const primaryAsset = assetById.get(primaryAssetId);
    if (primaryAsset === undefined) {
      throw new Error(`missing_canvas_asset:${review.playId}/${primaryAssetId}`);
    }
    switch (review.kind) {
      case 'single_choice':
        assertSingleChoiceReview(review, entryState, states, primaryAsset);
        break;
      case 'preference':
        assertPreferenceReview(review, entryState, primaryAsset, states);
        break;
      case 'matchstick':
        assertMatchstickReview(review, entryState, states, assetById);
        break;
    }
  }
}

function assertSingleChoiceReview(
  review: Extract<CatalogIntegrityReview, {kind: 'single_choice'}>,
  entryState: Record<string, unknown>,
  states: Record<string, unknown>,
  primaryAsset: CanvasAssetDocument,
): void {
  assertPrompt(review, entryState);
  const input = record(entryState.input, `${review.playId}.input`);
  if (input.type !== 'single_choice') {
    throw new Error(`review_input_type:${review.playId}`);
  }
  const optionIds = optionIdsFrom(input, review.playId);
  if (!optionIds.includes(review.answer)) {
    throw new Error(`review_answer_not_offered:${review.playId}/${review.answer}`);
  }
  const validation = record(entryState.validation, `${review.playId}.validation`);
  if (validation.type !== 'equals' || validation.value !== review.answer) {
    throw new Error(`review_answer_mismatch:${review.playId}`);
  }
  const semanticLabel = primaryAsset.semanticLabel ?? '';
  for (const evidence of review.semanticEvidence) {
    if (!semanticLabel.toLowerCase().includes(evidence.toLowerCase())) {
      throw new Error(`missing_semantic_evidence:${review.playId}/${evidence}`);
    }
  }
  const revealState = record(states.reveal, `${review.playId}.reveal`);
  const revealTitle = revealTitleFrom(revealState, review.playId);
  if (!revealTitle.startsWith(review.revealStartsWith)) {
    throw new Error(`review_reveal_mismatch:${review.playId}`);
  }
}

function assertPreferenceReview(
  review: Extract<CatalogIntegrityReview, {kind: 'preference'}>,
  entryState: Record<string, unknown>,
  primaryAsset: CanvasAssetDocument,
  states: Record<string, unknown>,
): void {
  assertPrompt(review, entryState);
  const input = record(entryState.input, `${review.playId}.input`);
  const actualOptions = optionIdsFrom(input, review.playId);
  if (actualOptions.join('\u0000') !== review.optionIds.join('\u0000')) {
    throw new Error(`review_options_mismatch:${review.playId}`);
  }
  const validation = record(entryState.validation, `${review.playId}.validation`);
  if (validation.type !== 'none') {
    throw new Error(`preference_has_correct_answer:${review.playId}`);
  }
  const semanticLabel = primaryAsset.semanticLabel ?? '';
  for (const evidence of review.semanticEvidence) {
    if (!semanticLabel.toLowerCase().includes(evidence.toLowerCase())) {
      throw new Error(`missing_semantic_evidence:${review.playId}/${evidence}`);
    }
  }
  const revealState = record(states.reveal, `${review.playId}.reveal`);
  const revealText = revealTitleFrom(revealState, review.playId);
  for (const evidence of review.revealEvidence) {
    if (!revealText.toLowerCase().includes(evidence.toLowerCase())) {
      throw new Error(`missing_reveal_evidence:${review.playId}/${evidence}`);
    }
  }
}

function assertMatchstickReview(
  review: Extract<CatalogIntegrityReview, {kind: 'matchstick'}>,
  entryState: Record<string, unknown>,
  states: Record<string, unknown>,
  assetById: ReadonlyMap<string, CanvasAssetDocument>,
): void {
  assertPrompt(review, entryState);
  const input = record(entryState.input, `${review.playId}.input`);
  if (input.type !== 'drag') throw new Error(`review_input_type:${review.playId}`);
  const entryLayers = presentationLayers(entryState, review.playId);
  if (
    !entryLayers.some(
      (layer) => layer.type === 'canvas' && layer.assetId === review.sourceAssetId,
    )
  ) {
    throw new Error(`matchstick_source_asset_mismatch:${review.playId}`);
  }
  const targets = Array.isArray(input.targets) ? input.targets : [];
  const targetIds = targets.map((target) =>
    string(record(target, `${review.playId}.target`).id, `${review.playId}.target.id`),
  );
  const destinationIds = review.destinations.map((destination) => destination.id);
  if (targetIds.join('\u0000') !== destinationIds.join('\u0000')) {
    throw new Error(`matchstick_targets_mismatch:${review.playId}`);
  }
  const validation = record(entryState.validation, `${review.playId}.validation`);
  if (
    validation.type !== 'target_region' ||
    validation.value !== review.answerDestinationId
  ) {
    throw new Error(`review_answer_mismatch:${review.playId}`);
  }
  const source = new Set(review.sourceSegments);
  if (parseEquation(review.sourceEquation) !== false) {
    throw new Error(`matchstick_source_already_valid:${review.playId}`);
  }
  const validDestinations = review.destinations.filter((destination) => {
    moveSegment(source, destination.from, destination.to);
    return parseEquation(destination.equation) === true;
  });
  if (
    validDestinations.length !== 1 ||
    validDestinations[0]?.id !== review.answerDestinationId ||
    validDestinations[0]?.equation !== review.solvedEquation
  ) {
    throw new Error(`matchstick_solution_not_unique:${review.playId}`);
  }
  const revealState = record(states.reveal, `${review.playId}.reveal`);
  const revealLayers = presentationLayers(revealState, review.playId);
  if (
    !revealLayers.some(
      (layer) => layer.type === 'canvas' && layer.assetId === review.solvedAssetId,
    )
  ) {
    throw new Error(`matchstick_reveal_asset_mismatch:${review.playId}`);
  }
  const solvedAsset = assetById.get(review.solvedAssetId);
  if (solvedAsset === undefined) {
    throw new Error(`missing_canvas_asset:${review.playId}/${review.solvedAssetId}`);
  }
  if (
    !solvedAsset.semanticLabel
      ?.toLowerCase()
      .includes(review.solvedEquation.toLowerCase())
  ) {
    throw new Error(`matchstick_solved_asset_mismatch:${review.playId}`);
  }
  const revealTitle = revealTitleFrom(revealState, review.playId);
  if (!revealTitle.startsWith(review.solvedEquation)) {
    throw new Error(`review_reveal_mismatch:${review.playId}`);
  }
}

function assertPrompt(
  review: {readonly playId: string; readonly prompt: string},
  entryState: Record<string, unknown>,
): void {
  const prompt = presentationLayers(entryState, review.playId).find(
    (layer) => layer.type === 'text' && layer.role === 'prompt',
  );
  if (prompt?.value !== review.prompt) {
    throw new Error(`review_prompt_mismatch:${review.playId}`);
  }
}

function revealTitleFrom(state: Record<string, unknown>, playId: string): string {
  const reveal = presentationLayers(state, playId).find(
    (layer) => layer.type === 'text' && layer.role === 'reveal_title',
  );
  return string(reveal?.value, `${playId}.reveal_title`);
}

function presentationLayers(
  state: Record<string, unknown>,
  playId: string,
): readonly {
  readonly type?: unknown;
  readonly role?: unknown;
  readonly value?: unknown;
  readonly assetId?: unknown;
}[] {
  const presentation = record(state.presentation, `${playId}.presentation`);
  if (!Array.isArray(presentation.layers)) {
    throw new TypeError(`${playId}.presentation.layers must be an array`);
  }
  return presentation.layers;
}

function firstAssetId(value: unknown, playId: string): string {
  if (!Array.isArray(value)) throw new TypeError(`${playId}.assets must be an array`);
  return string(value[0], `${playId}.assets[0]`);
}

function optionIdsFrom(input: Record<string, unknown>, playId: string): string[] {
  if (!Array.isArray(input.options)) {
    throw new TypeError(`${playId}.input.options must be an array`);
  }
  return input.options.map((option, index) =>
    string(
      record(option, `${playId}.input.options[${index}]`).id,
      `${playId}.input.options[${index}].id`,
    ),
  );
}

function parseEquation(equation: string): boolean | false {
  const parsed = /^(\d+)\s*([+\-])\s*(\d+)\s*=\s*(\d+)$/.exec(equation);
  if (parsed === null) return false;
  const left = Number.parseInt(parsed[1]!, 10);
  const right = Number.parseInt(parsed[3]!, 10);
  const expected = Number.parseInt(parsed[4]!, 10);
  const actual = parsed[2] === '+' ? left + right : left - right;
  return actual === expected;
}

function record(value: unknown, name: string): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(`${name} must be an object`);
  }
  return value as Record<string, unknown>;
}

function string(value: unknown, name: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new TypeError(`${name} must be a non-empty string`);
  }
  return value;
}
