import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

const _minimumStageAspectRatio = 3 / 4;
const _maximumStageAspectRatio = 16 / 9;
const _minimumUsableRailStage = Size(320, 240);
const _minimumCompactLandscapeStage = Size(300, 168);

typedef _ViewportCase = ({
  String name,
  Size viewport,
  EdgeInsets safeInsets,
  String expectedUtilityPlacement,
});

const _viewportCases = <_ViewportCase>[
  (
    name: 'small phone portrait',
    viewport: Size(320, 640),
    safeInsets: EdgeInsets.only(top: 24, bottom: 20),
    expectedUtilityPlacement: 'horizontalDock',
  ),
  (
    name: 'modern phone portrait',
    viewport: Size(390, 844),
    safeInsets: EdgeInsets.only(top: 47, bottom: 34),
    expectedUtilityPlacement: 'horizontalDock',
  ),
  (
    name: 'compact phone landscape',
    viewport: Size(844, 390),
    safeInsets: EdgeInsets.fromLTRB(44, 0, 44, 21),
    expectedUtilityPlacement: 'horizontalDock',
  ),
  (
    name: 'tablet portrait',
    viewport: Size(768, 1024),
    safeInsets: EdgeInsets.only(top: 24, bottom: 20),
    expectedUtilityPlacement: 'trailingRail',
  ),
  (
    name: 'desktop landscape',
    viewport: Size(1440, 900),
    safeInsets: EdgeInsets.fromLTRB(16, 12, 16, 12),
    expectedUtilityPlacement: 'trailingRail',
  ),
];

