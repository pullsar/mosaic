import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

PlayDocument _fixture(String name) {
  final raw =
      jsonDecode(File('../play_schema/fixtures/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayDocument.fromJson(raw);
}

PlayCanvasAsset _canvasFixture(String name) {
  final raw =
      jsonDecode(File('fixtures/canvas/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayCanvasAsset.fromJson(raw);
}

void main() {
  testWidgets('renders concise prompt and advances a choice', (tester) async {
    final play = PlayDocument.fromJson({
      'schemaVersion': 1,
      'id': 'demo',
      'revisionId': 'rev_1',
      'format': 'guess',
      'classification': 'challenge',
      'topics': ['travel'],
      'learningTopics': ['geography'],
      'estimatedDurationSec': 10,
      'assets': <String>[],
      'sources': <Object>[],
      'entryState': 'guess',
      'states': {
        'guess': {
          'presentation': {
            'layers': [
              {'type': 'text', 'role': 'prompt', 'value': 'Where is this?'},
            ],
          },
          'input': {
            'type': 'single_choice',
            'options': [
              {'id': 'a', 'label': 'Lisbon'},
              {'id': 'b', 'label': 'Marrakech'},
            ],
          },
          'validation': {'type': 'equals', 'value': 'a'},
          'transition': {'correct': 'reveal', 'incorrect': 'reveal'},
        },
        'reveal': {
          'presentation': {
            'layers': [
              {'type': 'text', 'role': 'reveal_title', 'value': 'Lisbon'},
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
        home: Scaffold(body: PlaySurface(play: play)),
      ),
    );
    expect(find.text('Where is this?'), findsOneWidget);
    await tester.tap(find.text('Lisbon'));
    await tester.pump();
    expect(find.text('Lisbon'), findsWidgets);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('routes declarative media through the PlaySurface media seam', (
    tester,
  ) async {
    final play = PlayDocument.fromJson({
      'schemaVersion': 1,
      'id': 'visual_demo',
      'revisionId': 'visual_rev_1',
      'format': 'guess',
      'classification': 'challenge',
      'topics': ['travel'],
      'learningTopics': ['geography'],
      'estimatedDurationSec': 10,
      'assets': ['image_1'],
      'sources': <Object>[],
      'entryState': 'guess',
      'states': {
        'guess': {
          'presentation': {
            'layers': [
              {'type': 'image', 'role': 'media', 'assetId': 'image_1'},
              {'type': 'text', 'role': 'prompt', 'value': 'Where is this?'},
            ],
          },
          'input': {'type': 'tap', 'label': 'Done'},
          'validation': {'type': 'none'},
          'transition': {'default': r'$end'},
        },
      },
    });
    final media = PlayMediaLayerBuilder(
      ownerId: play.revisionId,
      visualResolver: MapPlayVisualAssetResolver(const {}),
      videoResolver: MapPlayVideoAssetResolver(const {}),
      mediaCoordinator: ActiveMediaCoordinator(),
      videoControllerFactory: (_) =>
          throw StateError('Video controller must not be requested.'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaySurface(play: play, mediaBuilder: media.call),
        ),
      ),
    );

    expect(find.byType(ResolvedPlayVisual), findsOneWidget);
    expect(find.text('Where is this?'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(PlayVisualUnavailable), findsOneWidget);
  });

  testWidgets('authored piano input resolves the reference sequence', (
    tester,
  ) async {
    final play = _fixture('play_it_back.json');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlaySurface(play: play)),
      ),
    );

    expect(find.text('Play it back.'), findsOneWidget);
    await tester.tap(find.text('C'));
    await tester.tap(find.text('E'));
    await tester.tap(find.text('G'));
    await tester.pump();

    expect(find.text('C · E · G'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('matchstick Play renders and resolves entirely from data', (
    tester,
  ) async {
    final play = _fixture('move_one_match.json');
    final unsolved = _canvasFixture('puzzle_match_01.json');
    final solved = _canvasFixture('puzzle_match_01_solved.json');
    final manipulation = <bool>[];
    final media = PlayMediaLayerBuilder(
      ownerId: play.revisionId,
      visualResolver: MapPlayVisualAssetResolver(const {}),
      videoResolver: MapPlayVideoAssetResolver(const {}),
      canvasResolver: MapPlayCanvasAssetResolver({
        unsolved.id: unsolved,
        solved.id: solved,
      }),
      mediaCoordinator: ActiveMediaCoordinator(),
      videoControllerFactory: (_) =>
          throw StateError('Video controller must not be requested.'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 400,
              child: PlaySurface(
                play: play,
                mediaBuilder: media.call,
                onDirectManipulationChanged: manipulation.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Move one match.'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Matchstick equation: 6 plus 4 equals 4'),
      findsOneWidget,
    );

    await tester.drag(
      find.bySemanticsLabel('Move match'),
      const Offset(-56, -24),
    );
    await tester.pumpAndSettle();

    expect(manipulation, [true, false]);
    expect(find.text('8 − 4 = 4'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Solved matchstick equation: 8 minus 4 equals 4'),
      findsOneWidget,
    );
    expect(find.text('Done'), findsOneWidget);
  });
}
