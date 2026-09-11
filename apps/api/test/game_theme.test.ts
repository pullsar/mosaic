import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  assertGamePresentationCompatible,
  normalizeGameFamilyManifest,
  normalizeGameThemeManifest,
  resolvePresentation,
  uniformIndex,
} from '../src/game_theme.js';

const family = {
  id: 'quiet-switch',
  revisionId: 'family_1',
  playRevisions: [{playId: 'quiet-switch-round', revisionId: 'round_1'}],
  requiredPlatformFlags: ['managed_game_themes'],
  compatibleThemes: [{themeId: 'paper-studio', themeRevisionId: 'theme_1'}],
};

const theme = {
  id: 'paper-studio',
  revisionId: 'theme_1',
  variants: [
    {
      id: 'felt-ivory',
      familyRevisions: [{id: 'quiet-switch', revisionId: 'family_1'}],
      media: [
        {
          assetId: 'paper-studio-bg',
          kind: 'image',
          role: 'background',
          gain: 1,
          durationMs: 0,
        },
        {
          assetId: 'paper-studio-contact',
          kind: 'audio',
          role: 'effect',
          gain: 0.65,
          durationMs: 280,
        },
      ],
      contrastRatio: 4.5,
      targetExclusions: ['warm-orange'],
      suppressMusicAndEffects: false,
    },
  ],
};

test('immutable family and theme manifests validate a compatible presentation', () => {
  const normalizedFamily = normalizeGameFamilyManifest(family);
  const normalizedTheme = normalizeGameThemeManifest(theme);

  assertGamePresentationCompatible(
    {id: 'quiet-switch', revisionId: 'family_1'},
    {themeId: 'paper-studio', themeRevisionId: 'theme_1', variantId: 'felt-ivory'},
    [normalizedFamily],
    [normalizedTheme],
  );
  assert.deepEqual(normalizedTheme.variants[0]?.media.map((media) => media.assetId), [
    'paper-studio-bg',
    'paper-studio-contact',
  ]);
});

test('theme manifests reject direct URLs and unbounded duplicate media identities', () => {
  assert.throws(
    () =>
      normalizeGameThemeManifest({
        ...theme,
        variants: [
          {
            ...theme.variants[0],
            media: [
              {
                assetId: 'https://example.invalid/background.jpg',
                kind: 'image',
                role: 'background',
                gain: 1,
                durationMs: 0,
              },
            ],
          },
        ],
      }),
    /assetId/,
  );
  assert.throws(
    () =>
      normalizeGameThemeManifest({
        ...theme,
        variants: [
          {
            ...theme.variants[0],
            media: [
              {
                assetId: 'paper-studio-bg',
                kind: 'image',
                role: 'background',
                gain: 1,
                durationMs: 0,
              },
              {
                assetId: 'paper-studio-bg',
                kind: 'image',
                role: 'background',
                gain: 1,
                durationMs: 0,
              },
            ],
          },
        ],
      }),
    /unique/,
  );
});

test('an unknown theme revision cannot be presented to a family', () => {
  assert.throws(
    () =>
      assertGamePresentationCompatible(
        {id: 'quiet-switch', revisionId: 'family_1'},
        {themeId: 'paper-studio', themeRevisionId: 'theme_404', variantId: 'felt-ivory'},
        [normalizeGameFamilyManifest(family)],
        [normalizeGameThemeManifest(theme)],
      ),
    /theme_revision_not_found/,
  );
});

test('presentation resolution freezes exact choices and avoids recent packs', () => {
  const candidates = [
    {themeId: 'glass-garden', themeRevisionId: 'theme_1', variantId: 'mineral'},
    {themeId: 'paper-studio', themeRevisionId: 'theme_1', variantId: 'felt-ivory'},
    {themeId: 'paper-studio', themeRevisionId: 'theme_1', variantId: 'felt-coral'},
  ];
  assert.deepEqual(
    resolvePresentation({themeId: 'paper-studio', themeRevisionId: 'theme_1', variantId: 'felt-ivory'}, 'random', candidates, [], () => 0),
    {kind: 'resolved', presentation: candidates[1]},
  );
  assert.deepEqual(
    resolvePresentation(undefined, 'random', candidates, ['paper-studio'], () => 0),
    {kind: 'resolved', presentation: candidates[0]},
  );
  assert.deepEqual(
    resolvePresentation(undefined, 'orbital', candidates, [], () => 0),
    {kind: 'neutral', reason: 'preference_unavailable'},
  );
});

test('uniform selection rejects modulo-biased words', () => {
  const words = [4294967295, 4];
  assert.equal(uniformIndex(3, () => words.shift()!), 1);
});
