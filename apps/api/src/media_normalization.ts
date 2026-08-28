import {
  normalizeMediaDerivativePlan,
  type CanonicalJsonValue,
  type MediaDerivativePlan,
} from './media.js';

export type SpeechImportance = 'none' | 'incidental' | 'material';
export type VerifiedDynamicRange = 'sdr' | 'hdr';
export type VerifiedRotationDegrees = 0 | 90 | 180 | 270;

export interface VerifiedVideoSourceMetadata {
  kind: 'video';
  width: number;
  height: number;
  durationMs: number;
  videoCodec: string;
  videoProfile?: string;
  dynamicRange: VerifiedDynamicRange;
  colorSpace?: string;
  variableFrameRate: boolean;
  nominalFrameRate?: number;
  rotationDegrees: VerifiedRotationDegrees;
  hasAudio: boolean;
  audioCodec?: string;
  audioSampleRateHz?: number;
  audioChannels?: number;
  speech: SpeechImportance;
  languageTag?: string;
}

export interface VerifiedAudioSourceMetadata {
  kind: 'audio';
  durationMs: number;
  audioCodec: string;
  sampleRateHz: number;
  channels: number;
  speech: SpeechImportance;
  languageTag?: string;
}

export type VerifiedMediaSourceMetadata =
  | VerifiedVideoSourceMetadata
  | VerifiedAudioSourceMetadata;

export const MEDIA_NORMALIZATION_POLICY_VERSION = 1;

const PLAYBACK_PROCESSOR = 'ffmpeg-video-normalize-v1';
const POSTER_PROCESSOR = 'ffmpeg-poster-v1';
const AUDIO_PROCESSOR = 'ffmpeg-audio-normalize-v1';
const CAPTIONS_PROCESSOR = 'speech-transcript-v1';

export function planMediaNormalization(
  source: VerifiedMediaSourceMetadata,
): readonly MediaDerivativePlan[] {
  return source.kind === 'video'
    ? planVideoNormalization(normalizeVideoSource(source))
    : planAudioNormalization(normalizeAudioSource(source));
}

function planVideoNormalization(
  source: NormalizedVideoSource,
): readonly MediaDerivativePlan[] {
  const sourceTraits: Record<string, CanonicalJsonValue> = {
    width: source.width,
    height: source.height,
    durationMs: source.durationMs,
    videoCodec: source.videoCodec,
    dynamicRange: source.dynamicRange,
    variableFrameRate: source.variableFrameRate,
    rotationDegrees: source.rotationDegrees,
    hasAudio: source.hasAudio,
  };
  if (source.videoProfile !== null) sourceTraits.videoProfile = source.videoProfile;
  if (source.colorSpace !== null) sourceTraits.colorSpace = source.colorSpace;
  if (source.nominalFrameRate !== null) sourceTraits.nominalFrameRate = source.nominalFrameRate;
  if (source.audioCodec !== null) sourceTraits.audioCodec = source.audioCodec;
  if (source.audioSampleRateHz !== null) sourceTraits.audioSampleRateHz = source.audioSampleRateHz;
  if (source.audioChannels !== null) sourceTraits.audioChannels = source.audioChannels;

  const playback = normalizedPlan({
    version: MEDIA_NORMALIZATION_POLICY_VERSION,
    purpose: 'playback',
    processor: PLAYBACK_PROCESSOR,
    parameters: {
      source: sourceTraits,
      output: {
        container: 'mp4',
        videoCodec: 'h264',
        videoProfile: 'main',
        pixelFormat: 'yuv420p',
        dynamicRange: 'sdr',
        colorSpace: 'bt709',
        frameRateMode: 'cfr',
        maxFps: 30,
        maxLongEdge: 1920,
        maxShortEdge: 1080,
        evenDimensions: true,
        orientation: 'pixels-normalized',
        fastStart: true,
        audio: source.hasAudio
          ? {
              codec: 'aac',
              profile: 'lc',
              sampleRateHz: 48000,
              maxChannels: 2,
            }
          : null,
      },
    },
  });

  const poster = normalizedPlan({
    version: MEDIA_NORMALIZATION_POLICY_VERSION,
    purpose: 'poster',
    processor: POSTER_PROCESSOR,
    parameters: {
      source: {
        durationMs: source.durationMs,
        rotationDegrees: source.rotationDegrees,
        dynamicRange: source.dynamicRange,
        ...(source.colorSpace === null ? {} : {colorSpace: source.colorSpace}),
      },
      output: {
        format: 'jpeg',
        quality: 82,
        dynamicRange: 'sdr',
        colorSpace: 'srgb',
        maxLongEdge: 1280,
        evenDimensions: true,
        orientation: 'pixels-normalized',
      },
      timestampMs: posterTimestampMs(source.durationMs),
    },
  });

  const plans: MediaDerivativePlan[] = [playback, poster];
  if (source.speech === 'material') {
    plans.push(captionsPlan({
      durationMs: source.durationMs,
      audioCodec: source.audioCodec ?? 'unknown',
      sampleRateHz: source.audioSampleRateHz,
      channels: source.audioChannels,
      languageTag: source.languageTag,
    }));
  }
  return Object.freeze(plans);
}

