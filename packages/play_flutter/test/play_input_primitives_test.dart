import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

void main() {
  test('piano spec is authored, bounded, and sequence-aware', () {
    final input = PlayInputDefinition(
      type: PlayInputType.pianoKey,
      properties: {
        'keys': ['C4', 'E4', 'G4'],
        'sequenceLength': 3,
      },
    );
    final validation = PlayValidationDefinition(
      type: PlayValidatorType.orderedSequence,
      value: ['C4', 'E4', 'G4'],
    );

    final spec = PlayPianoInputSpec.fromDefinitions(input, validation);
    expect(spec, isNotNull);
    expect(spec!.keys, ['C4', 'E4', 'G4']);
    expect(spec.sequenceLength, 3);
  });

  test('piano spec fails closed on malformed authored keys', () {
    final input = PlayInputDefinition(
      type: PlayInputType.pianoKey,
      properties: {
        'keys': ['C4', 'C4'],
        'sequenceLength': 2,
      },
    );
    final validation = PlayValidationDefinition(
      type: PlayValidatorType.orderedSequence,
      value: ['C4', 'C4'],
    );

    expect(PlayPianoInputSpec.fromDefinitions(input, validation), isNull);
  });

  testWidgets('piano emits one immutable sequence only when complete', (
    tester,
  ) async {
    final sequences = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayPianoInput(
            keys: const ['C4', 'E4', 'G4'],
            sequenceLength: 3,
            onSequence: sequences.add,
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('C4'));
    await tester.tap(find.bySemanticsLabel('E4'));
    expect(sequences, isEmpty);

    await tester.tap(find.bySemanticsLabel('G4'));
    expect(sequences, [
      ['C4', 'E4', 'G4'],
    ]);

    await tester.tap(find.bySemanticsLabel('C4'));
    expect(sequences, hasLength(1));
  });

  testWidgets('piano keeps every key tappable in a compact 56px allocation', (
    tester,
  ) async {
    final sequences = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 56,
              child: PlayPianoInput(
                keys: const ['C4', 'E4', 'G4'],
                sequenceLength: 3,
                onSequence: sequences.add,
              ),
            ),
          ),
        ),
      ),
    );

    for (final note in const ['C4', 'E4', 'G4']) {
      final key = find.bySemanticsLabel(note);
      expect(tester.getRect(key).height, greaterThanOrEqualTo(48));
      await tester.tap(key);
    }

    expect(sequences, [
      ['C4', 'E4', 'G4'],
    ]);
    expect(tester.takeException(), isNull);
  });

  test('drag spec rejects out-of-bounds authored targets', () {
    final input = PlayInputDefinition(
      type: PlayInputType.drag,
      properties: {
        'dragOrigin': {'x': 0.1, 'y': 0.1},
        'dragSize': {'width': 0.2, 'height': 0.1},
        'targets': [
          {'id': 'bad', 'x': 0.9, 'y': 0.2, 'width': 0.2, 'height': 0.2},
        ],
      },
    );

    expect(PlayDragInputSpec.fromDefinition(input), isNull);
  });

  testWidgets('drag owns manipulation until an authored target resolves', (
    tester,
  ) async {
    const spec = PlayDragInputSpec(
      origin: Offset(0.1, 0.5),
      size: Size(0.2, 0.1),
      handleLabel: 'Move match',
      targets: [
        PlayDragTarget(
          id: 'solution_a',
          rect: PlayNormalizedRect(x: 0.6, y: 0.2, width: 0.2, height: 0.2),
        ),
      ],
    );
    final targets = <String>[];
    final manipulation = <bool>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 400,
              child: PlayDragInput(
                spec: spec,
                onTarget: targets.add,
                onManipulationChanged: manipulation.add,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(
      find.bySemanticsLabel('Move match'),
      const Offset(200, -100),
    );
    await tester.pump();

    expect(targets, ['solution_a']);
    expect(manipulation, [true, false]);
  });

  testWidgets('replacing a drag spec mid-gesture releases the feed lock', (
    tester,
  ) async {
    final first = _runtimeDragSpec(const Offset(0.1, 0.5), 'solution_a');
    final replacement = _runtimeDragSpec(const Offset(0.2, 0.5), 'solution_b');
    final manipulation = <bool>[];

    await tester.pumpWidget(_dragTestSurface(first, manipulation));
    final gesture = await tester.startGesture(
      tester.getCenter(find.bySemanticsLabel('Move match')),
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(manipulation, [true]);

    await tester.pumpWidget(_dragTestSurface(replacement, manipulation));
    await tester.pump();

    expect(manipulation, [true, false]);
    await gesture.cancel();
  });

  testWidgets('disposing a drag mid-gesture releases the feed lock', (
    tester,
  ) async {
    final spec = _runtimeDragSpec(const Offset(0.1, 0.5), 'solution_a');
    final manipulation = <bool>[];

    await tester.pumpWidget(_dragTestSurface(spec, manipulation));
    final gesture = await tester.startGesture(
      tester.getCenter(find.bySemanticsLabel('Move match')),
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(manipulation, [true]);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    expect(manipulation, [true, false]);
    await gesture.cancel();
  });
}

PlayDragInputSpec _runtimeDragSpec(Offset origin, String targetId) =>
    PlayDragInputSpec(
      origin: origin,
      size: const Size(0.2, 0.1),
      handleLabel: 'Move match',
      targets: [
        PlayDragTarget(
          id: targetId,
          rect: const PlayNormalizedRect(
            x: 0.6,
            y: 0.2,
            width: 0.2,
            height: 0.2,
          ),
        ),
      ],
    );

Widget _dragTestSurface(PlayDragInputSpec spec, List<bool> manipulation) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox.square(
          dimension: 400,
          child: PlayDragInput(
            spec: spec,
            onTarget: (_) {},
            onManipulationChanged: manipulation.add,
          ),
        ),
      ),
    );
