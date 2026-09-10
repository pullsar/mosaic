import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  assertProductionCatalogIntegrity,
  moveSegment,
} from '../src/catalog_integrity.js';
import {productionCatalogIntegrityFixture} from '../src/production_catalog.js';

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