function planAudioNormalization(
  source: NormalizedAudioSource,
): readonly MediaDerivativePlan[] {
  const audio = normalizedPlan({
    version: MEDIA_NORMALIZATION_POLICY_VERSION,
    purpose: 'audio',
    processor: AUDIO_PROCESSOR,
    parameters: {
      source: {
        durationMs: source.durationMs,
        audioCodec: source.audioCodec,
        sampleRateHz: source.sampleRateHz,
        channels: source.channels,
      },
      output: {
        container: 'mp4',
        codec: 'aac',
        profile: 'lc',
        sampleRateHz: 48000,
        maxChannels: 2,
        fastStart: true,
      },
    },
  });

  const plans: MediaDerivativePlan[] = [audio];
  if (source.speech === 'material') {
    plans.push(captionsPlan({
      durationMs: source.durationMs,
      audioCodec: source.audioCodec,
      sampleRateHz: source.sampleRateHz,
      channels: source.channels,
      languageTag: source.languageTag,
    }));
  }
  return Object.freeze(plans);
}

interface CaptionSource {
  durationMs: number;
  audioCodec: string;
  sampleRateHz: number | null;
  channels: number | null;
  languageTag: string | null;
}

function captionsPlan(source: CaptionSource): MediaDerivativePlan {
  const sourceTraits: Record<string, CanonicalJsonValue> = {
    durationMs: source.durationMs,
    audioCodec: source.audioCodec,
  };
  if (source.sampleRateHz !== null) sourceTraits.sampleRateHz = source.sampleRateHz;
  if (source.channels !== null) sourceTraits.channels = source.channels;

  return normalizedPlan({
    version: MEDIA_NORMALIZATION_POLICY_VERSION,
    purpose: 'captions',
    processor: CAPTIONS_PROCESSOR,
    parameters: {
      source: sourceTraits,
      output: {
        format: 'webvtt',
        language: source.languageTag ?? 'auto',
      },
    },
  });
}

function normalizedPlan(plan: MediaDerivativePlan): MediaDerivativePlan {
  const normalized = normalizeMediaDerivativePlan(plan);
  return Object.freeze(normalized);
}

interface NormalizedVideoSource {
  width: number;
  height: number;
  durationMs: number;
  videoCodec: string;
  videoProfile: string | null;
  dynamicRange: VerifiedDynamicRange;
  colorSpace: string | null;
  variableFrameRate: boolean;
  nominalFrameRate: number | null;
  rotationDegrees: VerifiedRotationDegrees;
  hasAudio: boolean;
  audioCodec: string | null;
  audioSampleRateHz: number | null;
  audioChannels: number | null;
  speech: SpeechImportance;
  languageTag: string | null;
}

interface NormalizedAudioSource {
  durationMs: number;
  audioCodec: string;
  sampleRateHz: number;
  channels: number;
  speech: SpeechImportance;
  languageTag: string | null;
}

