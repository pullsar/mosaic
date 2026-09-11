export const secondThoughtChoices = ['north', 'south'] as const;
export const secondThoughtAdvice = [...secondThoughtChoices, 'unsure'] as const;
export type SecondThoughtChoice = (typeof secondThoughtChoices)[number];
export type SecondThoughtAdvice = (typeof secondThoughtAdvice)[number];

export interface SecondThoughtRound {
  readonly initial: SecondThoughtChoice;
  readonly advice: SecondThoughtAdvice;
  readonly evidence: SecondThoughtChoice;
}

export interface SecondThoughtSolution {
  readonly decision: 'keep' | 'change';
  readonly finalChoice: SecondThoughtChoice;
  readonly adviceAgrees: boolean | null;
}

/** Scores the final decision against the stated evidence, never adviser agreement. */
export function solveSecondThought(round: SecondThoughtRound): SecondThoughtSolution {
  if (!secondThoughtChoices.includes(round.initial) ||
      !secondThoughtChoices.includes(round.evidence) ||
      !secondThoughtAdvice.includes(round.advice)) {
    throw new Error('second_thought_round');
  }
  return {
    decision: round.initial === round.evidence ? 'keep' : 'change',
    finalChoice: round.evidence,
    adviceAgrees: round.advice === 'unsure' ? null : round.advice === round.evidence,
  };
}