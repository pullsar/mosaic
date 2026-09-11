import {createHash} from 'node:crypto';

import type {CanvasAssetDocument, CanvasElement, CanvasPalette} from './canvas_asset.js';
import type {EditorialDraft} from './game_editorial.js';
import {
  enumerateOneMoveMatchstickSolutions,
  knownMatchstickSegments,
  matchstickEquationFromSegments,
  matchstickSegmentsForEquation,
  oneMoveMatchstickSolverVersion,
  type MatchstickMoveSolution,
} from './game_solvers.js';

const generatorVersion = 'one-move-matchstick-v1';
const maximumDrafts = 24;
const maximumCandidateChecksPerDraft = 200;

export interface OneMoveGenerationRequest {
  readonly seed: number;
  readonly count: number;
  readonly themePreference?: string;
}

export interface OneMoveMatchstickDraft {
  readonly family: 'one_move_matchstick';
  readonly generatorVersion: typeof generatorVersion;
  readonly sourceEquation: string;
  readonly sourceSegments: readonly string[];
  readonly solution: MatchstickMoveSolution;
  readonly structuralSignature: string;
  readonly canonicalHash: string;
  readonly media: {
    readonly sourceCanvasAssetId: string;
    readonly solvedCanvasAssetId: string;
  };
  /** Complete local composition for an editor to preview before approval. */
  readonly canvasAssets: readonly CanvasAssetDocument[];
  readonly document: OneMoveDraftDocument;
  /** The exact evidence record that must be approved before publication. */
  readonly editorial: EditorialDraft;
  readonly themePreference?: string;
}

export interface OneMoveDraftDocument {
  readonly schemaVersion: 1;
  readonly id: string;
  readonly revisionId: string;
  readonly format: 'solve';
  readonly classification: 'challenge';
  readonly topics: readonly string[];
  readonly learningTopics: readonly string[];
  readonly estimatedDurationSec: number;
  readonly assets: readonly string[];
  readonly sources: readonly unknown[];
  readonly entryState: 'solve';
  readonly states: Readonly<Record<string, unknown>>;
}

export interface OneMoveGenerationResult {
  readonly seed: number;
  readonly requestedCount: number;
  readonly candidateChecks: number;
  readonly drafts: readonly OneMoveMatchstickDraft[];
  readonly rejectionCounts: Readonly<Record<string, number>>;
}

/**
 * Creates local editorial drafts only. The result contains no eligibility or
 * publication mutation and remains reproducible from its recorded seed.
 */
export function generateOneMoveMatchstickDrafts(
  request: OneMoveGenerationRequest,
): OneMoveGenerationResult {
  validateRequest(request);
  const candidatePool = oneMoveCandidates();
  const random = mulberry32(request.seed);
  const shuffled = [...candidatePool];
  for (let index = shuffled.length - 1; index > 0; index -= 1) {
    const swap = Math.floor(random() * (index + 1));
    [shuffled[index], shuffled[swap]] = [shuffled[swap]!, shuffled[index]!];
  }

  const drafts: OneMoveMatchstickDraft[] = [];
  const signatures = new Set<string>();
  let candidateChecks = 0;
  const rejections: {duplicate_structure: number; exhausted: number} = {
    duplicate_structure: 0,
    exhausted: 0,
  };
  const maximumCandidateChecks = request.count * maximumCandidateChecksPerDraft;
  for (const candidate of shuffled) {
    if (candidateChecks >= maximumCandidateChecks || drafts.length === request.count) break;
    candidateChecks += 1;
    if (!signatures.add(candidate.structuralSignature)) {
      rejections.duplicate_structure += 1;
      continue;
    }
    const canonical = JSON.stringify({
      family: 'one_move_matchstick',
      generatorVersion,
      sourceSegments: candidate.sourceSegments,
      solution: candidate.solution,
    });
    const themePreference = normalizeThemePreference(request.themePreference);
    const canonicalHash = createHash('sha256').update(canonical).digest('hex');
    const renderable = buildRenderableDraft(candidate, canonicalHash);
    drafts.push(Object.freeze({
      family: 'one_move_matchstick',
      generatorVersion,
      sourceEquation: candidate.sourceEquation,
      sourceSegments: candidate.sourceSegments,
      solution: candidate.solution,
      structuralSignature: candidate.structuralSignature,
      canonicalHash,
      ...renderable,
      ...(themePreference === undefined ? {} : {themePreference}),
    }));
  }
  if (drafts.length < request.count) rejections.exhausted = request.count - drafts.length;
  return Object.freeze({
    seed: request.seed,
    requestedCount: request.count,
    candidateChecks,
    drafts: Object.freeze(drafts),
    rejectionCounts: Object.freeze(rejections),
  });
}

const draftMatchstickPalette: CanvasPalette = Object.freeze({
  background: '#FFF7ED',
  foreground: '#5D2518',
  accent: '#C9783E',
  muted: '#7C6253',
  surface: '#F4E4D4',
});

