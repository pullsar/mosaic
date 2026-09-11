import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

GameSceneDefinition _scene() => GameSceneDefinition.fromJson({
  'version': 1,
  'objects': [
    for (final (id, x) in [('piece', .1), ('neighbor', .8)])
      {
        'id': id,
        'semanticLabel': id,
        'shape': 'rounded_rect',
        'x': x,
        'y': .2,
        'width': .1,
        'height': .2,
        'movable': true,
      },
  ],
  'targets': [
    for (final (id, x) in [('first', .4), ('second', .6)])
      {
        'id': id,
        'semanticLabel': id,
        'x': x,
        'y': .2,
        'width': .1,
        'height': .2,
      },
  ],
});

Widget _app({
  required GameSceneDefinition scene,
  Map<String, String> placements = const {},
  void Function(String, String)? onMove,
  ValueChanged<bool>? onManipulation,
  bool reduced = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Center(
      child: SizedBox.square(
        dimension: 300,
        child: PlaySceneRenderer(
          scene: scene,
          placements: placements,
          onPieceMove: onMove ?? (_, _) {},
          onDirectManipulationChanged: onManipulation,
        ),
      ),
    ),
  ),
);

Finder _visual(String id) => find
    .descendant(
      of: find.byKey(ValueKey<String>('scene-object:$id')),
      matching: find.byType(DecoratedBox),
    )
    .last;

void main() {
  testWidgets('100 interrupted scenes leave no active gesture or ticker', (
    tester,
  ) async {
    final leases = <bool>[];
    for (var index = 0; index < 100; index++) {
      await tester.pumpWidget(
        _app(scene: _scene(), onManipulation: leases.add),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(_visual('piece')),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(35, 20));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await gesture.cancel();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    }
    expect(leases, [
      for (var index = 0; index < 100; index++) ...[true, false],
    ]);
  });

  testWidgets('a returning piece can be caught without jumping to its origin', (
    tester,
  ) async {
    await tester.pumpWidget(_app(scene: _scene()));
    final original = tester.getCenter(_visual('piece'));
    final gesture = await tester.startGesture(original);
    await tester.pump();
    await gesture.moveBy(const Offset(65, 60));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final returning = tester.getCenter(_visual('piece'));
    expect((returning - original).distance, greaterThan(2));
    final catchGesture = await tester.startGesture(returning);
    await tester.pump();
    expect(
      (tester.getCenter(_visual('piece')) - returning).distance,
      lessThan(.01),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      (tester.getCenter(_visual('piece')) - returning).distance,
      lessThan(.01),
    );
    await catchGesture.cancel();
    await tester.pumpAndSettle();
    expect(
      (tester.getCenter(_visual('piece')) - original).distance,
      lessThan(.01),
    );
  });

  testWidgets(
    'drag tracks the finger in the same frame and isolates neighbors',
    (tester) async {
      await tester.pumpWidget(_app(scene: _scene()));
      final neighbor = tester.getCenter(_visual('neighbor'));
      final gesture = await tester.startGesture(
        tester.getCenter(_visual('piece')),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump();
      final before = tester.getCenter(_visual('piece'));
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      expect(
        tester.getCenter(_visual('piece')).dx - before.dx,
        closeTo(24, .01),
      );
      expect(tester.getCenter(_visual('neighbor')), neighbor);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('drag hit testing starts at the published placement', (
    tester,
  ) async {
    final moves = <(String, String)>[];
    await tester.pumpWidget(
      _app(
        scene: _scene(),
        placements: {'piece': 'first'},
        onMove: (piece, target) => moves.add((piece, target)),
      ),
    );
    await tester.dragFrom(
      tester.getCenter(_visual('piece')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    expect(moves, [('piece', 'second')]);
  });

  testWidgets('removing a held scene releases the feed gesture lease', (
    tester,
  ) async {
    final leases = <bool>[];
    await tester.pumpWidget(_app(scene: _scene(), onManipulation: leases.add));
    final gesture = await tester.startGesture(
      tester.getCenter(_visual('piece')),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(leases, [true, false]);
    await gesture.cancel();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replacement scene cannot retain an old selection', (
    tester,
  ) async {
    await tester.pumpWidget(_app(scene: _scene()));
    await tester.tap(find.bySemanticsLabel('piece'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('first'), findsOneWidget);
    await tester.pumpWidget(_app(scene: _scene()));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('first'), findsNothing);
  });

  testWidgets('a second touch cannot release or submit the first drag', (
    tester,
  ) async {
    final leases = <bool>[];
    final moves = <(String, String)>[];
    await tester.pumpWidget(
      _app(
        scene: _scene(),
        onManipulation: leases.add,
        onMove: (piece, target) => moves.add((piece, target)),
      ),
    );
    final first = await tester.startGesture(
      tester.getCenter(_visual('piece')),
      pointer: 1,
    );
    await tester.pump();
    await first.moveBy(const Offset(25, 0));
    await tester.pump();
    final second = await tester.startGesture(
      tester.getCenter(_visual('neighbor')),
      pointer: 2,
    );
    await tester.pump();
    await second.cancel();
    await tester.pump();
    expect(leases, [true]);
    await first.cancel();
    await tester.pumpAndSettle();
    expect(leases, [true, false]);
    expect(moves, isEmpty);
  });

  testWidgets(
    'reduced motion cancels a dragged piece without residual motion',
    (tester) async {
      await tester.pumpWidget(_app(scene: _scene(), reduced: true));
      final origin = tester.getCenter(_visual('piece'));
      final gesture = await tester.startGesture(origin);
      await tester.pump();
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();
      expect(tester.getCenter(_visual('piece')), origin);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
