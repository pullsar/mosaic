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

PlayDocument _continuousRevealPlay() => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'continuous_reveal',
  'revisionId': 'continuous_reveal_rev_1',
  'format': 'solve',
  'classification': 'challenge',
  'topics': ['puzzles'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 8,
  'assets': ['continuous_canvas'],
  'sources': <Object>[],
  'entryState': 'solve',
  'states': {
    'solve': {
      'presentation': {
        'layers': [
          {'type': 'canvas', 'role': 'media', 'assetId': 'continuous_canvas'},
          {'type': 'text', 'role': 'prompt', 'value': 'Move one match.'},
        ],
      },
      'input': {
        'type': 'single_choice',
        'options': [
          {'id': 'solve', 'label': 'Solve'},
          {'id': 'leave', 'label': 'Leave it'},
        ],
      },
      'validation': {'type': 'equals', 'value': 'solve'},
      'transition': {'correct': 'reveal', 'incorrect': 'reveal'},
    },
    'reveal': {
      'presentation': {
        'layers': [
          {'type': 'canvas', 'role': 'media', 'assetId': 'continuous_canvas'},
          {'type': 'text', 'role': 'reveal_title', 'value': '8 − 4 = 4'},
          {
            'type': 'text',
            'role': 'reveal_detail',
            'value': 'One match changes the six to eight.',
          },
        ],
      },
      'input': {'type': 'tap', 'label': 'Done'},
      'validation': {'type': 'none'},
      'transition': {'default': r'$end'},
    },
  },
});

PlayDocument _duplicateMediaRevealPlay() => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'duplicate_media_reveal',
  'revisionId': 'duplicate_media_reveal_rev_1',
  'format': 'discover',
  'classification': 'challenge',
  'topics': ['patterns'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 8,
  'assets': ['continuous_canvas', 'inserted_image'],
  'sources': <Object>[],
  'entryState': 'look',
  'states': {
    'look': {
      'presentation': {
        'layers': [
          {'type': 'canvas', 'role': 'media', 'assetId': 'continuous_canvas'},
          {'type': 'canvas', 'role': 'media', 'assetId': 'continuous_canvas'},
          {'type': 'text', 'role': 'prompt', 'value': 'Look closer.'},
        ],
      },
      'input': {
        'type': 'single_choice',
        'options': [
          {'id': 'reveal', 'label': 'Reveal'},
          {'id': 'wait', 'label': 'Wait'},
        ],
      },
      'validation': {'type': 'equals', 'value': 'reveal'},
      'transition': {'correct': 'reveal', 'incorrect': 'look'},
    },
    'reveal': {
      'presentation': {
        'layers': [
          {'type': 'image', 'role': 'media', 'assetId': 'inserted_image'},
          {'type': 'canvas', 'role': 'media', 'assetId': 'continuous_canvas'},
          {'type': 'canvas', 'role': 'media', 'assetId': 'continuous_canvas'},
          {'type': 'text', 'role': 'reveal_title', 'value': 'Two layers.'},
        ],
      },
      'input': {'type': 'tap', 'label': 'Done'},
      'validation': {'type': 'none'},
      'transition': {'default': r'$end'},
    },
  },
});