function buildRenderableDraft(
  candidate: Candidate,
  canonicalHash: string,
): Pick<OneMoveMatchstickDraft, 'media' | 'canvasAssets' | 'document' | 'editorial'> {
  const media = Object.freeze({
    sourceCanvasAssetId: `draft_matchsticks_${canonicalHash}_source`,
    solvedCanvasAssetId: `draft_matchsticks_${canonicalHash}_solved`,
  });
  const staticSource = new Set(candidate.sourceSegments);
  staticSource.delete(candidate.solution.from);
  const solved = new Set(staticSource);
  solved.add(candidate.solution.to);
  const sourceAsset = buildDraftMatchstickCanvas(
    media.sourceCanvasAssetId,
    staticSource,
    'An incomplete matchstick equation.',
  );
  const solvedAsset = buildDraftMatchstickCanvas(
    media.solvedCanvasAssetId,
    solved,
    'A solved matchstick equation.',
  );
  const pieceId = `match_${candidate.solution.from.replace('.', '_')}`;
  const targetSegments = [
    candidate.solution.to,
    ...knownMatchstickSegments.filter(
      (segment) =>
        !staticSource.has(segment) &&
        segment !== candidate.solution.to &&
        segment !== candidate.solution.from,
    ),
  ].slice(0, 3);
  const destinations = targetSegments.map((segment, index) => Object.freeze({
    id: index === 0 ? 'solution' : `option_${index}`,
    segment,
  }));
  const documentId = `draft_one_move_${canonicalHash}`;
  const document: OneMoveDraftDocument = Object.freeze({
    schemaVersion: 1,
    id: documentId,
    revisionId: `draft_${canonicalHash.slice(0, 12)}`,
    format: 'solve',
    classification: 'challenge',
    topics: Object.freeze(['puzzles', 'logic']),
    learningTopics: Object.freeze([]),
    estimatedDurationSec: 20,
    assets: Object.freeze([media.sourceCanvasAssetId, media.solvedCanvasAssetId]),
    sources: Object.freeze([]),
    entryState: 'solve',
    states: Object.freeze({
      solve: Object.freeze({
        presentation: Object.freeze({
          layers: Object.freeze([
            Object.freeze({type: 'canvas', role: 'media', assetId: media.sourceCanvasAssetId}),
            Object.freeze({
              type: 'scene',
              role: 'media',
              scene: Object.freeze({
                version: 1,
                objects: Object.freeze([
                  Object.freeze({
                    id: pieceId,
                    semanticLabel: 'Match',
                    shape: 'matchstick',
                    ...matchstickSceneLocation(candidate.solution.from),
                    tone: 'accent',
                    movable: true,
                  }),
                ]),
                targets: Object.freeze(destinations.map((destination) => Object.freeze({
                  id: destination.id,
                  semanticLabel: 'Open space',
                  ...matchstickSceneLocation(destination.segment),
                }))),
              }),
            }),
            Object.freeze({type: 'text', role: 'prompt', value: 'Move one match.'}),
          ]),
        }),
        input: Object.freeze({type: 'piece_move'}),
        validation: Object.freeze({
          type: 'legal_piece_move',
          value: Object.freeze(destinations.map((destination) => Object.freeze({
            pieceId,
            targetId: destination.id,
            correct: destination.segment === candidate.solution.to,
          }))),
        }),
        transition: Object.freeze({correct: 'reveal', incorrect: 'solve'}),
      }),
      reveal: Object.freeze({
        presentation: Object.freeze({
          layers: Object.freeze([
            Object.freeze({type: 'canvas', role: 'media', assetId: media.solvedCanvasAssetId}),
            Object.freeze({
              type: 'text',
              role: 'reveal_title',
              value: `${candidate.solution.equation}. One match changes sides.`,
            }),
          ]),
        }),
        input: Object.freeze({type: 'tap', label: 'Done'}),
        validation: Object.freeze({type: 'none'}),
        transition: Object.freeze({default: '$end'}),
      }),
    }),
  });
  return Object.freeze({
    media,
    canvasAssets: Object.freeze([sourceAsset, solvedAsset]),
    document,
    editorial: Object.freeze({
      draftHash: canonicalHash,
      generatorVersion,
      solverVersion: oneMoveMatchstickSolverVersion,
      structuralSignature: candidate.structuralSignature,
      mediaAssetIds: Object.freeze([media.sourceCanvasAssetId, media.solvedCanvasAssetId]),
    }),
  });
}

function buildDraftMatchstickCanvas(
  id: string,
  occupied: ReadonlySet<string>,
  semanticLabel: string,
): CanvasAssetDocument {
  const elements = [...occupied]
    .sort()
    .map((segment) => matchstickCanvasLine(segment));
  elements.push(
    {type: 'line', x1: 0.62, y1: 0.47, x2: 0.7, y2: 0.47, width: 0.016, cap: 'round', tone: 'foreground'},
    {type: 'line', x1: 0.62, y1: 0.53, x2: 0.7, y2: 0.53, width: 0.016, cap: 'round', tone: 'foreground'},
  );
  return Object.freeze({
    schemaVersion: 1,
    id,
    semanticLabel,
    elements: Object.freeze(elements),
    palette: draftMatchstickPalette,
  });
}

