import type {
  CanvasAssetDocument,
  CanvasElement,
  CanvasPalette,
} from './canvas_asset.js';
import {canonicalJson} from './media.js';
import {
  simulateSleightTrajectory,
  type SleightTrajectory,
} from './sleight_solver.js';
import {
  evaluateConstellationRound,
  type ConstellationTrajectory,
} from './constellation_solver.js';
import {
  solveRuleFlip,
  type RuleFlipObject,
} from './rule_flip_solver.js';
import {
  solveEvidenceLens,
  type EvidenceLensClaim,
  type EvidenceLensPoint,
} from './evidence_lens_solver.js';
import {
  solveCounterexample,
  type CounterexampleClaim,
  type CounterexampleTile,
} from './counterexample_solver.js';

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

type CounterexampleVisualTile = CounterexampleTile & {
  readonly x: number;
};

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
      readonly movingPieceId: string;
      readonly destinations: readonly MatchstickDestination[];
      readonly answerDestinationId: string;
      readonly solvedEquation: string;
    }
  | {
      readonly kind: 'quiet_switch';
      readonly playId: string;
      readonly revisionId: string;
      readonly prompt: string;
      readonly sourceAssetId: string;
      readonly choiceAssetId: string;
      readonly choicePrompt: string;
      readonly answer: string;
      readonly changedElementIndex: number;
      readonly revealStartsWith: string;
    }
  | {
      readonly kind: 'sleight';
      readonly playId: string;
      readonly revisionId: string;
      readonly prompt: string;
      readonly cueId: string;
      readonly durationMs: number;
      readonly trajectory: SleightTrajectory;
      readonly answerPositionId: string;
      readonly revealStartsWith: string;
    }
  | {
      readonly kind: 'constellation';
      readonly playId: string;
      readonly revisionId: string;
      readonly prompt: string;
      readonly cueId: string;
      readonly durationMs: number;
      readonly trajectory: ConstellationTrajectory;
      readonly targetObjectIds: readonly string[];
      readonly revealStartsWith: string;
    }
  | {
      readonly kind: 'rule_flip';
      readonly playId: string;
      readonly revisionId: string;
      readonly sourceAssetId: string;
      readonly object: RuleFlipObject;
    }  | {
      readonly kind: 'evidence_lens';
      readonly playId: string;
      readonly revisionId: string;
      readonly sourceAssetId: string;
      readonly points: readonly EvidenceLensPoint[];
      readonly claims: readonly EvidenceLensClaim[];
    }  | {
      readonly kind: 'counterexample';
      readonly playId: string;
      readonly revisionId: string;
      readonly prompt: string;
      readonly claim: CounterexampleClaim;
      readonly tiles: readonly CounterexampleVisualTile[];
      readonly sourceAssetId: string;
      readonly solvedAssetId: string;
      readonly revealStartsWith: string;
    };

export interface MatchstickDestination {
  readonly id: string;
  readonly from: string;
  readonly to: string;
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
      readonly scene?: unknown;
    }[];
  };
  readonly input?: {
    readonly type?: unknown;
    readonly options?: readonly {readonly id?: unknown; readonly label?: unknown}[];
    readonly targets?: readonly {readonly id?: unknown}[];
  };
  readonly validation?: {readonly type?: unknown; readonly value?: unknown};
  readonly transition?: Readonly<Record<string, unknown>>;
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

const digitSegments = {
  '0': ['a', 'b', 'c', 'd', 'e', 'f'],
  '1': ['b', 'c'],
  '2': ['a', 'b', 'd', 'e', 'g'],
  '3': ['a', 'b', 'c', 'd', 'g'],
  '4': ['b', 'c', 'f', 'g'],
  '5': ['a', 'c', 'd', 'f', 'g'],
  '6': ['a', 'c', 'd', 'e', 'f', 'g'],
  '7': ['a', 'b', 'c'],
  '8': ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
  '9': ['a', 'b', 'c', 'd', 'f', 'g'],
} as const;

const digitBySignature = new Map(
  Object.entries(digitSegments).map(([digit, segments]) => [
    [...segments].sort().join(','),
    digit,
  ]),
);

const digitSlots = ['left', 'right', 'result'] as const;
const digitSegmentNames = ['a', 'b', 'c', 'd', 'e', 'f', 'g'] as const;
const operatorSegmentNames = ['horizontal', 'vertical'] as const;
const knownMatchstickSegments = new Set<string>([
  ...digitSlots.flatMap((slot) =>
    digitSegmentNames.map((segment) => `${slot}.${segment}`),
  ),
  ...operatorSegmentNames.map((segment) => `operator.${segment}`),
]);

