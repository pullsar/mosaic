import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

const _promptKey = ValueKey<String>('play-prompt');
const _stageKey = ValueKey<String>('play-stage');
const _inputKey = ValueKey<String>('play-input');
const _utilitiesKey = ValueKey<String>('play-utilities-region');

typedef _ViewportCase = ({
  String name,
  Size size,
  EdgeInsets safeInsets,
});

const _viewportCases = <_ViewportCase>[
  (
    name: 'compact phone',
    size: Size(320, 640),
    safeInsets: EdgeInsets.only(top: 24, bottom: 20),
  ),
  (
    name: 'reference phone',
    size: Size(390, 844),
    safeInsets: EdgeInsets.only(top: 47, bottom: 34),
  ),
  (
    name: 'compact landscape',
    size: Size(844, 390),
    safeInsets: EdgeInsets.fromLTRB(44, 0, 44, 21),
  ),
  (
    name: 'tablet portrait',
    size: Size(768, 1024),
    safeInsets: EdgeInsets.only(top: 24, bottom: 20),
  ),
  (
    name: 'desktop',
    size: Size(1440, 900),
    safeInsets: EdgeInsets.fromLTRB(16, 12, 16, 12),
  ),
];

PlayDocument _composedCanvasPlay() => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'composed_canvas',
  'revisionId': 'composed_canvas_rev_1',
  'format': 'solve',
  'classification': 'challenge',
  'topics': ['puzzles'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 8,
  'assets': ['composition_canvas'],
  'sources': <Object>[],
  'entryState': 'solve',
  'states': {
    'solve': {
      'presentation': {
        'layers': [
          {
            'type': 'canvas',
            'role': 'media',
            'assetId': 'composition_canvas',
          },
          {'type': 'text', 'role': 'prompt', 'value': 'Place the match.'},
        ],
      },
      'input': {
        'type': 'single_choice',
        'options': [
          {'id': 'place', 'label': 'Place it'},
        ],
      },
      'validation': {'type': 'equals', 'value': 'place'},
      'transition': {'correct': 'reveal', 'incorrect': 'reveal'},
    },
    'reveal': {
      'presentation': {
        'layers': [
          {
            'type': 'canvas',
            'role': 'media',
            'assetId': 'composition_canvas',
          },
          {'type': 'text', 'role': 'reveal_title', 'value': 'Balanced.'},
          {
            'type': 'text',
            'role': 'reveal_detail',
            'value': 'One move restores the equation.',
          },
        ],
      },
      'input': {'type': 'tap', 'label': 'Done'},
      'validation': {'type': 'none'},
      'transition': {'default': r'$end'},
    },
  },
});

PlayCanvasAsset _compositionCanvas() => PlayCanvasAsset(
  id: 'composition_canvas',
  semanticLabel: 'A matchstick equation',
  elements: [
    PlayCanvasLine(
      start: const Offset(0.25, 0.5),
      end: const Offset(0.75, 0.5),
      width: 0.025,
      tone: PlayCanvasTone.accent,
    ),
  ],
);