function matchstickCanvasLine(segment: string): CanvasElement {
  const [slot, part] = segment.split('.');
  const center = ({left: 0.16, right: 0.5, result: 0.82} as const)[slot ?? ''];
  const line = (x1: number, y1: number, x2: number, y2: number): CanvasElement => ({
    type: 'line', x1, y1, x2, y2, width: 0.016, cap: 'round', tone: 'foreground',
  });
  if (slot === 'operator' && part === 'horizontal') return line(0.3, 0.5, 0.38, 0.5);
  if (slot === 'operator' && part === 'vertical') return line(0.34, 0.43, 0.34, 0.57);
  if (center === undefined) throw new Error(`unknown_matchstick_segment:${segment}`);
  if (part === 'a') return line(center - 0.055, 0.36, center + 0.055, 0.36);
  if (part === 'b') return line(center + 0.055, 0.36, center + 0.055, 0.5);
  if (part === 'c') return line(center + 0.055, 0.5, center + 0.055, 0.64);
  if (part === 'd') return line(center - 0.055, 0.64, center + 0.055, 0.64);
  if (part === 'e') return line(center - 0.055, 0.5, center - 0.055, 0.64);
  if (part === 'f') return line(center - 0.055, 0.36, center - 0.055, 0.5);
  if (part === 'g') return line(center - 0.055, 0.5, center + 0.055, 0.5);
  throw new Error(`unknown_matchstick_segment:${segment}`);
}

function matchstickSceneLocation(segment: string): Record<string, number> {
  const [slot, part] = segment.split('.');
  if (slot === 'operator') {
    if (part === 'horizontal') return {x: 0.29, y: 0.485, width: 0.1, height: 0.03};
    if (part === 'vertical') return {x: 0.325, y: 0.43, width: 0.03, height: 0.14};
    throw new Error(`unknown_matchstick_segment:${segment}`);
  }
  const center = ({left: 0.16, right: 0.5, result: 0.82} as const)[slot ?? ''];
  if (center === undefined) throw new Error(`unknown_matchstick_segment:${segment}`);
  if (part === 'a') return {x: center - 0.07, y: 0.345, width: 0.14, height: 0.03};
  if (part === 'b') return {x: center + 0.04, y: 0.36, width: 0.03, height: 0.14};
  if (part === 'c') return {x: center + 0.04, y: 0.5, width: 0.03, height: 0.14};
  if (part === 'd') return {x: center - 0.07, y: 0.625, width: 0.14, height: 0.03};
  if (part === 'e') return {x: center - 0.07, y: 0.5, width: 0.03, height: 0.14};
  if (part === 'f') return {x: center - 0.07, y: 0.36, width: 0.03, height: 0.14};
  if (part === 'g') return {x: center - 0.07, y: 0.485, width: 0.14, height: 0.03};
  throw new Error(`unknown_matchstick_segment:${segment}`);
}

interface Candidate {
  readonly sourceEquation: string;
  readonly sourceSegments: readonly string[];
  readonly solution: MatchstickMoveSolution;
  readonly structuralSignature: string;
}

let cachedCandidates: readonly Candidate[] | undefined;

function oneMoveCandidates(): readonly Candidate[] {
  const cached = cachedCandidates;
  if (cached !== undefined) return cached;
  const candidates: Candidate[] = [];
  for (let left = 0; left <= 9; left += 1) {
    for (const operator of ['+', '-'] as const) {
      for (let right = 0; right <= 9; right += 1) {
        for (let result = 0; result <= 9; result += 1) {
          const source = matchstickSegmentsForEquation(
            String(left), operator, String(right), String(result),
          );
          const sourceEquation = matchstickEquationFromSegments(source);
          if (sourceEquation === null) throw new Error('generated source is not renderable');
          const solutions = enumerateOneMoveMatchstickSolutions(source);
          if (solutions.length !== 1) continue;
          const solution = solutions[0]!;
          const sourceSegments = Object.freeze([...source].sort());
          candidates.push(Object.freeze({
            sourceEquation,
            sourceSegments,
            solution,
            structuralSignature: `${sourceSegments.join(',')}|${solution.from}>${solution.to}`,
          }));
        }
      }
    }
  }
  const generated = Object.freeze(candidates.sort((left, right) =>
    left.structuralSignature.localeCompare(right.structuralSignature),
  ));
  cachedCandidates = generated;
  return generated;
}

function validateRequest(request: OneMoveGenerationRequest): void {
  if (!Number.isInteger(request.seed) || request.seed < 0 || request.seed > 0xffffffff) {
    throw new RangeError('seed must be an unsigned 32-bit integer');
  }
  if (!Number.isInteger(request.count) || request.count < 1 || request.count > maximumDrafts) {
    throw new RangeError(`count must be an integer from 1 to ${maximumDrafts}`);
  }
  normalizeThemePreference(request.themePreference);
}

function normalizeThemePreference(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const normalized = value.trim();
  if (normalized.length === 0 || normalized.length > 200) {
    throw new RangeError('themePreference must be 1 to 200 characters');
  }
  return normalized;
}

function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}