export function matchstickEquationFromSegments(
  occupied: ReadonlySet<string>,
): string | null {
  if ([...occupied].some((segment) => !knownMatchstickSegments.has(segment))) {
    return null;
  }
  const digits = digitSlots.map((slot) => {
    const signature = digitSegmentNames
      .filter((segment) => occupied.has(`${slot}.${segment}`))
      .sort()
      .join(',');
    return digitBySignature.get(signature);
  });
  if (digits.some((digit) => digit === undefined)) return null;
  const horizontal = occupied.has('operator.horizontal');
  const vertical = occupied.has('operator.vertical');
  const operator = horizontal && vertical ? '+' : horizontal ? '-' : null;
  if (operator === null) return null;
  return `${digits[0]} ${operator} ${digits[1]} = ${digits[2]}`;
}

export function buildMatchstickCanvasAsset(
  id: string,
  occupied: ReadonlySet<string>,
  palette: CanvasPalette,
): CanvasAssetDocument {
  const equation = matchstickEquationFromSegments(occupied);
  if (equation === null) throw new Error('matchstick_configuration_not_renderable');
  const elements: CanvasElement[] = [];
  for (const segment of occupied) {
    const element = matchstickLineById.get(segment);
    if (element === undefined) {
      throw new Error(`matchstick_unknown_segment:${segment}`);
    }
    elements.push({...element});
  }
  elements.push(
    line(0.62, 0.47, 0.7, 0.47),
    line(0.62, 0.53, 0.7, 0.53),
  );
  return {
    schemaVersion: 1,
    id,
    semanticLabel: `${
      parseEquation(equation) ? 'A solved' : 'A'
    } matchstick equation showing ${equation}`,
    elements,
    palette,
  };
}

const matchstickLineById = buildMatchstickLineMap();

function buildMatchstickLineMap(): ReadonlyMap<string, CanvasElement> {
  const lines = new Map<string, CanvasElement>();
  const centers = {left: 0.16, right: 0.5, result: 0.82} as const;
  for (const [slot, centerX] of Object.entries(centers)) {
    const left = centerX - 0.055;
    const right = centerX + 0.055;
    const top = 0.36;
    const middle = 0.5;
    const bottom = 0.64;
    lines.set(`${slot}.a`, line(left, top, right, top));
    lines.set(`${slot}.b`, line(right, top, right, middle));
    lines.set(`${slot}.c`, line(right, middle, right, bottom));
    lines.set(`${slot}.d`, line(left, bottom, right, bottom));
    lines.set(`${slot}.e`, line(left, middle, left, bottom));
    lines.set(`${slot}.f`, line(left, top, left, middle));
    lines.set(`${slot}.g`, line(left, middle, right, middle));
  }
  lines.set('operator.horizontal', line(0.3, 0.5, 0.38, 0.5));
  lines.set('operator.vertical', line(0.34, 0.43, 0.34, 0.57));
  return lines;
}

function line(x1: number, y1: number, x2: number, y2: number): CanvasElement {
  return {
    type: 'line',
    x1,
    y1,
    x2,
    y2,
    width: 0.016,
    cap: 'round',
    tone: 'foreground',
  };
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
    const primaryAsset = review.kind === 'sleight' || review.kind === 'constellation'
      ? undefined
      : assetById.get(firstAssetId(play.document.assets, review.playId));
    if (review.kind !== 'sleight' && review.kind !== 'constellation' && primaryAsset === undefined) {
      throw new Error(`missing_canvas_asset:${review.playId}`);
    }
    switch (review.kind) {
      case 'single_choice':
        assertSingleChoiceReview(review, entryState, states, primaryAsset!);
        break;
      case 'preference':
        assertPreferenceReview(review, entryState, primaryAsset!, states);
        break;
      case 'matchstick':
        assertMatchstickReview(review, entryState, states, assetById);
        break;
      case 'quiet_switch':
        assertQuietSwitchReview(review, entryState, states, assetById);
        break;
      case 'sleight':
        assertSleightReview(review, play.document, entryState, states);
        break;
      case 'constellation':
        assertConstellationReview(review, play.document, entryState, states);
        break;
      case 'rule_flip':
        assertRuleFlipReview(review, entryState, states, assetById);
        break;
      case 'evidence_lens':
        assertEvidenceLensReview(review, entryState, states, assetById);
        break;      case 'counterexample':
        assertCounterexampleReview(review, entryState, states, assetById);
        break;
    }
  }
}

