import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  assertProductionCatalogIntegrity,
  moveSegment,
} from '../src/catalog_integrity.js';
import {productionCatalogIntegrityFixture} from '../src/production_catalog.js';

test('pattern task has a neutral missing slot and no pre-answer solution', () => {
  const play = productionCatalogIntegrityFixture.plays.find(
    (candidate) => candidate.id === 'mixli_starter_finish_pattern',
  )!;
  const asset = productionCatalogIntegrityFixture.canvasAssets.find(
    (candidate) => candidate.id === (play.document.assets as string[])[0],
  )!;
  assert.equal(asset.elements.filter((element) => element.type === 'circle').length, 2);
  assert.equal(asset.elements.filter((element) => element.type === 'rect').length, 1);
  assert.ok(asset.elements.some((element) => element.type === 'label' && element.text === '?'));
  assert.equal(asset.semanticLabel, 'Circle, square, circle, then a missing shape.');
  for (const shape of asset.elements.filter((element) => element.type !== 'label')) {
    assert.equal(shape.tone, 'accent');
  }
});

test('route candidates have equal visible weight and no answer in semantics', () => {
  const play = productionCatalogIntegrityFixture.plays.find(
    (candidate) => candidate.id === 'mixli_starter_find_orbit',
  )!;
  const asset = productionCatalogIntegrityFixture.canvasAssets.find(
    (candidate) => candidate.id === (play.document.assets as string[])[0],
  )!;
  const paths = asset.elements.filter((element) => element.type === 'line');
  assert.equal(paths.length, 5);
  assert.equal(new Set(paths.map((line) => line.width)).size, 1);
  assert.ok(paths.every((line) => line.tone === 'foreground'));
  assert.equal(
    asset.semanticLabel,
    'Three route candidates: A rises, B stays level, C falls. Start and End are marked.',
  );
  assert.doesNotMatch(asset.semanticLabel ?? '', /coordinates|connects|\d{2}/i);
  for (const route of ['A rises', 'B stays level', 'C falls']) {
    assert.ok(asset.semanticLabel?.includes(route));
  }
  const endpoints = asset.elements.filter((element) => element.type === 'circle');
  assert.equal(endpoints.length, 2);
  const connecting = paths.filter((line) => endpoints.every(
    (point) => (line.x1 === point.x && line.y1 === point.y) ||
      (line.x2 === point.x && line.y2 === point.y),
  ));
  assert.equal(connecting.length, 1);
});

test('pattern reveal fills only the missing slot with the accepted shape', () => {
  const play = productionCatalogIntegrityFixture.plays.find(
    (candidate) => candidate.id === 'mixli_starter_finish_pattern',
  )!;
  const states = play.document.states as Record<string, {
    validation: {value?: string};
    presentation: {layers: Array<{type: string; assetId?: string}>};
  }>;
  assert.equal(states.choice!.validation.value, 'square');
  const entryId = states.choice!.presentation.layers.find((layer) => layer.type === 'canvas')!.assetId;
  const revealId = states.reveal!.presentation.layers.find((layer) => layer.type === 'canvas')!.assetId;
  assert.notEqual(entryId, revealId);
  const before = productionCatalogIntegrityFixture.canvasAssets.find((asset) => asset.id === entryId)!;
  const after = productionCatalogIntegrityFixture.canvasAssets.find((asset) => asset.id === revealId)!;
  assert.deepEqual(after.elements.slice(0, 3), before.elements.slice(0, 3));
  assert.deepEqual(after.palette, before.palette);
  const finalShape = after.elements[3]!;
  assert.equal(finalShape.type, 'rect');
  if (finalShape.type !== 'rect') assert.fail('expected square');
  // Canvas coordinates use a 4:5 stage; equality in normalized coordinates
  // would draw a rectangle, not a square.
  assert.ok(Math.abs(finalShape.width * 4 / 5 - finalShape.height) < 1e-10);
  assert.equal(after.elements.length, 4);
  assert.ok((play.document.assets as string[]).includes(after.id));
});

test('moving a piece preserves count and the original configuration', () => {
  const before = new Set(['a', 'b']);

  assert.deepEqual([...moveSegment(before, 'a', 'c')].sort(), ['b', 'c']);
  assert.deepEqual([...before].sort(), ['a', 'b']);
  assert.throws(() => moveSegment(before, 'missing', 'c'), /invalid_segment_move/);
  assert.throws(() => moveSegment(before, 'a', 'b'), /invalid_segment_move/);
});

test('eligible starter Plays have verified answers and solved artwork', () => {
  assert.doesNotThrow(() =>
    assertProductionCatalogIntegrity(productionCatalogIntegrityFixture),
  );
});

test('matchstick equations must be derived from the occupied segments', () => {
  const reviews = productionCatalogIntegrityFixture.reviews.map((review) =>
    review.kind === 'matchstick'
      ? {...review, sourceEquation: '9 + 4 = 4'}
      : review,
  );

  assert.throws(
    () =>
      assertProductionCatalogIntegrity({
        ...productionCatalogIntegrityFixture,
        reviews,
      }),
    /matchstick_source_equation_mismatch/,
  );
});

test('catalog integrity requires one review for every eligible Play', () => {
  const [_firstReview, ...remainingReviews] = productionCatalogIntegrityFixture.reviews;

  assert.throws(
    () =>
      assertProductionCatalogIntegrity({
        ...productionCatalogIntegrityFixture,
        reviews: remainingReviews,
      }),
    /review_count_mismatch/,
  );
});

test('catalog integrity rejects duplicate eligible Play identities', () => {
  const firstPlay = productionCatalogIntegrityFixture.plays[0];
  assert.ok(firstPlay);

  assert.throws(
    () =>
      assertProductionCatalogIntegrity({
        ...productionCatalogIntegrityFixture,
        plays: [
          firstPlay,
          firstPlay,
          ...productionCatalogIntegrityFixture.plays.slice(2),
        ],
      }),
    /duplicate_play_identity/,
  );
});

test('catalog integrity rejects duplicate review identities', () => {
  const firstReview = productionCatalogIntegrityFixture.reviews[0];
  assert.ok(firstReview);

  assert.throws(
    () =>
      assertProductionCatalogIntegrity({
        ...productionCatalogIntegrityFixture,
        reviews: [
          firstReview,
          firstReview,
          ...productionCatalogIntegrityFixture.reviews.slice(2),
        ],
      }),
    /duplicate_review_identity/,
  );
});
