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

  testWidgets('authored drag resolves target and brackets feed paging lock', (
    tester,
  ) async {
    final play = _fixture('move_one_match.json');
    final manipulation = <bool>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 400,
              child: PlaySurface(
                play: play,
                onDirectManipulationChanged: manipulation.add,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Move one match.'), findsOneWidget);
    await tester.drag(
      find.bySemanticsLabel('Move match'),
      const Offset(176, -96),
    );
    await tester.pump();

    expect(manipulation, [true, false]);
    expect(find.text('Solved'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });
}