function assertRuleFlipReview(
  review: Extract<CatalogIntegrityReview, {kind: 'rule_flip'}>,
  entryState: Record<string, unknown>,
  states: Record<string, unknown>,
  assetById: ReadonlyMap<string, CanvasAssetDocument>,
): void {
  const asset = assetById.get(review.sourceAssetId);
  if (asset === undefined) throw new Error(`rule_flip_asset_missing:${review.playId}`);
  const shape = solveRuleFlip('shape', review.object).side;
  const fill = solveRuleFlip('fill', review.object).side;
  const shapeInput = record(entryState.input, `${review.playId}.shape.input`);
  const fillState = record(states.fill, `${review.playId}.fill`);
  const fillInput = record(fillState.input, `${review.playId}.fill.input`);
  const shapeAnswer = `shape_${shape}`;
  const fillAnswer = `fill_${fill}`;
  if (shapeInput.type !== 'single_choice' || fillInput.type !== 'single_choice' ||
      !optionIdsFrom(shapeInput, review.playId).every((id) => id.startsWith('shape_')) ||
      !optionIdsFrom(fillInput, review.playId).every((id) => id.startsWith('fill_')) ||
      record(entryState.validation, `${review.playId}.shape.validation`).value !== shapeAnswer ||
      record(fillState.validation, `${review.playId}.fill.validation`).value !== fillAnswer ||
      record(entryState.transition, `${review.playId}.shape.transition`).correct !== 'fill' ||
      record(fillState.transition, `${review.playId}.fill.transition`).correct !== 'reveal' ||
      !presentationLayers(entryState, review.playId).some((layer) => layer.type === 'canvas' && layer.assetId === review.sourceAssetId)) {
    throw new Error(`rule_flip_trial_mismatch:${review.playId}`);
  }
  const reveal = record(states.reveal, `${review.playId}.reveal`);
  if (!revealTitleFrom(reveal, review.playId).startsWith(`Shape: ${shape}. Fill: ${fill}.`)) {
    throw new Error(`rule_flip_reveal_mismatch:${review.playId}`);
  }
  const expectedLabel = `A ${review.object.fill} ${review.object.shape}.`;
  if (asset.semanticLabel !== expectedLabel) throw new Error(`rule_flip_visual_mismatch:${review.playId}`);
}
function assertEvidenceLensReview(
  review: Extract<CatalogIntegrityReview, {kind: 'evidence_lens'}>,
  entryState: Record<string, unknown>,
  states: Record<string, unknown>,
  assetById: ReadonlyMap<string, CanvasAssetDocument>,
): void {
  const asset = assetById.get(review.sourceAssetId);
  if (asset === undefined) throw new Error(`evidence_lens_asset_missing:${review.playId}`);
  const input = record(entryState.input, `${review.playId}.claim.input`);
  const transitions = record(entryState.transition, `${review.playId}.claim.transition`);
  if (input.type !== 'single_choice' || record(entryState.validation, `${review.playId}.claim.validation`).type !== 'none' ||
      !review.claims.every((claim) => optionIdsFrom(input, review.playId).includes(claim.id) && transitions[claim.id] === `evidence_${claim.id}`)) {
    throw new Error(`evidence_lens_claim_route_mismatch:${review.playId}`);
  }
  for (const claim of review.claims) {
    const solution = solveEvidenceLens(claim, review.points);
    const evidence = record(states[`evidence_${claim.id}`], `${review.playId}.evidence`);
    const reveal = record(states[`reveal_${claim.id}`], `${review.playId}.reveal`);
    if (!presentationLayers(evidence, review.playId).some((layer) => layer.type === 'canvas' && layer.assetId === review.sourceAssetId) ||
        record(evidence.validation, `${review.playId}.evidence.validation`).value !== solution.answerId ||
        record(evidence.transition, `${review.playId}.evidence.transition`).correct !== `reveal_${claim.id}` ||
        record(evidence.transition, `${review.playId}.evidence.transition`).incorrect !== `evidence_${claim.id}` ||
        !revealTitleFrom(reveal, review.playId).startsWith(`${solution.answerId.toUpperCase()}. ${claim.label}`)) {
      throw new Error(`evidence_lens_solution_mismatch:${review.playId}`);
    }
  }
  if (!review.points.every((point) => asset.elements.some((element) => element.type === 'label' && element.text === String(point.value)))) {
    throw new Error(`evidence_lens_chart_mismatch:${review.playId}`);
  }
}
function assertCounterexampleReview(
  review: Extract<CatalogIntegrityReview, {kind: 'counterexample'}>,
  entryState: Record<string, unknown>,
  states: Record<string, unknown>,
  assetById: ReadonlyMap<string, CanvasAssetDocument>,
): void {
  assertPrompt(review, entryState);
  const solution = solveCounterexample(review.claim, review.tiles);
  const source = assetById.get(review.sourceAssetId);
  const solved = assetById.get(review.solvedAssetId);
  if (source === undefined || solved === undefined) {
    throw new Error(`counterexample_asset_missing:${review.playId}`);
  }
  const sourceLayers = presentationLayers(entryState, review.playId);
  if (!sourceLayers.some((layer) => layer.type === 'canvas' && layer.assetId === review.sourceAssetId)) {
    throw new Error(`counterexample_source_mismatch:${review.playId}`);
  }
  const input = record(entryState.input, `${review.playId}.input`);
  const options = optionIdsFrom(input, review.playId);
  const validation = record(entryState.validation, `${review.playId}.validation`);
  if (
    input.type !== 'single_choice' ||
    options.length !== review.tiles.length + 1 ||
    !review.tiles.every((tile) => options.includes(tile.id)) ||
    !options.includes('insufficient') ||
    validation.type !== 'equals' ||
    validation.value !== solution.answerId ||
    record(entryState.transition, `${review.playId}.transition`).correct !== 'reveal' ||
    record(entryState.transition, `${review.playId}.transition`).incorrect !== 'choose'
  ) {
    throw new Error(`counterexample_choice_mismatch:${review.playId}`);
  }
  if (
    !source.elements.some((element) => element.type === 'label' && element.text === 'A') ||
    !source.elements.some((element) => element.type === 'label' && element.text === 'B') ||
    !source.elements.some((element) => element.type === 'label' && element.text === 'C') ||
    !review.tiles.every((tile) => {
      const tone = tile.color === 'red' ? 'accent' : tile.color === 'blue' ? 'muted' : 'surface';
      return tile.shape === 'round'
        ? source.elements.some(
            (element) => element.type === 'circle' && element.x === tile.x &&
              element.y === .42 && element.tone === tone,
          )
        : source.elements.some(
            (element) => element.type === 'rect' && element.x === tile.x - .07 &&
              element.y === .35 && element.tone === tone,
          );
    })
  ) {
    throw new Error(`counterexample_visual_clue_mismatch:${review.playId}`);
  }
  const reveal = record(states.reveal, `${review.playId}.reveal`);
  if (
    !presentationLayers(reveal, review.playId).some(
      (layer) => layer.type === 'canvas' && layer.assetId === review.solvedAssetId,
    ) ||
    !revealTitleFrom(reveal, review.playId).startsWith(review.revealStartsWith) ||
    !solved.elements.some(
      (element) => element.type === 'label' && element.text.includes('breaks it'),
    )
  ) {
    throw new Error(`counterexample_reveal_mismatch:${review.playId}`);
  }
}