PlayCanvasAsset _continuousCanvas() => PlayCanvasAsset(
  id: 'continuous_canvas',
  semanticLabel: 'Matchstick equation',
  elements: [
    PlayCanvasLine(
      start: const Offset(0.2, 0.5),
      end: const Offset(0.8, 0.5),
      width: 0.025,
      tone: PlayCanvasTone.accent,
    ),
  ],
);

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
      ownerId: playMediaOwnerId(play),
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
      ownerId: playMediaOwnerId(play),
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

    final canvasStage = tester.getSize(
      find.descendant(
        of: find.byType(PlayCanvas),
        matching: find.byType(CustomPaint),
      ),
    );
    await tester.drag(
      find.bySemanticsLabel('Move match'),
      Offset(-0.14 * canvasStage.width, -0.06 * canvasStage.height),
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

  testWidgets('reveal preserves the dominant canvas element in place', (
    tester,
  ) async {
    const viewport = Size(390, 844);
    const insets = EdgeInsets.only(top: 47, bottom: 34);
    final play = _continuousRevealPlay();
    final canvas = _continuousCanvas();
    final composition = PlayViewportComposition.fromConstraints(
      const BoxConstraints.tightFor(width: 390, height: 844),
      safeInsets: insets,
    );
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
          data: const MediaQueryData(size: viewport, padding: insets),
          child: Scaffold(
            body: PlaySurface(
              play: play,
              mediaBuilder: (context, layer) => PlayCanvas(asset: canvas),
            ),
          ),
        ),
      ),
    );

    final stageBefore = tester.getRect(
      find.byKey(const ValueKey<String>('play-stage')),
    );
    expect(stageBefore, composition.stageRect);
    final canvasElementBefore = tester.element(find.byType(PlayCanvas));

    await tester.tap(find.widgetWithText(FilledButton, 'Solve'));
    await tester.pumpAndSettle();

    final stageAfter = tester.getRect(
      find.byKey(const ValueKey<String>('play-stage')),
    );
    final canvasElementAfter = tester.element(find.byType(PlayCanvas));
    final promptRect = tester.getRect(
      find.byKey(const ValueKey<String>('play-prompt')),
    );
    final inputRect = tester.getRect(
      find.byKey(const ValueKey<String>('play-input')),
    );
    final textScroll = find.byKey(
      const ValueKey<String>('play-text-scroll'),
    );
    final textScrollRect = tester.getRect(textScroll);

    expect(identical(canvasElementBefore, canvasElementAfter), isTrue);
    expect(stageAfter, stageBefore);
    expect(find.text('Move one match.'), findsNothing);
    expect(find.text('One match changes the six to eight.'), findsOneWidget);
    expect(
      _containsRect(promptRect, tester.getRect(find.text('8 − 4 = 4'))),
      isTrue,
    );
    expect(
      _containsRect(
        promptRect,
        tester.getRect(find.text('One match changes the six to eight.')),
      ),
      isTrue,
    );
    expect(_containsRect(promptRect, textScrollRect), isTrue);
    expect(textScrollRect.overlaps(stageAfter), isFalse);
    expect(textScrollRect.overlaps(inputRect), isFalse);
    expect(
      tester.widget<SingleChildScrollView>(textScroll).clipBehavior,
      Clip.hardEdge,
    );
  });

  testWidgets('reduced motion reveals directly without moving the stage', (
    tester,
  ) async {
    const viewport = Size(390, 844);
    const insets = EdgeInsets.only(top: 47, bottom: 34);
    final play = _continuousRevealPlay();
    final canvas = _continuousCanvas();
    final composition = PlayViewportComposition.fromConstraints(
      const BoxConstraints.tightFor(width: 390, height: 844),
      safeInsets: insets,
    );
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
            disableAnimations: true,
          ),
          child: Scaffold(
            body: PlaySurface(
              play: play,
              mediaBuilder: (context, layer) => PlayCanvas(asset: canvas),
            ),
          ),
        ),
      ),
    );

    final stageBefore = tester.getRect(
      find.byKey(const ValueKey<String>('play-stage')),
    );
    expect(stageBefore, composition.stageRect);
    final canvasElementBefore = tester.element(find.byType(PlayCanvas));

    await tester.tap(find.widgetWithText(FilledButton, 'Solve'));
    await tester.pump();

    expect(find.text('8 − 4 = 4'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('play-stage'))),
      stageBefore,
    );
    expect(
      identical(canvasElementBefore, tester.element(find.byType(PlayCanvas))),
      isTrue,
    );
  });

  testWidgets(
    'duplicate media layers keep unique stable identities on reveal',
    (tester) async {
      final play = _duplicateMediaRevealPlay();
      final canvas = _continuousCanvas();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaySurface(
              play: play,
              mediaBuilder: (context, layer) => PlayCanvas(asset: canvas),
            ),
          ),
        ),
      );

      final before = tester.elementList(find.byType(PlayCanvas)).toList();
      expect(before, hasLength(2));
      expect(tester.takeException(), isNull);

      await tester.tap(find.widgetWithText(FilledButton, 'Reveal'));
      await tester.pumpAndSettle();

      final after = tester.elementList(find.byType(PlayCanvas)).toList();
      expect(after, hasLength(3));
      expect(identical(before[0], after[1]), isTrue);
      expect(identical(before[1], after[2]), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

bool _containsRect(Rect outer, Rect inner) =>
    inner.left >= outer.left &&
    inner.top >= outer.top &&
    inner.right <= outer.right &&
    inner.bottom <= outer.bottom;
