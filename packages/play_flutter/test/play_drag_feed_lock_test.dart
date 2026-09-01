import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

const _spec = PlayDragInputSpec(
  origin: Offset(0.4, 0.4),
  size: Size(0.1, 0.1),
  targets: <PlayDragTarget>[
    PlayDragTarget(
      id: 'target',
      rect: PlayNormalizedRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2),
    ),
  ],
);

const _accessibleMatchSpec = PlayDragInputSpec(
  origin: Offset(0.48, 0.35),
  size: Size(0.04, 0.2),
  handleLabel: 'Move match',
  targets: <PlayDragTarget>[
    PlayDragTarget(
      id: 'solution',
      rect: PlayNormalizedRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2),
    ),
  ],
);

const _multipleTargetSpec = PlayDragInputSpec(
  origin: Offset(0.48, 0.35),
  size: Size(0.04, 0.2),
  handleLabel: 'Move match',
  targets: <PlayDragTarget>[
    PlayDragTarget(
      id: 'decoy',
      rect: PlayNormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
    ),
    PlayDragTarget(
      id: 'solution',
      rect: PlayNormalizedRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2),
    ),
  ],
);

PlayDocument _multipleTargetPlay() => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'multiple_target_drag',
  'revisionId': 'multiple_target_drag_rev_1',
  'format': 'solve',
  'classification': 'challenge',
  'topics': ['puzzles'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 8,
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
        'dragOrigin': {'x': 0.48, 'y': 0.35},
        'dragSize': {'width': 0.04, 'height': 0.2},
        'handleLabel': 'Move match',
        'targets': [
          {'id': 'decoy', 'x': 0.1, 'y': 0.1, 'width': 0.2, 'height': 0.2},
          {'id': 'solution', 'x': 0.7, 'y': 0.4, 'width': 0.2, 'height': 0.2},
        ],
      },
      'validation': {'type': 'target_region', 'value': 'solution'},
      'transition': {'correct': 'reveal', 'incorrect': 'solve'},
    },
    'reveal': {
      'presentation': {
        'layers': [
          {'type': 'canvas', 'role': 'media', 'assetId': 'drag_canvas'},
          {'type': 'text', 'role': 'reveal_title', 'value': 'Solved target.'},
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
  elements: [
    PlayCanvasLine(
      start: const Offset(0.48, 0.35),
      end: const Offset(0.48, 0.55),
    ),
  ],
);

Widget _scopedDragSurface({
  required PlayViewportComposition composition,
  required PlayDocument play,
  required PlayCanvasAsset canvas,
  required ValueChanged<bool> onManipulationChanged,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      size: composition.viewportRect.size,
      padding: EdgeInsets.fromLTRB(
        composition.safeRect.left,
        composition.safeRect.top,
        composition.viewportRect.right - composition.safeRect.right,
        composition.viewportRect.bottom - composition.safeRect.bottom,
      ),
    ),
    child: PlayViewportScope(
      composition: composition,
      child: Scaffold(
        body: PlaySurface(
          play: play,
          mediaBuilder: (context, layer) => PlayCanvas(asset: canvas),
          onDirectManipulationChanged: onManipulationChanged,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('drag handle locks feed paging on raw pointer down', (
    tester,
  ) async {
    final locks = <bool>[];

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 300,
          child: PlayDragInput(
            spec: _spec,
            onTarget: (_) {},
            onManipulationChanged: locks.add,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.bySemanticsLabel('Move item')),
    );
    expect(locks, [true]);

    await gesture.moveBy(const Offset(20, 0));
    expect(locks, [true]);

    await gesture.up();
    await tester.pump();
    expect(locks, [true, false]);
  });

  testWidgets('pointer outside drag handle never locks feed paging', (
    tester,
  ) async {
    final locks = <bool>[];
    const surfaceKey = ValueKey<String>('drag-surface');

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          key: surfaceKey,
          dimension: 300,
          child: PlayDragInput(
            spec: _spec,
            onTarget: (_) {},
            onManipulationChanged: locks.add,
          ),
        ),
      ),
    );

    final topLeft = tester.getTopLeft(find.byKey(surfaceKey));
    final gesture = await tester.startGesture(topLeft + const Offset(20, 20));
    await gesture.moveBy(const Offset(0, 80));
    await gesture.up();
    await tester.pump();

    expect(locks, isEmpty);
  });

  testWidgets(
    'equivalent viewport reconstruction preserves active pointer ownership',
    (tester) async {
      const viewport = Size(390, 844);
      const safeInsets = EdgeInsets.only(top: 47, bottom: 34);
      final play = _multipleTargetPlay();
      final canvas = _dragCanvas();
      final locks = <bool>[];
      tester.view
        ..physicalSize = viewport
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      PlayViewportComposition equivalentComposition() =>
          PlayViewportComposition.fromConstraints(
            const BoxConstraints.tightFor(width: 390, height: 844),
            safeInsets: safeInsets,
          );
      final initialComposition = equivalentComposition();

      await tester.pumpWidget(
        _scopedDragSurface(
          composition: initialComposition,
          play: play,
          canvas: canvas,
          onManipulationChanged: locks.add,
        ),
      );
      final handle = find.byKey(const ValueKey<String>('play-drag-object'));
      final originRect = tester.getRect(handle);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      final firstMovedRect = tester.getRect(handle);

      expect(firstMovedRect.left, greaterThan(originRect.left));
      expect(locks, [true]);

      final rebuiltComposition = equivalentComposition();
      expect(identical(rebuiltComposition, initialComposition), isFalse);
      expect(rebuiltComposition.stageRect, initialComposition.stageRect);
      await tester.pumpWidget(
        _scopedDragSurface(
          composition: rebuiltComposition,
          play: play,
          canvas: canvas,
          onManipulationChanged: locks.add,
        ),
      );
      await tester.pump();

      expect(tester.getRect(handle), firstMovedRect);
      expect(locks, [true]);

      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      expect(tester.getRect(handle).left, greaterThan(firstMovedRect.left));
      expect(locks, [true]);

      await gesture.up();
      await tester.pump();
      expect(locks, [true, false]);
    },
  );

  testWidgets('thin authored match keeps a 48 by 48 semantic target', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: PlayDragInput(spec: _accessibleMatchSpec, onTarget: (_) {}),
          ),
        ),
      ),
    );

    final semanticTarget = tester.getRect(find.bySemanticsLabel('Move match'));
    final object = find.byKey(const ValueKey<String>('play-drag-object'));

    expect(semanticTarget.width, greaterThanOrEqualTo(48));
    expect(semanticTarget.height, greaterThanOrEqualTo(48));
    expect(object, findsOneWidget);
    expect(
      tester.getRect(object).width / tester.getRect(object).height,
      closeTo(
        _accessibleMatchSpec.size.width / _accessibleMatchSpec.size.height,
        0.001,
      ),
    );
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
  });

  testWidgets('semantic activation resolves without acquiring the feed lock', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final targets = <String>[];
      final locks = <bool>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 300,
              child: PlayDragInput(
                spec: _accessibleMatchSpec,
                onTarget: targets.add,
                onManipulationChanged: locks.add,
              ),
            ),
          ),
        ),
      );

      final node = tester.getSemantics(find.bySemanticsLabel('Move match'));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

      tester.semantics.tap(find.semantics.byLabel('Move match'));
      await tester.pump();

      expect(targets, ['solution']);
      expect(locks, isEmpty);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'multi-target semantics lets the user choose without acquiring feed lock',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final targets = <String>[];
        final locks = <bool>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox.square(
                dimension: 300,
                child: PlayDragInput(
                  spec: _multipleTargetSpec,
                  onTarget: targets.add,
                  onManipulationChanged: locks.add,
                ),
              ),
            ),
          ),
        );

        final handle = find.bySemanticsLabel('Move match');
        final initialData = tester.getSemantics(handle).getSemanticsData();
        expect(initialData.label, 'Move match');
        expect(initialData.value, 'Target 1 of 2');
        expect(initialData.label, isNot(contains('decoy')));
        expect(initialData.label, isNot(contains('solution')));
        expect(initialData.hasAction(SemanticsAction.tap), isTrue);
        expect(initialData.hasAction(SemanticsAction.increase), isTrue);
        expect(initialData.hasAction(SemanticsAction.decrease), isTrue);

        tester.semantics.tap(find.semantics.byLabel('Move match'));
        await tester.pump();
        expect(targets, ['decoy']);
        expect(locks, isEmpty);

        tester.semantics.increase(find.semantics.byLabel('Move match'));
        await tester.pump();
        expect(
          tester.getSemantics(handle).getSemanticsData().value,
          'Target 2 of 2',
        );
        tester.semantics.tap(find.semantics.byLabel('Move match'));
        await tester.pump();

        expect(targets, ['decoy', 'solution']);
        expect(locks, isEmpty);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('keyboard arrows choose a drag target and Enter submits it', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final targets = <String>[];
      final locks = <bool>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 300,
              child: PlayDragInput(
                spec: _multipleTargetSpec,
                onTarget: targets.add,
                onManipulationChanged: locks.add,
              ),
            ),
          ),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Move match'))
            .getSemanticsData()
            .value,
        'Target 2 of 2',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(targets, ['solution']);
      expect(locks, isEmpty);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('PlaySurface requires accessible multi-target selection', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final locks = <bool>[];
      final canvas = _dragCanvas();

      await tester.pumpWidget(
        MaterialApp(
          home: PlaySurface(
            play: _multipleTargetPlay(),
            mediaBuilder: (context, layer) => PlayCanvas(asset: canvas),
            onDirectManipulationChanged: locks.add,
          ),
        ),
      );

      final handle = find.bySemanticsLabel('Move match');
      expect(
        tester.getSemantics(handle).getSemanticsData().value,
        'Target 1 of 2',
      );
      tester.semantics.tap(find.semantics.byLabel('Move match'));
      await tester.pumpAndSettle();

      expect(find.text('Solved target.'), findsNothing);
      expect(find.byType(PlayDragInput), findsOneWidget);
      expect(locks, isEmpty);

      tester.semantics.increase(find.semantics.byLabel('Move match'));
      await tester.pump();
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Move match'))
            .getSemanticsData()
            .value,
        'Target 2 of 2',
      );
      tester.semantics.tap(find.semantics.byLabel('Move match'));
      await tester.pumpAndSettle();

      expect(find.text('Solved target.'), findsOneWidget);
      expect(locks, isEmpty);
    } finally {
      semantics.dispose();
    }
  });
}