function assertConstellationReview(
  review: Extract<CatalogIntegrityReview, {kind: 'constellation'}>,
  document: StarterPlayIntegrityDocument,
  entryState: Record<string, unknown>,
  states: Record<string, unknown>,
): void {
  assertPrompt(review, entryState);
  const flags = Array.isArray((document as Record<string, unknown>).requiredPlatformFlags)
    ? (document as Record<string, unknown>).requiredPlatformFlags as readonly unknown[]
    : [];
  for (const flag of ['timed_scene_v1', 'multiple_choice', 'set_equality']) {
    if (!flags.includes(flag)) {
      throw new Error(`constellation_capability_missing:${review.playId}`);
    }
  }
  const solved = evaluateConstellationRound(
    review.trajectory,
    review.targetObjectIds,
  );
  const input = record(entryState.input, `${review.playId}.input`);
  if (
    input.type !== 'timed_cue' ||
    input.cueId !== review.cueId ||
    input.cueOrdinal !== 1 ||
    input.durationMs !== review.durationMs ||
    record(entryState.transition, `${review.playId}.transition`).default !== 'choose'
  ) {
    throw new Error(`constellation_timed_input_mismatch:${review.playId}`);
  }
  const initialScene = record(
    presentationLayers(entryState, review.playId).find(
      (layer) => layer.type === 'scene' && layer.role === 'media',
    )?.scene,
    `${review.playId}.scene`,
  );
  const initialObjects = Array.isArray(initialScene.objects)
    ? initialScene.objects.map((object) => record(object, `${review.playId}.object`))
    : [];
  if (
    initialObjects.length !== 6 ||
    !review.trajectory.objectIds.every((id) =>
      initialObjects.some((object) => object.id === id),
    ) ||
    !review.targetObjectIds.every((id) =>
      initialObjects.some((object) => object.id === id && object.tone === 'accent'),
    )
  ) {
    throw new Error(`constellation_initial_marks_missing:${review.playId}`);
  }
  const cues = Array.isArray(initialScene.cues) ? initialScene.cues : [];
  if (!review.trajectory.objectIds.every((id) =>
    cues.some((cue) => {
      const candidate = record(cue, `${review.playId}.cue`);
      const expected = review.trajectory.tracks.find(
        (track) => track.objectId === id,
      );
      return candidate.id === review.cueId &&
        candidate.objectId === id &&
        candidate.durationMs === review.durationMs &&
        canonicalJson(candidate.keyframes) === canonicalJson(expected?.keyframes);
    }))) {
    throw new Error(`constellation_cue_tracks_missing:${review.playId}`);
  }
  const choose = record(states.choose, `${review.playId}.choose`);
  const choiceInput = record(choose.input, `${review.playId}.choose.input`);
  const options = optionIdsFrom(choiceInput, review.playId);
  const validation = record(choose.validation, `${review.playId}.choose.validation`);
  if (
    choiceInput.type !== 'multiple_choice' ||
    options.length !== review.trajectory.objectIds.length ||
    !review.trajectory.objectIds.every((id) => options.includes(id)) ||
    validation.type !== 'set_equality' ||
    !sameStringSet(validation.value, solved.acceptedObjectIds) ||
    record(choose.transition, `${review.playId}.choose.transition`).correct !== 'replay' ||
    record(choose.transition, `${review.playId}.choose.transition`).incorrect !== 'choose'
  ) {
    throw new Error(`constellation_choice_mismatch:${review.playId}`);
  }
  const choiceScene = record(
    presentationLayers(choose, review.playId).find(
      (layer) => layer.type === 'scene' && layer.role === 'media',
    )?.scene,
    `${review.playId}.choose.scene`,
  );
  const choiceObjects = Array.isArray(choiceScene.objects)
    ? choiceScene.objects.map((object) => record(object, `${review.playId}.choice.object`))
    : [];
  if (
    choiceObjects.length !== 6 ||
    !review.trajectory.objectIds.every((id) => {
      const object = choiceObjects.find((candidate) => candidate.id === id);
      const finalRect = solved.finalRects.get(id);
      return object !== undefined && finalRect !== undefined &&
        object.tone !== 'accent' &&
        object.x === finalRect.x && object.y === finalRect.y &&
        object.width === finalRect.width && object.height === finalRect.height;
    })
  ) {
    throw new Error(`constellation_final_scene_mismatch:${review.playId}`);
  }
  const replay = record(states.replay, `${review.playId}.replay`);
  const replayInput = record(replay.input, `${review.playId}.replay.input`);
  const replayScene = record(
    presentationLayers(replay, review.playId).find(
      (layer) => layer.type === 'scene' && layer.role === 'media',
    )?.scene,
    `${review.playId}.replay.scene`,
  );
  const replayCues = Array.isArray(replayScene.cues) ? replayScene.cues : [];
  if (
    replayInput.type !== 'timed_cue' ||
    replayInput.cueId !== review.cueId ||
    replayInput.cueOrdinal !== 1 ||
    replayInput.durationMs !== review.durationMs ||
    record(replay.transition, `${review.playId}.replay.transition`).default !== 'reveal' ||
    !review.trajectory.objectIds.every((id) =>
      replayCues.some((cue) => {
        const candidate = record(cue, `${review.playId}.replay.cue`);
        const expected = review.trajectory.tracks.find(
          (track) => track.objectId === id,
        );
        return candidate.id === review.cueId &&
          candidate.objectId === id &&
          candidate.durationMs === review.durationMs &&
          canonicalJson(candidate.keyframes) === canonicalJson(expected?.keyframes);
      }),
    )
  ) {
    throw new Error(`constellation_replay_missing:${review.playId}`);
  }
  const reveal = record(states.reveal, `${review.playId}.reveal`);
  if (!revealTitleFrom(reveal, review.playId).startsWith(review.revealStartsWith)) {
    throw new Error(`constellation_reveal_mismatch:${review.playId}`);
  }
}