void main() {
  group('PlayViewportComposition.fromConstraints', () {
    for (final viewportCase in _viewportCases) {
      test('${viewportCase.name} keeps every region usable and in bounds', () {
        final composition = PlayViewportComposition.fromConstraints(
          BoxConstraints.tight(viewportCase.viewport),
          safeInsets: viewportCase.safeInsets,
        );
        final expectedViewport = Offset.zero & viewportCase.viewport;
        final expectedSafeRect = Rect.fromLTRB(
          viewportCase.safeInsets.left,
          viewportCase.safeInsets.top,
          viewportCase.viewport.width - viewportCase.safeInsets.right,
          viewportCase.viewport.height - viewportCase.safeInsets.bottom,
        );

        expect(composition.viewportRect, expectedViewport);
        expect(composition.safeRect, expectedSafeRect);
        expect(composition.reservedRegions, contains(composition.stageRect));
        expect(composition.reservedRegions, contains(composition.utilityRect));

        final allRects = <Rect>[
          composition.safeRect,
          ...composition.reservedRegions,
        ];
        for (final rect in allRects) {
          expect(rect.left, greaterThanOrEqualTo(expectedViewport.left));
          expect(rect.top, greaterThanOrEqualTo(expectedViewport.top));
          expect(rect.width, greaterThanOrEqualTo(0));
          expect(rect.height, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(expectedViewport.right));
          expect(rect.bottom, lessThanOrEqualTo(expectedViewport.bottom));
        }
        for (final region in composition.reservedRegions) {
          expect(
            _containsRect(composition.safeRect, region),
            isTrue,
            reason: '$region must respect ${composition.safeRect}',
          );
        }

        _expectReadingOrder(composition.reservedRegions);
        _expectPairwiseNonOverlapping(composition.reservedRegions);

        final stageAspect =
            composition.stageRect.width / composition.stageRect.height;
        expect(stageAspect, greaterThanOrEqualTo(_minimumStageAspectRatio));
        expect(
          stageAspect,
          lessThanOrEqualTo(_maximumStageAspectRatio + precisionErrorTolerance),
        );
      });
    }

    test('adapts utility placement without sacrificing the stage', () {
      for (final viewportCase in _viewportCases) {
        final composition = PlayViewportComposition.fromConstraints(
          BoxConstraints.tight(viewportCase.viewport),
          safeInsets: viewportCase.safeInsets,
        );

        expect(
          composition.utilityPlacement.name,
          viewportCase.expectedUtilityPlacement,
          reason: viewportCase.name,
        );
        if (composition.utilityPlacement.name == 'horizontalDock') {
          expect(
            composition.utilityRect.width,
            greaterThan(composition.utilityRect.height),
            reason: '${viewportCase.name} must expose utilities horizontally',
          );
        } else {
          expect(
            composition.utilityRect.height,
            greaterThan(composition.utilityRect.width),
            reason: '${viewportCase.name} must expose utilities as a rail',
          );
          expect(
            composition.stageRect.width,
            greaterThanOrEqualTo(_minimumUsableRailStage.width),
          );
          expect(
            composition.stageRect.height,
            greaterThanOrEqualTo(_minimumUsableRailStage.height),
          );
        }
      }
    });

    test('publishes an immutable reserved-region snapshot', () {
      final composition = PlayViewportComposition.fromConstraints(
        const BoxConstraints.tightFor(width: 390, height: 844),
        safeInsets: const EdgeInsets.only(top: 47, bottom: 34),
      );

      expect(
        () => composition.reservedRegions.add(Rect.zero),
        throwsUnsupportedError,
      );
    });

    group('rejects invalid geometry', () {
      final invalidCases =
          <({String name, BoxConstraints constraints, EdgeInsets safeInsets})>[
        (
          name: 'unbounded width',
          constraints: const BoxConstraints(
            maxWidth: double.infinity,
            maxHeight: 640,
          ),
          safeInsets: EdgeInsets.zero,
        ),
        (
          name: 'negative inset',
          constraints: const BoxConstraints.tightFor(
            width: 320,
            height: 640,
          ),
          safeInsets: const EdgeInsets.only(left: -1),
        ),
        (
          name: 'non-finite inset',
          constraints: const BoxConstraints.tightFor(
            width: 320,
            height: 640,
          ),
          safeInsets: const EdgeInsets.only(top: double.infinity),
        ),
        (
          name: 'horizontal insets exceed the viewport',
          constraints: const BoxConstraints.tightFor(
            width: 320,
            height: 640,
          ),
          safeInsets: const EdgeInsets.symmetric(horizontal: 161),
        ),
        (
          name: 'vertical insets exceed the viewport',
          constraints: const BoxConstraints.tightFor(
            width: 320,
            height: 640,
          ),
          safeInsets: const EdgeInsets.symmetric(vertical: 321),
        ),
      ];

      for (final invalidCase in invalidCases) {
        test('${invalidCase.name} with ArgumentError', () {
          expect(
            () => PlayViewportComposition.fromConstraints(
              invalidCase.constraints,
              safeInsets: invalidCase.safeInsets,
            ),
            throwsA(isA<ArgumentError>()),
          );
        });
      }
    });

    test('compact landscape preserves a usable contextual stage', () {
      final composition = PlayViewportComposition.fromConstraints(
        const BoxConstraints.tightFor(width: 844, height: 390),
        safeInsets: const EdgeInsets.fromLTRB(44, 0, 44, 21),
      );

      expect(composition.utilityPlacement, PlayUtilityPlacement.horizontalDock);
      expect(
        composition.stageRect.width,
        greaterThanOrEqualTo(_minimumCompactLandscapeStage.width),
      );
      expect(
        composition.stageRect.height,
        greaterThanOrEqualTo(_minimumCompactLandscapeStage.height),
      );
      expect(composition.stageRect.overlaps(composition.inputRect), isFalse);
    });

    test('2x text remains usable across reference viewports', () {
      for (final viewportCase in _viewportCases) {
        final composition = _compositionWithTextScaler(
          viewportCase.viewport,
          safeInsets: viewportCase.safeInsets,
          textScaler: const TextScaler.linear(2),
        );

        _expectRegionsInBounds(composition);
        _expectReadingOrder(composition.reservedRegions);
        _expectPairwiseNonOverlapping(composition.reservedRegions);
        if (viewportCase.viewport.height > viewportCase.viewport.width) {
          expect(composition.promptRect.height, greaterThanOrEqualTo(96));
          expect(composition.inputRect.height, greaterThanOrEqualTo(96));
          expect(composition.navigationRect.height, greaterThanOrEqualTo(72));
        }
        if (viewportCase.name == 'compact phone landscape') {
          expect(
            composition.stageRect.width,
            greaterThanOrEqualTo(_minimumCompactLandscapeStage.width),
          );
          expect(
            composition.stageRect.height,
            greaterThanOrEqualTo(_minimumCompactLandscapeStage.height),
          );
        }
        final stageAspect =
            composition.stageRect.width / composition.stageRect.height;
        expect(stageAspect, greaterThanOrEqualTo(_minimumStageAspectRatio));
        expect(
          stageAspect,
          lessThanOrEqualTo(_maximumStageAspectRatio + precisionErrorTolerance),
        );
      }
    });

    test('desktop caps and centers the stage and utility group', () {
      final composition = PlayViewportComposition.fromConstraints(
        const BoxConstraints.tightFor(width: 1440, height: 900),
        safeInsets: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      );
      final stageAndUtility = composition.stageRect.expandToInclude(
        composition.utilityRect,
      );

      expect(composition.stageRect.width, lessThanOrEqualTo(720));
      expect(
        stageAndUtility.center.dx,
        closeTo(composition.safeRect.center.dx, 0.001),
      );
    });

    test('tall fitted stage centers while lower regions stay anchored', () {
      final composition = PlayViewportComposition.fromConstraints(
        const BoxConstraints.tightFor(width: 320, height: 900),
        safeInsets: const EdgeInsets.only(top: 24, bottom: 34),
      );
      final stageAllotment = Rect.fromLTRB(
        composition.safeRect.left,
        composition.promptRect.bottom,
        composition.safeRect.right,
        composition.safeRect.bottom -
            composition.inputRect.height -
            composition.utilityRect.height -
            composition.navigationRect.height,
      );

      expect(
        composition.stageRect.center.dx,
        closeTo(stageAllotment.center.dx, 0.001),
      );
      expect(
        composition.stageRect.center.dy,
        closeTo(stageAllotment.center.dy, 0.001),
      );
      expect(composition.inputRect.bottom, composition.utilityRect.top);
      expect(composition.utilityRect.bottom, composition.navigationRect.top);
      expect(composition.navigationRect.bottom, composition.safeRect.bottom);
    });
  });
}

