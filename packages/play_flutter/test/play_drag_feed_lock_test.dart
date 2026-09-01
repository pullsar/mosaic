import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

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

  testWidgets('thin authored match keeps a 48 by 48 semantic target', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 300,
          child: PlayDragInput(
            spec: _accessibleMatchSpec,
            onTarget: (_) {},
          ),
        ),
      ),
    );

    final semanticTarget = tester.getRect(
      find.bySemanticsLabel('Move match'),
    );
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
    addTearDown(semantics.dispose);
    final targets = <String>[];
    final locks = <bool>[];

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 300,
          child: PlayDragInput(
            spec: _accessibleMatchSpec,
            onTarget: targets.add,
            onManipulationChanged: locks.add,
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
  });
}
