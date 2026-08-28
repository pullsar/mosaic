import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

PlayDocument _playWithInput({
  required Map<String, Object?> input,
  required Map<String, Object?> validation,
}) => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'defensive_input',
  'revisionId': 'rev_1',
  'format': 'solve',
  'classification': 'challenge',
  'topics': ['test'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 10,
  'assets': <String>[],
  'sources': <Object>[],
  'entryState': 'active',
  'states': {
    'active': {
      'presentation': {
        'layers': [
          {'type': 'text', 'role': 'prompt', 'value': 'Try it.'},
        ],
      },
      'input': input,
      'validation': validation,
      'transition': {'correct': r'$end', 'incorrect': 'active'},
    },
  },
});

void main() {
  testWidgets('PlaySurface rejects a piano sequence-length mismatch', (
    tester,
  ) async {
    final play = _playWithInput(
      input: {
        'type': 'piano_key',
        'keys': ['C4', 'E4', 'G4'],
        'sequenceLength': 2,
      },
      validation: {
        'type': 'ordered_sequence',
        'value': ['C4', 'E4', 'G4'],
      },
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PlaySurface(play: play))),
    );

    expect(find.byType(PlayInputUnavailable), findsOneWidget);
    expect(find.bySemanticsLabel('Piano keyboard'), findsNothing);
  });

  testWidgets('PlaySurface rejects overlapping authored drag targets', (
    tester,
  ) async {
    final play = _playWithInput(
      input: {
        'type': 'drag',
        'dragOrigin': {'x': 0.1, 'y': 0.1},
        'dragSize': {'width': 0.1, 'height': 0.1},
        'targets': [
          {'id': 'a', 'x': 0.5, 'y': 0.5, 'width': 0.2, 'height': 0.2},
          {'id': 'b', 'x': 0.6, 'y': 0.6, 'width': 0.2, 'height': 0.2},
        ],
      },
      validation: {'type': 'target_region', 'value': 'a'},
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PlaySurface(play: play))),
    );

    expect(find.byType(PlayInputUnavailable), findsOneWidget);
    expect(find.byType(PlayDragInput), findsNothing);
  });

  testWidgets('PlaySurface rejects a drag validator with no authored target', (
    tester,
  ) async {
    final play = _playWithInput(
      input: {
        'type': 'drag',
        'dragOrigin': {'x': 0.1, 'y': 0.1},
        'dragSize': {'width': 0.1, 'height': 0.1},
        'targets': [
          {'id': 'a', 'x': 0.5, 'y': 0.5, 'width': 0.2, 'height': 0.2},
        ],
      },
      validation: {'type': 'target_region', 'value': 'missing'},
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PlaySurface(play: play))),
    );

    expect(find.byType(PlayInputUnavailable), findsOneWidget);
    expect(find.byType(PlayDragInput), findsNothing);
  });
}
