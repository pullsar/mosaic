import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
          'x': .6,
          'y': .2,
          'width': .3,
          'height': .4,
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
    final socket = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey<String>('scene-target-socket:slot')),
    );
    final decoration = socket.decoration! as BoxDecoration;
    expect(decoration.boxShadow, isNotEmpty);
    await tester.tap(find.bySemanticsLabel('Open slot'));

    expect(moves, [('match', 'slot')]);
  });

  testWidgets('scene renders a matchstick with a visible head', (tester) async {
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'match',
          'semanticLabel': 'Vertical match',
          'shape': 'matchstick',
          'x': .2,
          'y': .2,
          'width': .05,
          'height': .2,
          'movable': true,
        },
      ],
      'targets': const [],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 300,
          child: PlaySceneRenderer(scene: scene, onPieceMove: (_, _) {}),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('scene-matchstick-head')),
      findsOneWidget,
    );
  });

  testWidgets('scene renders a cup with a rim and recessed well', (
    tester,
  ) async {
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'cup',
          'semanticLabel': 'Cup',
          'shape': 'cup',
          'x': .2,
          'y': .3,
          'width': .16,
          'height': .28,
          'tone': 'surface',
        },
      ],
      'targets': const [],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 300,
          child: PlaySceneRenderer(scene: scene, onPieceMove: (_, _) {}),
        ),
      ),
    );

    expect(find.byKey(const ValueKey<String>('scene-cup-rim')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('scene-cup-well')),
      findsOneWidget,
    );
  });

  testWidgets('scene renders a coin with a raised rim and inset mark', (
    tester,
  ) async {
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'coin',
          'semanticLabel': 'Coin',
          'shape': 'coin',
          'x': .2,
          'y': .3,
          'width': .08,
          'height': .08,
          'tone': 'accent',
        },
      ],
      'targets': const [],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 300,
          child: PlaySceneRenderer(scene: scene, onPieceMove: (_, _) {}),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('scene-coin-rim')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('scene-coin-mark')),
      findsOneWidget,
    );
  });

  testWidgets('scene renders an orb with a reflective mark', (tester) async {
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'orb',
          'semanticLabel': 'Marked orb',
          'shape': 'orb',
          'x': .2,
          'y': .3,
          'width': .08,
          'height': .08,
          'tone': 'accent',
        },
      ],
      'targets': const [],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 300,
          child: PlaySceneRenderer(scene: scene, onPieceMove: (_, _) {}),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('scene-orb-highlight:orb')),
      findsOneWidget,
    );
  });

  testWidgets('scene renders an active cue at its sampled position', (
    tester,
  ) async {
    final moves = <(String, String)>[];
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'coin',
          'semanticLabel': 'Coin',
          'shape': 'circle',
          'x': .1,
          'y': .3,
          'width': .1,
          'height': .1,
          'movable': true,
        },
      ],
      'targets': const [],
      'cues': [
        {
          'id': 'coin_path',
          'objectId': 'coin',
          'durationMs': 1000,
          'keyframes': [
            {'timeMs': 0, 'x': .1, 'y': .3, 'width': .1, 'height': .1},
            {'timeMs': 1000, 'x': .7, 'y': .3, 'width': .1, 'height': .1},
          ],
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 300,
          child: PlaySceneRenderer(
            scene: scene,
            cueId: 'coin_path',
            cueProgress: .5,
            onPieceMove: (piece, target) => moves.add((piece, target)),
          ),
        ),
      ),
    );

    final position = tester.widget<AnimatedPositioned>(
      find.byKey(const ValueKey<String>('scene-object:coin')),
    );
    final sceneBounds = tester.getSize(find.byType(PlaySceneRenderer));
    expect(position.left, closeTo(sceneBounds.width * .4, .01));
    await tester.tap(find.bySemanticsLabel('Coin'));
    expect(moves, isEmpty);
  });

  testWidgets('scene samples every track in an active cue schedule', (
    tester,
  ) async {
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'left_cup',
          'semanticLabel': 'Left cup',
          'shape': 'rounded_rect',
          'x': .1,
          'y': .3,
          'width': .1,
          'height': .2,
        },
        {
          'id': 'right_cup',
          'semanticLabel': 'Right cup',
          'shape': 'rounded_rect',
          'x': .7,
          'y': .3,
          'width': .1,
          'height': .2,
        },
      ],
      'targets': const <Object?>[],
      'cues': [
        {
          'id': 'shuffle_1',
          'objectId': 'left_cup',
          'durationMs': 1000,
          'keyframes': [
            {'timeMs': 0, 'x': .1, 'y': .3, 'width': .1, 'height': .2},
            {'timeMs': 1000, 'x': .7, 'y': .3, 'width': .1, 'height': .2},
          ],
        },
        {
          'id': 'shuffle_1',
          'objectId': 'right_cup',
          'durationMs': 1000,
          'keyframes': [
            {'timeMs': 0, 'x': .7, 'y': .3, 'width': .1, 'height': .2},
            {'timeMs': 1000, 'x': .1, 'y': .3, 'width': .1, 'height': .2},
          ],
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 300,
          child: PlaySceneRenderer(
            scene: scene,
            cueId: 'shuffle_1',
            cueProgress: 1,
            onPieceMove: (_, _) {},
          ),
        ),
      ),
    );

    final bounds = tester.getSize(find.byType(PlaySceneRenderer));
    expect(
      tester
          .widget<AnimatedPositioned>(
            find.byKey(const ValueKey<String>('scene-object:left_cup')),
          )
          .left,
      closeTo(bounds.width * .7, .01),
    );
    expect(
      tester
          .widget<AnimatedPositioned>(
            find.byKey(const ValueKey<String>('scene-object:right_cup')),
          )
          .left,
      closeTo(bounds.width * .1, .01),
    );
  });

  testWidgets('scene puts a horizontal matchstick head at its end', (
    tester,
  ) async {
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'match',
          'semanticLabel': 'Horizontal match',
          'shape': 'matchstick',
          'x': .2,
          'y': .2,
          'width': .2,
          'height': .05,
          'movable': true,
        },
      ],
      'targets': const [],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 300,
          child: PlaySceneRenderer(scene: scene, onPieceMove: (_, _) {}),
        ),
      ),
    );

    final head = tester.widget<Align>(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('scene-matchstick-head')),
        matching: find.byType(Align),
      ),
    );
    expect(head.alignment, Alignment.centerRight);
  });

  testWidgets(
    'scene drag commits one legal piece move and releases its lease',
    (tester) async {
      final moves = <(String, String)>[];
      final manipulation = <bool>[];
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
            'x': .6,
            'y': .2,
            'width': .3,
            'height': .4,
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
                onPieceMove: (piece, target) => moves.add((piece, target)),
                onDirectManipulationChanged: manipulation.add,
              ),
            ),
          ),
        ),
      );

      final match = find.bySemanticsLabel('Vertical match');
      await tester.dragFrom(tester.getCenter(match), const Offset(160, 0));
      await tester.pumpAndSettle();

      expect(manipulation, [true, false]);
      expect(moves, [('match', 'slot')]);
    },
  );

  testWidgets('scene moves can be completed from the keyboard', (tester) async {
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
              onPieceMove: (piece, target) => moves.add((piece, target)),
            ),
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(moves, [('match', 'slot')]);
  });

  testWidgets('scene move resolves through the shared Play surface', (
    tester,
  ) async {
    final play = PlayDocument.fromJson({
      'schemaVersion': 1,
      'id': 'scene_surface',
      'revisionId': 'rev_1',
      'format': 'solve',
      'classification': 'challenge',
      'topics': [],
      'learningTopics': [],
      'estimatedDurationSec': 10,
      'assets': [],
      'sources': [],
      'entryState': 'move',
      'states': {
        'move': {
          'presentation': {
            'layers': [
              {
                'type': 'scene',
                'role': 'media',
                'scene': {
                  'version': 1,
                  'objects': [
                    {
                      'id': 'piece',
                      'semanticLabel': 'Move piece',
                      'shape': 'rounded_rect',
                      'x': .2,
                      'y': .2,
                      'width': .05,
                      'height': .2,
                      'movable': true,
                    },
                  ],
                  'targets': [
                    {
                      'id': 'slot',
                      'semanticLabel': 'Open slot',
                      'x': .7,
                      'y': .2,
                      'width': .05,
                      'height': .2,
                    },
                  ],
                },
              },
              {'type': 'text', 'role': 'prompt', 'value': 'Move it.'},
            ],
          },
          'input': {'type': 'piece_move'},
          'validation': {
            'type': 'legal_piece_move',
            'value': [
              {'pieceId': 'piece', 'targetId': 'slot', 'correct': true},
            ],
          },
          'transition': {'correct': 'reveal', 'incorrect': 'move'},
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(child: PlaySurface(play: play)),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Move piece'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Open slot'));
    await tester.pumpAndSettle();

    expect(find.text('Placed.'), findsOneWidget);
  });
}
