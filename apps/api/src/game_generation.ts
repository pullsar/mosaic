import {createHash} from 'node:crypto';

import {
  enumerateOneMoveMatchstickSolutions,
  matchstickEquationFromSegments,
  matchstickSegmentsForEquation,
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
  readonly themePreference?: string;
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
    drafts.push(Object.freeze({
      family: 'one_move_matchstick',
      generatorVersion,
      sourceEquation: candidate.sourceEquation,
      sourceSegments: candidate.sourceSegments,
      solution: candidate.solution,
      structuralSignature: candidate.structuralSignature,
      canonicalHash,
      media: Object.freeze({
        sourceCanvasAssetId: `draft_matchsticks_${canonicalHash}_source`,
        solvedCanvasAssetId: `draft_matchsticks_${canonicalHash}_solved`,
      }),
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
