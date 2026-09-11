import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

void main() {
  testWidgets('scene moves the selected stable object to its target', (
    tester,
  ) async {
    final moves = <(String, String)>[];
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'match',
          'semanticLabel': 'Vertical match',
          'shape': 'rounded_rect',
          'x': .2,
          'y': .2,
          'width': .05,
          'height': .2,
          'tone': 'accent',
          'movable': true,
        },
      ],
      'targets': [
        {
          'id': 'slot',
          'semanticLabel': 'Open slot',
          'x': .7,
          'y': .4,
          'width': .05,
          'height': .2,
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: PlaySceneRenderer(
              scene: scene,
              onPieceMove: (piece, target) {
                moves.add((piece, target));
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Vertical match'));
    await tester.pump();
    expect(find.bySemanticsLabel('Open slot'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Open slot'));

    expect(moves, [('match', 'slot')]);
  });
}
