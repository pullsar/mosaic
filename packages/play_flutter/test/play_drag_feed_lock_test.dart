import 'package:flutter/material.dart';
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
}
