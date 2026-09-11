export const ruleFlipTrials = ['shape', 'fill'] as const;
export type RuleFlipTrial = (typeof ruleFlipTrials)[number];
export type RuleFlipShape = 'triangle' | 'round';
export type RuleFlipFill = 'solid' | 'striped';

export interface RuleFlipObject {
  readonly shape: RuleFlipShape;
  readonly fill: RuleFlipFill;
}

export interface RuleFlipSolution {
  readonly side: 'left' | 'right';
}

/** Evaluates the frozen rule for one discrete trial; no prior trial state leaks in. */
export function solveRuleFlip(
  trial: RuleFlipTrial,
  object: RuleFlipObject,
): RuleFlipSolution {
  if (!ruleFlipTrials.includes(trial)) throw new Error('rule_flip_trial');
  if (!isShape(object.shape) || !isFill(object.fill)) {
    throw new Error('rule_flip_object');
  }
  return {
    side: trial === 'shape'
      ? object.shape === 'triangle' ? 'left' : 'right'
      : object.fill === 'solid' ? 'left' : 'right',
  };
}

function isShape(value: unknown): value is RuleFlipShape {
  return value === 'triangle' || value === 'round';
}

function isFill(value: unknown): value is RuleFlipFill {
  return value === 'solid' || value === 'striped';
}