function sameStringSet(value: unknown, expected: readonly string[]): boolean {
  return Array.isArray(value) &&
    value.length === expected.length &&
    value.every((item) => typeof item === 'string') &&
    new Set(value).size === value.length &&
    value.every((item) => expected.includes(item));
}

function assertSleightReview(
  review: Extract<CatalogIntegrityReview, {kind: 'sleight'}>,
  document: StarterPlayIntegrityDocument,
  entryState: Record<string, unknown>,
  states: Record<string, unknown>,
): void {
  assertPrompt(review, entryState);
  const flags: readonly unknown[] = Array.isArray(
    (document as Record<string, unknown>).requiredPlatformFlags,
  )
    ? (document as Record<string, unknown>).requiredPlatformFlags as readonly unknown[]
    : [];
  if (!flags.includes('timed_scene_v1')) {
    throw new Error(`sleight_capability_missing:${review.playId}`);
  }
  const input = record(entryState.input, `${review.playId}.input`);
  if (
    input.type !== 'timed_cue' ||
    input.cueId !== review.cueId ||
    input.cueOrdinal !== 1 ||
    input.durationMs !== review.durationMs
  ) {
    throw new Error(`sleight_timed_input_mismatch:${review.playId}`);
  }
  const sceneLayer = presentationLayers(entryState, review.playId).find(
    (layer) => layer.type === 'scene' && layer.role === 'media',
  );
  const scene = record(sceneLayer?.scene, `${review.playId}.scene`);
  const cues = Array.isArray(scene.cues) ? scene.cues : [];
  if (!review.trajectory.cupIds.every((cupId) =>
    cues.some((cue) => {
      const candidate = record(cue, `${review.playId}.cue`);
      return candidate.id === review.cueId && candidate.objectId === cupId;
    }))) {
    throw new Error(`sleight_cue_tracks_missing:${review.playId}`);
  }
  const answer = simulateSleightTrajectory(review.trajectory).finalPositionId;
  if (answer !== review.answerPositionId) {
    throw new Error(`sleight_answer_mismatch:${review.playId}`);
  }
  const choose = record(states.choose, `${review.playId}.choose`);
  const options = optionIdsFrom(record(choose.input, `${review.playId}.choose.input`), review.playId);
  const validation = record(choose.validation, `${review.playId}.choose.validation`);
  if (
    !options.includes(answer) ||
    validation.type !== 'equals' ||
    validation.value !== answer
  ) {
    throw new Error(`sleight_choice_mismatch:${review.playId}`);
  }
  if (states.replay === undefined) {
    throw new Error(`sleight_replay_missing:${review.playId}`);
  }
  const replay = record(states.replay, `${review.playId}.replay`);
  const replayInput = record(replay.input, `${review.playId}.replay.input`);
  if (
    replayInput.type !== 'timed_cue' ||
    replayInput.cueId !== review.cueId ||
    replayInput.cueOrdinal !== 1 ||
    replayInput.durationMs !== review.durationMs ||
    record(replay.transition, `${review.playId}.replay.transition`).default !==
      'reveal'
  ) {
    throw new Error(`sleight_replay_missing:${review.playId}`);
  }
  const replayScene = record(
    presentationLayers(replay, review.playId).find(
      (layer) => layer.type === 'scene' && layer.role === 'media',
    )?.scene,
    `${review.playId}.replay.scene`,
  );
  const replayCues = Array.isArray(replayScene.cues) ? replayScene.cues : [];
  if (!review.trajectory.cupIds.every((cupId) =>
    replayCues.some((cue) => {
      const candidate = record(cue, `${review.playId}.replay.cue`);
      return candidate.id === review.cueId && candidate.objectId === cupId;
    }))) {
    throw new Error(`sleight_replay_missing:${review.playId}`);
  }
  const reveal = record(states.reveal, `${review.playId}.reveal`);
  if (!revealTitleFrom(reveal, review.playId).startsWith(review.revealStartsWith)) {
    throw new Error(`sleight_reveal_mismatch:${review.playId}`);
  }
}

