/**
 * Reviewed, repository-owned task audio. These files are published through the
 * normal immutable media worker; a Play never points at a third-party URL.
 */
export interface CuratedAudioAsset {
  readonly assetId: string;
  readonly sourcePath: string;
  readonly sourceSha256: string;
  readonly durationMs: number;
}

export const echoArchitectAudioAssets: readonly CuratedAudioAsset[] = [
  {
    assetId: 'mixli_audio_echo_c4_dsharp4_fsharp4',
    sourcePath: 'curated_assets/echo_architect/echo-architect-c4-dsharp4-fsharp4.m4a',
    sourceSha256: 'e2ab27b0c887dd72ca56e6def9a89de2d9561dded46b6759f482119559e27d59',
    durationMs: 2090,
  },
  {
    assetId: 'mixli_audio_echo_fsharp4_c4_dsharp4',
    sourcePath: 'curated_assets/echo_architect/echo-architect-fsharp4-c4-dsharp4.m4a',
    sourceSha256: 'a9be8fabbdd95412877a8ac5fe3918c53dfa27746daabe496ad12e275cfb8d0a',
    durationMs: 2090,
  },
  {
    assetId: 'mixli_audio_echo_dsharp4_fsharp4_c4',
    sourcePath: 'curated_assets/echo_architect/echo-architect-dsharp4-fsharp4-c4.m4a',
    sourceSha256: 'abf1b4e36a78908a5167b77893d430c068ae70dfb7848f50ce4895a1e210404b',
    durationMs: 2090,
  },
  {
    assetId: 'mixli_audio_echo_c4_fsharp4_dsharp4',
    sourcePath: 'curated_assets/echo_architect/echo-architect-c4-fsharp4-dsharp4.m4a',
    sourceSha256: 'cc9fa7b814910dbe2843daeccc18e7ba0032d2fc257183d2ee45b5965d2e7ac8',
    durationMs: 2090,
  },
  {
    assetId: 'mixli_audio_echo_dsharp4_c4_fsharp4',
    sourcePath: 'curated_assets/echo_architect/echo-architect-dsharp4-c4-fsharp4.m4a',
    sourceSha256: '42cb4c59f1df024a4d53c41724982158de0ec8708bf5f02dfa52d5bb69041304',
    durationMs: 2090,
  },
  {
    assetId: 'mixli_audio_echo_fsharp4_dsharp4_c4',
    sourcePath: 'curated_assets/echo_architect/echo-architect-fsharp4-dsharp4-c4.m4a',
    sourceSha256: '2563ac0372766393e4cae30866c30beede3e992ba2ba2b09ccea3b78bb073bf4',
    durationMs: 2090,
  },
];

export function curatedAudioAsset(assetId: string): CuratedAudioAsset | undefined {
  return echoArchitectAudioAssets.find((asset) => asset.assetId === assetId);
}
