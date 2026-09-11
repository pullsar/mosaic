export const evidenceLensClaimKinds = ['final', 'peak', 'lowest'] as const;

export type EvidenceLensClaimKind = (typeof evidenceLensClaimKinds)[number];

export interface EvidenceLensPoint {
  readonly id: string;
  readonly label: string;
  readonly value: number;
}

export interface EvidenceLensClaim {
  readonly id: string;
  readonly kind: EvidenceLensClaimKind;
  readonly label: string;
}

export interface EvidenceLensSolution {
  readonly answerId: string;
  readonly value: number;
}

/** Derives a claim's one cited point from finite, reviewed series data. */
export function solveEvidenceLens(
  claim: EvidenceLensClaim,
  points: readonly EvidenceLensPoint[],
): EvidenceLensSolution {
  if (!isIdentifier(claim.id) || !evidenceLensClaimKinds.includes(claim.kind)) {
    throw new Error('evidence_lens_claim');
  }
  if (
    points.length < 3 || points.length > 8 ||
    new Set(points.map((point) => point.id)).size !== points.length ||
    points.some((point) => !isIdentifier(point.id) || !isLabel(point.label) || !Number.isFinite(point.value))
  ) throw new Error('evidence_lens_point');

  const point = claim.kind === 'final'
    ? points.at(-1)!
    : uniqueExtreme(points, claim.kind === 'peak' ? Math.max : Math.min);
  const title = claim.kind === 'final' ? 'Final' : claim.kind === 'peak' ? 'Peak' : 'Lowest';
  if (claim.label !== `${title} value: ${point.value}.`) {
    throw new Error('evidence_lens_claim_label');
  }
  return {answerId: point.id, value: point.value};
}

function uniqueExtreme(
  points: readonly EvidenceLensPoint[],
  operation: (...values: number[]) => number,
): EvidenceLensPoint {
  const extreme = operation(...points.map((point) => point.value));
  const matches = points.filter((point) => point.value === extreme);
  if (matches.length !== 1) throw new Error('evidence_lens_ambiguous');
  return matches[0]!;
}

function isIdentifier(value: string): boolean {
  return /^[a-z][a-z0-9_-]{0,39}$/.test(value);
}

function isLabel(value: string): boolean {
  return value.length >= 1 && value.length <= 40 && !/[\r\n]/.test(value);
}