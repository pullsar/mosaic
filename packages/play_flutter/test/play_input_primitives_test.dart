import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

void main() {
  testWidgets('multiple choice toggles options and submits a stable set', (
    tester,
  ) async {
    final submitted = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayMultipleChoiceInput(
            options: const [
              PlayOption(id: 'beacon', label: 'Beacon'),
              PlayOption(id: 'orbit', label: 'Orbit'),
              PlayOption(id: 'comet', label: 'Comet'),
            ],
            onSubmit: submitted.add,
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Orbit'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Beacon'));
    await tester.pump();
    await tester.tap(find.byTooltip('Submit selection'));

    expect(submitted, [
      <String>['beacon', 'orbit'],
    ]);
  });

  testWidgets('a new pickup interrupts the return without a late snap', (
    tester,
  ) async {
    final locks = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: PlayDragInput(
              spec: _runtimeDragSpec(const Offset(.1, .1), 'target'),
              onTarget: (_) => fail('miss is not an answer'),
              onManipulationChanged: locks.add,
            ),
          ),
        ),
      ),
    );
    final object = find.byKey(const ValueKey<String>('play-drag-object'));
    final first = await tester.startGesture(tester.getCenter(object));
    await first.moveBy(const Offset(25, 0));
    await first.moveBy(const Offset(50, 0));
    await first.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 35));
    final second = await tester.startGesture(tester.getCenter(object));
    final pickedUp = tester.getRect(object);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(object), pickedUp);
    expect(locks, [true, false, true]);
    await second.cancel();
    await tester.pumpAndSettle();
    expect(locks.last, isFalse);
  });

  testWidgets('drag pickup lifts the object and marks an eligible target', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: PlayDragInput(
              spec: const PlayDragInputSpec(
                origin: const Offset(.1, .1),
                size: const Size(.2, .1),
                handleLabel: 'Move match',
                handleStyle: PlayDragHandleStyle.matchstick,
                showTargetHints: true,
                targets: const [
                  PlayDragTarget(
                    id: 'target',
                    rect: PlayNormalizedRect(
                      x: .6,
                      y: .2,
                      width: .2,
                      height: .2,
                    ),
                  ),
                ],
              ),
              onTarget: (_) {},
            ),
          ),
        ),
      ),
    );
    final object = find.byKey(const ValueKey<String>('play-drag-object'));
    expect(
      find.byKey(const ValueKey<String>('play-drag-matchstick-head')),
      findsOneWidget,
    );
    final target = find.byKey(
      const ValueKey<String>('play-drag-target-glow:target'),
    );
    final gesture = await tester.startGesture(tester.getCenter(object));
    // Establish the pan before moving to the target. The gesture arena consumes
    // the motion that exceeds its touch slop, so a single long test move would
    // leave the object short of the target.
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();

    final lift = tester.widget<AnimatedScale>(
      find.byKey(const ValueKey<String>('play-drag-object-motion')),
    );
    expect(lift.scale, 1.06);
    final glow = tester.widget<AnimatedContainer>(target);
    final border = (glow.decoration! as BoxDecoration).border! as Border;
    expect(
      border.top.color,
      Theme.of(tester.element(object)).colorScheme.primary,
    );

    await gesture.cancel();
  });

  testWidgets('horizontal drag matchstick puts its head at the end', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: PlayDragInput(
              spec: const PlayDragInputSpec(
                origin: Offset(.2, .2),
                size: Size(.2, .05),
                handleStyle: PlayDragHandleStyle.matchstick,
                targets: [],
              ),
              onTarget: (_) {},
            ),
          ),
        ),
      ),
    );

    final head = tester.widget<Align>(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('play-drag-matchstick-head')),
        matching: find.byType(Align),
      ),
    );
    expect(head.alignment, Alignment.centerRight);
  });

  testWidgets('drag lift is immediate with reduced motion', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Center(
            child: SizedBox.square(
              dimension: 300,
              child: PlayDragInput(
                spec: _runtimeDragSpec(const Offset(.1, .1), 'target'),
                onTarget: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    final object = find.byKey(const ValueKey<String>('play-drag-object'));
    final gesture = await tester.startGesture(tester.getCenter(object));
    await tester.pump();

    expect(
      tester
          .widget<AnimatedScale>(
            find.byKey(const ValueKey<String>('play-drag-object-motion')),
          )
          .scale,
      1,
    );
    await gesture.cancel();
  });

  testWidgets('adjacent thin targets select the visible destination', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: PlayDragInput(
              spec: const PlayDragInputSpec(
                origin: Offset(.1, .1),
                size: Size(.03, .14),
                handleLabel: 'Move match',
                targets: [
                  PlayDragTarget(
                    id: 'first',
                    rect: PlayNormalizedRect(
                      x: .5,
                      y: .4,
                      width: .03,
                      height: .14,
                    ),
                  ),
                  PlayDragTarget(
                    id: 'second',
                    rect: PlayNormalizedRect(
                      x: .55,
                      y: .4,
                      width: .03,
                      height: .14,
                    ),
                  ),
                ],
              ),
              onTarget: selected.add,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Move match'));
    await tester.pump();
    final stage = tester.getRect(find.byType(PlayDragInput));
    await tester.tapAt(stage.topLeft + const Offset(.515 * 300, .47 * 300));
    expect(selected, ['first']);
  });

  for (final reduced in [false, true]) {
    testWidgets('missed drop returns with reduced motion $reduced', (
      tester,
    ) async {
      final locks = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Center(
              child: SizedBox.square(
                dimension: 300,
                child: PlayDragInput(
                  spec: _runtimeDragSpec(const Offset(.1, .1), 'target'),
                  onTarget: (_) => fail('miss is not an answer'),
                  onManipulationChanged: locks.add,
                ),
              ),
            ),
          ),
        ),
      );
      final object = find.byKey(const ValueKey<String>('play-drag-object'));
      final origin = tester.getRect(object);
      final gesture = await tester.startGesture(tester.getCenter(object));
      await gesture.moveBy(const Offset(25, 0));
      await gesture.moveBy(const Offset(35, 0));
      await tester.pump();
      final moved = tester.getRect(object);
      expect(moved.left, greaterThan(origin.left));
      await gesture.up();
      await tester.pump();
      expect(locks.last, isFalse);
      if (reduced) {
        expect(tester.getRect(object), origin);
      } else {
        expect(tester.getRect(object).left, greaterThan(origin.left));
        await tester.pump(const Duration(milliseconds: 70));
        expect(tester.getRect(object).left, greaterThan(origin.left));
        expect(tester.getRect(object).left, lessThan(moved.left));
      }
      await tester.pumpAndSettle();
      expect(tester.getRect(object), origin);
    });
  }

  testWidgets('thin alternate destination has a full touch target', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: PlayDragInput(
              spec: const PlayDragInputSpec(
                origin: Offset(.1, .1),
                size: Size(.03, .14),
                handleLabel: 'Move match',
                targets: [
                  PlayDragTarget(
                    id: 'slot',
                    label: 'Opening',
                    rect: PlayNormalizedRect(
                      x: .6,
                      y: .4,
                      width: .03,
                      height: .14,
                    ),
                  ),
                ],
              ),
              onTarget: selected.add,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Move match'));
    await tester.pump();
    final target = find.byKey(
      const ValueKey<String>('play-drag-alternate-target:slot'),
    );
    expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
    await tester.tapAt(tester.getCenter(target) + const Offset(18, 0));
    expect(selected, ['slot']);
  });

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

  test('drag spec preserves the authored matchstick appearance', () {
    final spec = PlayDragInputSpec.fromDefinition(
      PlayInputDefinition(
        type: PlayInputType.drag,
        properties: {
          'dragOrigin': {'x': .2, 'y': .2},
          'dragSize': {'width': .04, 'height': .16},
          'targets': [
            {'id': 'slot', 'x': .6, 'y': .2, 'width': .04, 'height': .16},
          ],
          'handleStyle': 'matchstick',
        },
      ),
    );

    expect(spec, isNotNull);
    expect(spec!.handleStyle, PlayDragHandleStyle.matchstick);
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

  testWidgets('piano depresses and emits one note on pointer down', (
    tester,
  ) async {
    final notes = <String>[];
    final sequences = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayPianoInput(
            keys: const ['C4'],
            sequenceLength: 1,
            onNote: notes.add,
            onSequence: sequences.add,
          ),
        ),
      ),
    );

    final key = find.bySemanticsLabel('C4');
    final gesture = await tester.startGesture(tester.getCenter(key));
    await tester.pump();

    expect(notes, ['C4']);
    expect(sequences, [
      <String>['C4'],
    ]);
    expect(
      tester
          .widget<AnimatedScale>(
            find.byKey(const ValueKey<String>('play-piano-key:C4')),
          )
          .scale,
      .97,
    );

    await gesture.up();
    await tester.pump();
    expect(notes, ['C4']);
    expect(sequences, [
      <String>['C4'],
    ]);
  });

  testWidgets('piano scrolling never enters a sequence', (tester) async {
    final sequences = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 140,
            height: 110,
            child: PlayPianoInput(
              keys: const ['C4', 'D4', 'E4', 'F4'],
              sequenceLength: 1,
              onSequence: sequences.add,
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.bySemanticsLabel('C4')),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(-80, 0));
    await gesture.up();
    await tester.pump();

    expect(sequences, isEmpty);
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

  testWidgets('semantic drag activation requires an explicit destination', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final targets = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 300,
              child: PlayDragInput(
                spec: _multiTargetRuntimeDragSpec(),
                onTarget: targets.add,
              ),
            ),
          ),
        ),
      );

      tester.semantics.tap(find.semantics.byLabel('Move match'));
      await tester.pump();

      expect(targets, isEmpty);
      expect(find.bySemanticsLabel('Left opening'), findsOneWidget);
      expect(find.bySemanticsLabel('Right opening'), findsOneWidget);

      tester.semantics.tap(find.semantics.byLabel('Right opening'));
      await tester.pump();

      expect(targets, ['solution']);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('touch drag activation requires an explicit destination', (
    tester,
  ) async {
    final targets = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: PlayDragInput(
              spec: _multiTargetRuntimeDragSpec(),
              onTarget: targets.add,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Move match'));
    await tester.pump();

    expect(targets, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('play-drag-alternate-target:decoy')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('play-drag-alternate-target:solution')),
    );
    await tester.pump();

    expect(targets, ['solution']);
  });

  testWidgets('keyboard drag activation can choose or cancel a destination', (
    tester,
  ) async {
    final targets = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 300,
            child: PlayDragInput(
              spec: _multiTargetRuntimeDragSpec(),
              onTarget: targets.add,
            ),
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(targets, isEmpty);
    expect(find.bySemanticsLabel('Left opening'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.bySemanticsLabel('Left opening'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(targets, ['solution']);
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

PlayDragInputSpec _multiTargetRuntimeDragSpec() => const PlayDragInputSpec(
  origin: Offset(0.48, 0.35),
  size: Size(0.04, 0.2),
  handleLabel: 'Move match',
  targets: [
    PlayDragTarget(
      id: 'decoy',
      label: 'Left opening',
      rect: PlayNormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
    ),
    PlayDragTarget(
      id: 'solution',
      label: 'Right opening',
      rect: PlayNormalizedRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2),
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
