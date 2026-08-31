export interface ClientCapabilities {
  schemaVersions: number[];
  presentationTypes: string[];
  inputTypes: string[];
  validatorTypes: string[];
  platformFlags: string[];
}

export interface CompatibilityDecision {
  compatible: boolean;
  reason?: 'malformed' | 'unsupported_schema' | 'unsupported_capability';
  missing: string[];
}

const MAX_CAPABILITY_VALUES = 256;
const MAX_CAPABILITY_TEXT_LENGTH = 100;

export function parseClientCapabilities(value: unknown): ClientCapabilities | null {
  if (!isRecord(value)) return null;
  const schemaVersions = integerArray(value.schemaVersions);
  const presentationTypes = textArray(value.presentationTypes);
  const inputTypes = textArray(value.inputTypes);
  const validatorTypes = textArray(value.validatorTypes);
  const platformFlags = textArray(value.platformFlags);
  if (
    schemaVersions === null ||
    presentationTypes === null ||
    inputTypes === null ||
    validatorTypes === null ||
    platformFlags === null
  ) {
    return null;
  }
  return {
    schemaVersions,
    presentationTypes,
    inputTypes,
    validatorTypes,
    platformFlags,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function integerArray(value: unknown): number[] | null {
  if (
    !Array.isArray(value) ||
    value.length > MAX_CAPABILITY_VALUES ||
    value.some((item) => !Number.isSafeInteger(item) || (item as number) < 1)
  ) {
    return null;
  }
  return [...new Set(value as number[])].sort((left, right) => left - right);
}

function textArray(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.length > MAX_CAPABILITY_VALUES) return null;
  const normalized: string[] = [];
  for (const item of value) {
    if (typeof item !== 'string') return null;
    const text = item.trim();
    if (text.length === 0 || text.length > MAX_CAPABILITY_TEXT_LENGTH) return null;
    normalized.push(text);
  }
  return [...new Set(normalized)].sort();
}

function stringSet(value: unknown): Set<string> | null {
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) return null;
  return new Set(value as string[]);
}

export function checkPlayCompatibility(
  raw: unknown,
  capabilities: ClientCapabilities,
): CompatibilityDecision {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return {compatible: false, reason: 'malformed', missing: []};
  }
  const play = raw as Record<string, unknown>;
  const schemaVersion = play.schemaVersion;
  const states = play.states;
  if (
    !Number.isInteger(schemaVersion) ||
    !states ||
    typeof states !== 'object' ||
    Array.isArray(states)
  ) {
    return {compatible: false, reason: 'malformed', missing: []};
  }

  if (!capabilities.schemaVersions.includes(schemaVersion as number)) {
    return {
      compatible: false,
      reason: 'unsupported_schema',
      missing: [`schema:${schemaVersion}`],
    };
  }

  const requiredFlags =
    play.requiredPlatformFlags === undefined
      ? new Set<string>()
      : stringSet(play.requiredPlatformFlags);
  if (requiredFlags === null) {
    return {compatible: false, reason: 'malformed', missing: []};
  }

  const requiredPresentation = new Set<string>();
  const requiredInputs = new Set<string>();
  const requiredValidators = new Set<string>();

  for (const value of Object.values(states as Record<string, unknown>)) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      return {compatible: false, reason: 'malformed', missing: []};
    }
    const state = value as Record<string, unknown>;
    const presentation = state.presentation;
    const input = state.input;
    const validation = state.validation;
    if (
      !presentation ||
      typeof presentation !== 'object' ||
      Array.isArray(presentation) ||
      !input ||
      typeof input !== 'object' ||
      Array.isArray(input) ||
      !validation ||
      typeof validation !== 'object' ||
      Array.isArray(validation)
    ) {
      return {compatible: false, reason: 'malformed', missing: []};
    }

    const layers = (presentation as Record<string, unknown>).layers;
    if (!Array.isArray(layers)) return {compatible: false, reason: 'malformed', missing: []};
    for (const layer of layers) {
      if (!layer || typeof layer !== 'object' || Array.isArray(layer)) {
        return {compatible: false, reason: 'malformed', missing: []};
      }
      const type = (layer as Record<string, unknown>).type;
      if (typeof type !== 'string' || type.length === 0) {
        return {compatible: false, reason: 'malformed', missing: []};
      }
      requiredPresentation.add(type);
    }

    const inputType = (input as Record<string, unknown>).type;
    const validatorType = (validation as Record<string, unknown>).type;
    if (typeof inputType !== 'string' || typeof validatorType !== 'string') {
      return {compatible: false, reason: 'malformed', missing: []};
    }
    requiredInputs.add(inputType);
    requiredValidators.add(validatorType);
  }

  const missing: string[] = [];
  for (const type of requiredPresentation) {
    if (!capabilities.presentationTypes.includes(type)) missing.push(`presentation:${type}`);
  }
  for (const type of requiredInputs) {
    if (!capabilities.inputTypes.includes(type)) missing.push(`input:${type}`);
  }
  for (const type of requiredValidators) {
    if (!capabilities.validatorTypes.includes(type)) missing.push(`validator:${type}`);
  }
  for (const flag of requiredFlags) {
    if (!capabilities.platformFlags.includes(flag)) missing.push(`platform:${flag}`);
  }

  missing.sort();
  return missing.length === 0
    ? {compatible: true, missing: []}
    : {compatible: false, reason: 'unsupported_capability', missing};
}
