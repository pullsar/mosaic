import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_engine/play_engine.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

PlayDocument _play({required String id, required String prompt}) =>
    PlayDocument.fromJson({
      'schemaVersion': 1,
      'id': id,
      'revisionId': '${id}_rev_1',
      'format': 'guess',
      'classification': 'challenge',
      'topics': <String>[],
      'learningTopics': <String>[],
      'estimatedDurationSec': 10,
      'assets': <String>[],
      'sources': <Object>[],
      'entryState': 'question',
      'states': {
        'question': {
          'presentation': {
            'layers': [
              {'type': 'text', 'role': 'prompt', 'value': prompt},
            ],
          },
          'input': {
            'type': 'single_choice',
            'options': [
              {'id': 'a', 'label': 'A'},
              {'id': 'b', 'label': 'B'},
            ],
          },
          'validation': {'type': 'equals', 'value': 'a'},
          'transition': {'correct': 'reveal', 'incorrect': 'reveal'},
        },
        'reveal': {
          'presentation': {
            'layers': [
              {'type': 'text', 'role': 'reveal_title', 'value': 'Reveal $id'},
            ],
          },
          'input': {'type': 'tap', 'label': 'Done'},
          'validation': {'type': 'none'},
          'transition': {'default': r'$end'},
        },
      },
    });

void main() {
  testWidgets('recycled PlaySurface restarts when revision identity changes', (
    tester,
  ) async {
    const surfaceKey = ValueKey<String>('recycled-play-surface');
    final first = _play(id: 'first', prompt: 'First prompt');
    final second = _play(id: 'second', prompt: 'Second prompt');

    await tester.pumpWidget(
      MaterialApp(
        home: PlaySurface(key: surfaceKey, play: first),
      ),
    );
    await tester.tap(find.text('A'));
    await tester.pump();
    expect(find.text('Reveal first'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: PlaySurface(key: surfaceKey, play: second),
      ),
    );
    await tester.pump();

    expect(find.text('Second prompt'), findsOneWidget);
    expect(find.text('Reveal first'), findsNothing);
  });

  testWidgets('same immutable revision preserves in-progress session', (
    tester,
  ) async {
    const surfaceKey = ValueKey<String>('stable-play-surface');
    final firstInstance = _play(id: 'stable', prompt: 'Stable prompt');
    final equivalentRevision = _play(id: 'stable', prompt: 'Ignored rewrite');

    await tester.pumpWidget(
      MaterialApp(
        home: PlaySurface(key: surfaceKey, play: firstInstance),
      ),
    );
    await tester.tap(find.text('A'));
    await tester.pump();
    expect(find.text('Reveal stable'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: PlaySurface(key: surfaceKey, play: equivalentRevision),
      ),
    );
    await tester.pump();

    expect(find.text('Reveal stable'), findsOneWidget);
    expect(find.text('Ignored rewrite'), findsNothing);
  });

  testWidgets('controlled surface delegates actions to its session owner', (
    tester,
  ) async {
    final play = _play(id: 'controlled', prompt: 'Controlled prompt');
    const engine = PlayEngine();
    var session = engine.start(play);
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return PlaySurface.controlled(
              session: session,
              onAction: (action) {
                rebuild(() => session = engine.apply(session, action).session);
              },
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('A'));
    await tester.pump();
    expect(find.text('Reveal controlled'), findsOneWidget);

    rebuild(() {});
    await tester.pump();
    expect(find.text('Reveal controlled'), findsOneWidget);
  });

  testWidgets('controlled surface never advances without owner state', (
    tester,
  ) async {
    final play = _play(id: 'delegated', prompt: 'Delegated prompt');
    const engine = PlayEngine();
    final actions = <PlayAction>[];

    await tester.pumpWidget(
      MaterialApp(
        home: PlaySurface.controlled(
          session: engine.start(play),
          onAction: actions.add,
        ),
      ),
    );
    await tester.tap(find.text('A'));
    await tester.pump();

    expect(actions, hasLength(1));
    expect(find.text('Delegated prompt'), findsOneWidget);
    expect(find.text('Reveal delegated'), findsNothing);
  });

  testWidgets('ended session replaces the old input with terminal action', (
    tester,
  ) async {
    final play = _play(id: 'terminal', prompt: 'Terminal prompt');
    const engine = PlayEngine();
    var session = engine.start(play);
    session = engine.apply(session, const ChoiceAction('a')).session;
    session = engine.apply(session, const TapAction()).session;

    await tester.pumpWidget(
      MaterialApp(
        home: PlaySurface.controlled(
          session: session,
          onAction: (_) => fail('ended input must not dispatch'),
          terminal: const Text('Replay'),
        ),
      ),
    );

    expect(find.text('Done'), findsNothing);
    expect(find.text('Replay'), findsOneWidget);
  });
}