function assertQuietSwitchReview(
  review: Extract<CatalogIntegrityReview, {kind: 'quiet_switch'}>,
  entryState: Record<string, unknown>,
  states: Record<string, unknown>,
  assetById: ReadonlyMap<string, CanvasAssetDocument>,
): void {
  assertPrompt(review, entryState);
  const entryInput = record(entryState.input, `${review.playId}.input`);
  const entryValidation = record(entryState.validation, `${review.playId}.validation`);
  const entryTransition = record(entryState.transition, `${review.playId}.transition`);
  if (
    entryInput.type !== 'timed_cue' ||
    typeof entryInput.cueId !== 'string' ||
    !/^[A-Za-z0-9_-]{1,80}$/.test(entryInput.cueId) ||
    !Number.isInteger(entryInput.cueOrdinal) ||
    (entryInput.cueOrdinal as number) < 1 ||
    (entryInput.cueOrdinal as number) > 128 ||
    !Number.isInteger(entryInput.durationMs) ||
    (entryInput.durationMs as number) < 300 ||
    (entryInput.durationMs as number) > 10000 ||
    entryValidation.type !== 'none' ||
    entryTransition.default !== 'choose'
  ) {
    throw new Error(`quiet_switch_observation_flow:${review.playId}`);
  }
  const entryLayers = presentationLayers(entryState, review.playId);
  if (!entryLayers.some((layer) => layer.type === 'canvas' && layer.assetId === review.sourceAssetId)) {
    throw new Error(`quiet_switch_source_asset_mismatch:${review.playId}`);
  }
  const choiceState = record(states.choose, `${review.playId}.choose`);
  assertPrompt({...review, prompt: review.choicePrompt}, choiceState);
  const choiceInput = record(choiceState.input, `${review.playId}.choose.input`);
  const choiceValidation = record(choiceState.validation, `${review.playId}.choose.validation`);
  if (
    choiceInput.type !== 'single_choice' ||
    !optionIdsFrom(choiceInput, review.playId).includes(review.answer) ||
    choiceValidation.type !== 'equals' ||
    choiceValidation.value !== review.answer
  ) {
    throw new Error(`quiet_switch_answer_mismatch:${review.playId}`);
  }
  const choiceLayers = presentationLayers(choiceState, review.playId);
  if (!choiceLayers.some((layer) => layer.type === 'canvas' && layer.assetId === review.choiceAssetId)) {
    throw new Error(`quiet_switch_choice_asset_mismatch:${review.playId}`);
  }
  const source = assetById.get(review.sourceAssetId);
  const choice = assetById.get(review.choiceAssetId);
  if (source === undefined || choice === undefined) {
    throw new Error(`missing_canvas_asset:${review.playId}`);
  }
  if (
    source.semanticLabel !== choice.semanticLabel ||
    canonicalJson(source.palette) !== canonicalJson(choice.palette) ||
    source.elements.length !== choice.elements.length
  ) {
    throw new Error(`quiet_switch_scene_structure:${review.playId}`);
  }
  const changed = source.elements.flatMap((element, index) =>
    canonicalJson(element) === canonicalJson(choice.elements[index]) ? [] : [index],
  );
  if (
    changed.length !== 1 ||
    changed[0] !== review.changedElementIndex ||
    source.elements[review.changedElementIndex]?.type !== 'circle' ||
    choice.elements[review.changedElementIndex]?.type !== 'circle' ||
    !isPureCircleXTransform(
      source.elements[review.changedElementIndex],
      choice.elements[review.changedElementIndex],
    )
  ) {
    throw new Error(`quiet_switch_change_mismatch:${review.playId}`);
  }
  const revealState = record(states.reveal, `${review.playId}.reveal`);
  const revealLayers = presentationLayers(revealState, review.playId);
  if (!revealLayers.some((layer) => layer.type === 'canvas' && layer.assetId === review.choiceAssetId)) {
    throw new Error(`quiet_switch_reveal_asset_mismatch:${review.playId}`);
  }
  if (!revealTitleFrom(revealState, review.playId).startsWith(review.revealStartsWith)) {
    throw new Error(`review_reveal_mismatch:${review.playId}`);
  }
}

