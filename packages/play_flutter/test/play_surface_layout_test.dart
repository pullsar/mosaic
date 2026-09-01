import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

const _promptKey = ValueKey<String>('play-prompt');
const _stageKey = ValueKey<String>('play-stage');
const _inputKey = ValueKey<String>('play-input');
const _utilitiesKey = ValueKey<String>('play-utilities-region');
const _maximumReveal =
    'One careful move keeps the original pieces visible while the '
    'corrected equation appears here with enough detail to explain why the '
    'solution works without replacing the puzzle or hiding context';

typedef _ViewportCase = ({String name, Size size, EdgeInsets safeInsets});

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

PlayDocument _composedCanvasPlay({
  String revealDetail = 'One move restores the equation.',
}) => PlayDocument.fromJson({
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
          {'type': 'canvas', 'role': 'media', 'assetId': 'composition_canvas'},
          {'type': 'text', 'role': 'prompt', 'value': 'Place the match.'},
        ],
      },
      'input': {
        'type': 'single_choice',
        'options': [
          {'id': 'place', 'label': 'Place it'},
          {'id': 'lift', 'label': 'Lift left'},
          {'id': 'shift', 'label': 'Shift top'},
          {'id': 'turn', 'label': 'Turn it'},
          {'id': 'reset', 'label': 'Reset'},
        ],
      },
      'validation': {'type': 'equals', 'value': 'place'},
      'transition': {'correct': 'reveal', 'incorrect': 'reveal'},
    },
    'reveal': {
      'presentation': {
        'layers': [
          {'type': 'canvas', 'role': 'media', 'assetId': 'composition_canvas'},
          {'type': 'text', 'role': 'reveal_title', 'value': 'Balanced.'},
          {'type': 'text', 'role': 'reveal_detail', 'value': revealDetail},
        ],
      },
      'input': {'type': 'tap', 'label': 'Done'},
      'validation': {'type': 'none'},
      'transition': {'default': r'$end'},
    },
  },
});

