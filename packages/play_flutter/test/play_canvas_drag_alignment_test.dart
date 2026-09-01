import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

const _stageAspectRatio = 4 / 5;
const _maximumStageWidth = 720.0;
const _dragOrigin = Offset(0.1, 0.2);
const _dragSize = Size(0.1, 0.1);
const _target = Rect.fromLTWH(0.7, 0.6, 0.2, 0.2);

typedef _ViewportCase = ({String name, Size viewport});

const _viewportCases = <_ViewportCase>[
  (name: 'phone portrait', viewport: Size(390, 844)),
  (name: 'desktop landscape', viewport: Size(1440, 900)),
];

PlayDocument _dragPlay() => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'canvas_drag_alignment',
  'revisionId': 'canvas_drag_alignment_rev_1',
  'format': 'solve',
  'classification': 'challenge',
  'topics': ['geometry'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 10,
  'assets': ['drag_canvas'],
  'sources': <Object>[],
  'entryState': 'solve',
  'states': {
    'solve': {
      'presentation': {
        'layers': [
          {'type': 'canvas', 'role': 'media', 'assetId': 'drag_canvas'},
        ],
      },
      'input': {
        'type': 'drag',
        'dragOrigin': {'x': _dragOrigin.dx, 'y': _dragOrigin.dy},
        'dragSize': {'width': _dragSize.width, 'height': _dragSize.height},
        'targets': [
          {
            'id': 'target',
            'x': _target.left,
            'y': _target.top,
            'width': _target.width,
            'height': _target.height,
          },
        ],
        'handleLabel': 'Move tile',
        'showTargetHints': true,
      },
      'validation': {'type': 'target_region', 'value': 'target'},
      'transition': {'correct': 'reveal', 'incorrect': 'solve'},
    },
    'reveal': {
      'presentation': {
        'layers': [
          {'type': 'text', 'role': 'reveal_title', 'value': 'Placed.'},
        ],
      },
      'input': {'type': 'tap', 'label': 'Done'},
      'validation': {'type': 'none'},
      'transition': {'default': r'$end'},
    },
  },
});

PlayCanvasAsset _dragCanvas() => PlayCanvasAsset(
  id: 'drag_canvas',
  semanticLabel: 'Move the tile to the outlined target',
  elements: [
    PlayCanvasRect(rect: _dragOrigin & _dragSize, fill: true),
    PlayCanvasRect(rect: _target, tone: PlayCanvasTone.accent),
  ],
);

void main() {
  for (final viewportCase in _viewportCases) {
    testWidgets(
      '${viewportCase.name} shares one fitted stage for canvas and drag input',
      (tester) async {
        tester.view
          ..physicalSize = viewportCase.viewport
          ..devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final canvas = _dragCanvas();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlaySurface(
                play: _dragPlay(),
                mediaBuilder: (context, layer) => PlayCanvas(asset: canvas),
              ),
            ),
          ),
        );

        final surfaceRect = tester.getRect(find.byType(PlaySurface));
        final expectedStage = _fitStage(surfaceRect);
        final canvasPaint = find.descendant(
          of: find.byType(PlayCanvas),
          matching: find.byType(CustomPaint),
        );
        final handle = find.bySemanticsLabel('Move tile');
        final targetHint = find.descendant(
          of: find.byType(PlayDragInput),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).border != null,
            description: 'authored drag target hint',
          ),
        );

        expect(canvasPaint, findsOneWidget);
        expect(handle, findsOneWidget);
        expect(targetHint, findsOneWidget);
        _expectRectClose(tester.getRect(canvasPaint), expectedStage);
        final expectedHandle = _mapRect(expectedStage, _dragOrigin & _dragSize);
        final expectedTarget = _mapRect(expectedStage, _target);
        _expectRectClose(tester.getRect(handle), expectedHandle);
        _expectRectClose(tester.getRect(targetHint), expectedTarget);

        await tester.drag(
          handle,
          expectedTarget.center - expectedHandle.center,
        );
        await tester.pump();

        expect(find.text('Placed.'), findsOneWidget);
      },
    );
  }
}

Rect _fitStage(Rect bounds) {
  final width = math.min(
    _maximumStageWidth,
    math.min(bounds.width, bounds.height * _stageAspectRatio),
  );
  return Rect.fromCenter(
    center: bounds.center,
    width: width,
    height: width / _stageAspectRatio,
  );
}

Rect _mapRect(Rect stage, Rect normalized) => Rect.fromLTWH(
  stage.left + normalized.left * stage.width,
  stage.top + normalized.top * stage.height,
  normalized.width * stage.width,
  normalized.height * stage.height,
);

void _expectRectClose(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, 0.001));
  expect(actual.top, closeTo(expected.top, 0.001));
  expect(actual.width, closeTo(expected.width, 0.001));
  expect(actual.height, closeTo(expected.height, 0.001));
}