function isPureCircleXTransform(
  source: CanvasElement | undefined,
  choice: CanvasElement | undefined,
): boolean {
  if (source?.type !== 'circle' || choice?.type !== 'circle') return false;
  return source.x !== choice.x &&
    source.y === choice.y &&
    source.radius === choice.radius &&
    source.strokeWidth === choice.strokeWidth &&
    source.fill === choice.fill &&
    source.tone === choice.tone;
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
  if (input.type !== 'piece_move') throw new Error(`review_input_type:${review.playId}`);
  const entryLayers = presentationLayers(entryState, review.playId);
  if (
    !entryLayers.some(
      (layer) => layer.type === 'canvas' && layer.assetId === review.sourceAssetId,
    )
  ) {
    throw new Error(`matchstick_source_asset_mismatch:${review.playId}`);
  }
  const sceneLayer = entryLayers.find(
    (layer) => layer.type === 'scene' && layer.role === 'media',
  );
  const scene = record(sceneLayer?.scene, `${review.playId}.scene`);
  const objects = Array.isArray(scene.objects) ? scene.objects : [];
  const movablePiece = objects.find((object) => {
    const candidate = record(object, `${review.playId}.scene.object`);
    return candidate.id === review.movingPieceId && candidate.movable === true;
  });
  if (movablePiece === undefined) {
    throw new Error(`matchstick_moving_piece_mismatch:${review.playId}`);
  }
  const targets = Array.isArray(scene.targets) ? scene.targets : [];
  const targetIds = targets.map((target) =>
    string(record(target, `${review.playId}.target`).id, `${review.playId}.target.id`),
  );
  const destinationIds = review.destinations.map((destination) => destination.id);
  if (targetIds.join('\u0000') !== destinationIds.join('\u0000')) {
    throw new Error(`matchstick_targets_mismatch:${review.playId}`);
  }
  const validation = record(entryState.validation, `${review.playId}.validation`);
  if (validation.type !== 'legal_piece_move' || !Array.isArray(validation.value)) {
    throw new Error(`review_answer_mismatch:${review.playId}`);
  }
  const legalMoves = validation.value.map((move, index) =>
    record(move, `${review.playId}.validation.value[${index}]`),
  );
  if (
    legalMoves.length !== review.destinations.length ||
    legalMoves.some((move, index) =>
      move.pieceId !== review.movingPieceId ||
      move.targetId !== review.destinations[index]?.id ||
      move.correct !== (review.destinations[index]?.id === review.answerDestinationId),
    )
  ) {
    throw new Error(`review_answer_mismatch:${review.playId}`);
  }
  const source = new Set(review.sourceSegments);
  if (source.size !== review.sourceSegments.length) {
    throw new Error(`matchstick_duplicate_source_segment:${review.playId}`);
  }
  const sourceEquation = matchstickEquationFromSegments(source);
  if (sourceEquation !== review.sourceEquation) {
    throw new Error(`matchstick_source_equation_mismatch:${review.playId}`);
  }
  if (parseEquation(review.sourceEquation) !== false) {
    throw new Error(`matchstick_source_already_valid:${review.playId}`);
  }
  const sourceAsset = assetById.get(review.sourceAssetId);
  if (sourceAsset === undefined) {
    throw new Error(`missing_canvas_asset:${review.playId}/${review.sourceAssetId}`);
  }
  const sourcePieceIds = new Set(
    review.destinations.map((destination) => destination.from),
  );
  if (sourcePieceIds.size !== 1) {
    throw new Error(`matchstick_multiple_source_segments:${review.playId}`);
  }
  const sourceWithoutMovedPiece = new Set(source);
  sourceWithoutMovedPiece.delete([...sourcePieceIds][0]!);
  assertMatchstickAsset(sourceAsset, sourceWithoutMovedPiece, review.playId);
  const resolvedDestinations = review.destinations.map((destination) => {
    const segments = moveSegment(source, destination.from, destination.to);
    return {
      destination,
      equation: matchstickEquationFromSegments(segments),
      segments,
    };
  });
  const validDestinations = resolvedDestinations.filter(
    (candidate) =>
      candidate.equation !== null && parseEquation(candidate.equation) === true,
  );
  if (
    validDestinations.length !== 1 ||
    validDestinations[0]?.destination.id !== review.answerDestinationId ||
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
  assertMatchstickAsset(solvedAsset, validDestinations[0]!.segments, review.playId);
  const revealTitle = revealTitleFrom(revealState, review.playId);
  if (!revealTitle.startsWith(review.solvedEquation)) {
    throw new Error(`review_reveal_mismatch:${review.playId}`);
  }
}

function assertMatchstickAsset(
  asset: CanvasAssetDocument,
  segments: ReadonlySet<string>,
  playId: string,
): void {
  if (asset.palette === undefined) {
    throw new Error(`matchstick_asset_palette_missing:${playId}/${asset.id}`);
  }
  const expected = buildMatchstickCanvasAsset(asset.id, segments, asset.palette);
  if (canonicalJson(asset) !== canonicalJson(expected)) {
    throw new Error(`matchstick_asset_configuration_mismatch:${playId}/${asset.id}`);
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
  readonly scene?: unknown;
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