PlayDocument _revealEntryPlay() => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'reveal_entry_canvas',
  'revisionId': 'reveal_entry_canvas_rev_1',
  'format': 'solve',
  'classification': 'challenge',
  'topics': ['puzzles'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 8,
  'assets': ['composition_canvas'],
  'sources': <Object>[],
  'entryState': 'reveal',
  'states': {
    'reveal': {
      'presentation': {
        'layers': [
          {'type': 'canvas', 'role': 'media', 'assetId': 'composition_canvas'},
          {'type': 'text', 'role': 'reveal_title', 'value': 'Balanced.'},
          {'type': 'text', 'role': 'reveal_detail', 'value': _maximumReveal},
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
    final promptRect = tester.getRect(find.byKey(_promptKey));
    final textScroll = find.byKey(const ValueKey<String>('play-text-scroll'));
    _expectContained(promptRect, tester.getRect(textScroll));
    _expectContained(promptRect, tester.getRect(find.text('Place the match.')));
    expect(
      tester.widget<SingleChildScrollView>(textScroll).clipBehavior,
      Clip.hardEdge,
    );
    final moreControl = find.byKey(const ValueKey<String>('play-text-more'));
    if (moreControl.evaluate().isNotEmpty) {
      _expectContained(promptRect, tester.getRect(moreControl));
    }
    _expectContained(
      tester.getRect(find.byKey(_inputKey)),
      tester.getRect(find.widgetWithText(FilledButton, 'Place it')),
    );
    expect(tester.takeException(), isNull);
  });

  for (final textDirection in TextDirection.values) {
    testWidgets(
      '200% ${textDirection.name} keeps five choices and maximum reveal usable',
      (tester) async {
        final composition = await _pumpComposedSurface(
          tester,
          viewportCase: _viewportCases[1],
          textScaler: const TextScaler.linear(2),
          textDirection: textDirection,
          play: _composedCanvasPlay(revealDetail: _maximumReveal),
        );
        final inputRect = tester.getRect(find.byKey(_inputKey));
        final choiceScroll = find.byKey(
          const ValueKey<String>('play-choice-scroll'),
        );

        _expectContained(inputRect, tester.getRect(choiceScroll));
        final choicePosition = tester.state<ScrollableState>(
          find.descendant(of: choiceScroll, matching: find.byType(Scrollable)),
        );
        expect(choicePosition.position.maxScrollExtent, greaterThan(0));
        for (final label in <String>[
          'Place it',
          'Lift left',
          'Shift top',
          'Turn it',
          'Reset',
        ]) {
          final button = find.widgetWithText(FilledButton, label);
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          _expectContained(inputRect, tester.getRect(button));
        }

        await tester.ensureVisible(
          find.widgetWithText(FilledButton, 'Place it'),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Place it'));
        await tester.pumpAndSettle();

        final promptRect = tester.getRect(find.byKey(_promptKey));
        final textScroll = find.byKey(
          const ValueKey<String>('play-text-scroll'),
        );
        _expectContained(promptRect, tester.getRect(textScroll));
        _expectContained(promptRect, tester.getRect(find.text('Balanced.')));
        final textPosition = tester.state<ScrollableState>(
          find.descendant(of: textScroll, matching: find.byType(Scrollable)),
        );
        expect(textPosition.position.maxScrollExtent, greaterThan(0));
        final beforeScroll = textPosition.position.pixels;
        await tester.tap(find.byKey(const ValueKey<String>('play-text-more')));
        await tester.pumpAndSettle();
        expect(textPosition.position.pixels, greaterThan(beforeScroll));
        expect(find.text(_maximumReveal), findsOneWidget);
        final visibleDetail = promptRect.intersect(
          tester.getRect(find.text(_maximumReveal)),
        );
        expect(visibleDetail.height, greaterThanOrEqualTo(24));
        _expectContained(promptRect, visibleDetail);
        expect(tester.takeException(), isNull);
        _expectSurfaceRegionsMatch(tester, composition);
      },
    );
  }

  testWidgets('a feed swipe starting over reveal still advances', (
    tester,
  ) async {
    const viewport = Size(390, 844);
    const insets = EdgeInsets.only(top: 47, bottom: 34);
    final canvas = _compositionCanvas();
    final pageController = PageController();
    addTearDown(pageController.dispose);
    tester.view
      ..physicalSize = viewport
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: viewport,
            padding: insets,
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: PageView(
              controller: pageController,
              scrollDirection: Axis.vertical,
              children: [
                PlaySurface(
                  play: _revealEntryPlay(),
                  mediaBuilder: (context, layer) => PlayCanvas(asset: canvas),
                ),
                const ColoredBox(
                  key: ValueKey<String>('next-play'),
                  color: Colors.black,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('play-text-scroll'))),
    );
    await gesture.moveBy(const Offset(0, -500));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(pageController.page, closeTo(1, 0.001));
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

  testWidgets('PlayViewportScope overrides fallback geometry and updates', (
    tester,
  ) async {
    const viewport = Size(390, 844);
    final first = PlayViewportComposition.fromConstraints(
      const BoxConstraints.tightFor(width: 390, height: 844),
      safeInsets: const EdgeInsets.only(top: 80, bottom: 24),
    );
    final second = PlayViewportComposition.fromConstraints(
      const BoxConstraints.tightFor(width: 390, height: 844),
      safeInsets: const EdgeInsets.only(top: 24, bottom: 80),
    );
    final canvas = _compositionCanvas();
    tester.view
      ..physicalSize = viewport
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Widget scopedSurface(PlayViewportComposition composition) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: viewport),
        child: Scaffold(
          body: PlayViewportScope(
            composition: composition,
            child: PlaySurface(
              play: _composedCanvasPlay(),
              mediaBuilder: (context, layer) => PlayCanvas(asset: canvas),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(scopedSurface(first));
    _expectSurfaceRegionsMatch(tester, first);

    await tester.pumpWidget(scopedSurface(second));
    _expectSurfaceRegionsMatch(tester, second);
  });
}

Future<PlayViewportComposition> _pumpComposedSurface(
  WidgetTester tester, {
  required _ViewportCase viewportCase,
  PlayDocument? play,
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
              play: play ?? _composedCanvasPlay(),
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