void main() {
  for (final viewportCase in _viewportCases) {
    testWidgets(
      '${viewportCase.name} gives the real PlaySurface non-overlapping regions',
      (tester) async {
        final composition = await _pumpComposedSurface(
          tester,
          viewportCase: viewportCase,
        );

        _expectSurfaceRegionsMatch(tester, composition);
        _expectPairwiseNonOverlapping(<Rect>[
          tester.getRect(find.byKey(_promptKey)),
          tester.getRect(find.byKey(_stageKey)),
          tester.getRect(find.byKey(_inputKey)),
          tester.getRect(find.byKey(_utilitiesKey)),
        ]);
      },
    );
  }

  testWidgets('200% text stays inside the allocated composition', (
    tester,
  ) async {
    final composition = await _pumpComposedSurface(
      tester,
      viewportCase: _viewportCases[1],
      textScaler: const TextScaler.linear(2),
    );

    _expectSurfaceRegionsMatch(tester, composition);
    _expectPairwiseNonOverlapping(<Rect>[
      tester.getRect(find.byKey(_promptKey)),
      tester.getRect(find.byKey(_stageKey)),
      tester.getRect(find.byKey(_inputKey)),
      tester.getRect(find.byKey(_utilitiesKey)),
    ]);
    _expectContained(
      tester.getRect(find.byKey(_promptKey)),
      tester.getRect(find.text('Place the match.')),
    );
    _expectContained(
      tester.getRect(find.byKey(_inputKey)),
      tester.getRect(find.widgetWithText(FilledButton, 'Place it')),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTL trailing-rail composition aligns prompt from the right', (
    tester,
  ) async {
    final composition = await _pumpComposedSurface(
      tester,
      viewportCase: _viewportCases[3],
      textDirection: TextDirection.rtl,
    );

    expect(
      Directionality.of(tester.element(find.byKey(_promptKey))),
      TextDirection.rtl,
    );
    _expectSurfaceRegionsMatch(tester, composition);
    _expectPairwiseNonOverlapping(<Rect>[
      tester.getRect(find.byKey(_promptKey)),
      tester.getRect(find.byKey(_stageKey)),
      tester.getRect(find.byKey(_inputKey)),
      tester.getRect(find.byKey(_utilitiesKey)),
    ]);
    final promptParagraph = tester.renderObject<RenderParagraph>(
      find.text('Place the match.'),
    );
    expect(promptParagraph.textDirection, TextDirection.rtl);
    expect(promptParagraph.textAlign, TextAlign.start);
  });
}

Future<PlayViewportComposition> _pumpComposedSurface(
  WidgetTester tester, {
  required _ViewportCase viewportCase,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
  bool disableAnimations = false,
}) async {
  tester.view
    ..physicalSize = viewportCase.size
    ..devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final composition = PlayViewportComposition.fromConstraints(
    BoxConstraints.tight(viewportCase.size),
    safeInsets: viewportCase.safeInsets,
    textScaler: textScaler,
  );
  final canvas = _compositionCanvas();

  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: viewportCase.size,
          padding: viewportCase.safeInsets,
          textScaler: textScaler,
          disableAnimations: disableAnimations,
        ),
        child: Directionality(
          textDirection: textDirection,
          child: Scaffold(
            body: PlaySurface(
              play: _composedCanvasPlay(),
              mediaBuilder: (context, layer) => PlayCanvas(asset: canvas),
            ),
          ),
        ),
      ),
    ),
  );

  return composition;
}

void _expectSurfaceRegionsMatch(
  WidgetTester tester,
  PlayViewportComposition composition,
) {
  _expectRectClose(
    tester.getRect(find.byKey(_promptKey)),
    composition.promptRect,
  );
  _expectRectClose(
    tester.getRect(find.byKey(_stageKey)),
    composition.stageRect,
  );
  _expectRectClose(
    tester.getRect(find.byKey(_inputKey)),
    composition.inputRect,
  );
  _expectRectClose(
    tester.getRect(find.byKey(_utilitiesKey)),
    composition.utilityRect,
  );
}

void _expectPairwiseNonOverlapping(List<Rect> regions) {
  for (var left = 0; left < regions.length; left += 1) {
    for (var right = left + 1; right < regions.length; right += 1) {
      expect(
        regions[left].overlaps(regions[right]),
        isFalse,
        reason: '${regions[left]} must not overlap ${regions[right]}',
      );
    }
  }
}

void _expectContained(Rect outer, Rect inner) {
  expect(inner.left, greaterThanOrEqualTo(outer.left));
  expect(inner.top, greaterThanOrEqualTo(outer.top));
  expect(inner.right, lessThanOrEqualTo(outer.right));
  expect(inner.bottom, lessThanOrEqualTo(outer.bottom));
}

void _expectRectClose(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 0.001));
  expect(actual.top, closeTo(expected.top, 0.001));
  expect(actual.right, closeTo(expected.right, 0.001));
  expect(actual.bottom, closeTo(expected.bottom, 0.001));
}