function normalizeVideoSource(source: VerifiedVideoSourceMetadata): NormalizedVideoSource {
  positiveInteger(source.width, 'width');
  positiveInteger(source.height, 'height');
  positiveInteger(source.durationMs, 'durationMs');
  const videoCodec = normalizedToken(source.videoCodec, 'videoCodec');
  const videoProfile = optionalToken(source.videoProfile, 'videoProfile');
  if (source.dynamicRange !== 'sdr' && source.dynamicRange !== 'hdr') {
    throw new TypeError(`Unsupported dynamicRange: ${String(source.dynamicRange)}`);
  }
  const colorSpace = optionalToken(source.colorSpace, 'colorSpace');
  const nominalFrameRate = optionalPositiveFinite(source.nominalFrameRate, 'nominalFrameRate');
  if (![0, 90, 180, 270].includes(source.rotationDegrees)) {
    throw new TypeError(`Unsupported rotationDegrees: ${String(source.rotationDegrees)}`);
  }
  speechImportance(source.speech);
  const languageTag = optionalLanguageTag(source.languageTag);

  let audioCodec: string | null = null;
  let audioSampleRateHz: number | null = null;
  let audioChannels: number | null = null;
  if (source.hasAudio) {
    if (source.audioCodec === undefined || source.audioSampleRateHz === undefined || source.audioChannels === undefined) {
      throw new TypeError('Verified video with audio requires codec, sample rate and channel count');
    }
    audioCodec = normalizedToken(source.audioCodec, 'audioCodec');
    positiveInteger(source.audioSampleRateHz, 'audioSampleRateHz');
    positiveInteger(source.audioChannels, 'audioChannels');
    audioSampleRateHz = source.audioSampleRateHz;
    audioChannels = source.audioChannels;
  } else if (
    source.audioCodec !== undefined ||
    source.audioSampleRateHz !== undefined ||
    source.audioChannels !== undefined ||
    source.speech !== 'none'
  ) {
    throw new TypeError('Silent video cannot carry audio metadata or speech classification');
  }

  return {
    width: source.width,
    height: source.height,
    durationMs: source.durationMs,
    videoCodec,
    videoProfile,
    dynamicRange: source.dynamicRange,
    colorSpace,
    variableFrameRate: source.variableFrameRate,
    nominalFrameRate,
    rotationDegrees: source.rotationDegrees,
    hasAudio: source.hasAudio,
    audioCodec,
    audioSampleRateHz,
    audioChannels,
    speech: source.speech,
    languageTag,
  };
}

function normalizeAudioSource(source: VerifiedAudioSourceMetadata): NormalizedAudioSource {
  positiveInteger(source.durationMs, 'durationMs');
  positiveInteger(source.sampleRateHz, 'sampleRateHz');
  positiveInteger(source.channels, 'channels');
  speechImportance(source.speech);
  return {
    durationMs: source.durationMs,
    audioCodec: normalizedToken(source.audioCodec, 'audioCodec'),
    sampleRateHz: source.sampleRateHz,
    channels: source.channels,
    speech: source.speech,
    languageTag: optionalLanguageTag(source.languageTag),
  };
}

function posterTimestampMs(durationMs: number): number {
  if (durationMs <= 2) return 0;
  const upperBound = Math.max(0, durationMs - 1);
  return Math.min(upperBound, Math.min(2000, Math.max(250, Math.floor(durationMs * 0.2))));
}

function normalizedToken(value: string, name: string): string {
  const normalized = value.trim().toLowerCase();
  if (!normalized) throw new TypeError(`${name} must not be empty`);
  if (!/^[a-z0-9][a-z0-9._+-]{0,63}$/.test(normalized)) {
    throw new TypeError(`${name} contains unsupported characters`);
  }
  return normalized;
}

function optionalToken(value: string | undefined, name: string): string | null {
  return value === undefined ? null : normalizedToken(value, name);
}

function optionalLanguageTag(value: string | undefined): string | null {
  if (value === undefined) return null;
  const normalized = value.trim().toLowerCase();
  if (!/^[a-z]{2,8}(?:-[a-z0-9]{1,8})*$/.test(normalized)) {
    throw new TypeError('languageTag must be a normalized BCP-47-like language tag');
  }
  return normalized;
}

function speechImportance(value: SpeechImportance): void {
  if (value !== 'none' && value !== 'incidental' && value !== 'material') {
    throw new TypeError(`Unsupported speech importance: ${String(value)}`);
  }
}

function positiveInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new TypeError(`${name} must be a positive safe integer`);
  }
}

function optionalPositiveFinite(value: number | undefined, name: string): number | null {
  if (value === undefined) return null;
  if (!Number.isFinite(value) || value <= 0 || value > 1000) {
    throw new TypeError(`${name} must be a positive finite number no greater than 1000`);
  }
  return value;
}