PlayViewportComposition _compositionWithTextScaler(
  Size viewport, {
  required EdgeInsets safeInsets,
  required TextScaler textScaler,
}) {
  final dynamic factory = PlayViewportComposition.fromConstraints;
  final result = factory(
    BoxConstraints.tight(viewport),
    safeInsets: safeInsets,
    textScaler: textScaler,
  );
  return result as PlayViewportComposition;
}

void _expectRegionsInBounds(PlayViewportComposition composition) {
  for (final region in composition.reservedRegions) {
    expect(region.left, greaterThanOrEqualTo(composition.safeRect.left));
    expect(region.top, greaterThanOrEqualTo(composition.safeRect.top));
    expect(region.right, lessThanOrEqualTo(composition.safeRect.right));
    expect(region.bottom, lessThanOrEqualTo(composition.safeRect.bottom));
  }
}

bool _containsRect(Rect outer, Rect inner) =>
    inner.left >= outer.left &&
    inner.top >= outer.top &&
    inner.right <= outer.right &&
    inner.bottom <= outer.bottom;

void _expectReadingOrder(List<Rect> regions) {
  for (var index = 1; index < regions.length; index += 1) {
    final previous = regions[index - 1];
    final current = regions[index];
    expect(
      current.top > previous.top ||
          (current.top == previous.top && current.left >= previous.left),
      isTrue,
      reason: '$current must follow $previous in top-to-bottom reading order',
    );
  }
}

void _expectPairwiseNonOverlapping(List<Rect> regions) {
  for (var leftIndex = 0; leftIndex < regions.length; leftIndex += 1) {
    for (
      var rightIndex = leftIndex + 1;
      rightIndex < regions.length;
      rightIndex += 1
    ) {
      expect(
        regions[leftIndex].overlaps(regions[rightIndex]),
        isFalse,
        reason: '${regions[leftIndex]} must not overlap ${regions[rightIndex]}',
      );
    }
  }
}
