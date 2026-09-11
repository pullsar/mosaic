import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/continuous_game_host.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

PlayDocument round(String id) => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': id,
  'revisionId': 'rev_1',
  'gameFamily': {'id': 'logic', 'revisionId': 'rev_1'},
  'format': 'solve',
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
          {'type': 'text', 'role': 'prompt', 'value': id},
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
      'transition': {'correct': 'result', 'incorrect': 'question'},
    },
    'result': {
      'presentation': {
        'layers': [
          {'type': 'text', 'role': 'reveal_title', 'value': 'Balanced.'},
        ],
      },
      'input': {'type': 'tap', 'label': 'Done'},
      'validation': {'type': 'none'},
      'transition': {'default': r'$end'},
    },
  },
});

Widget host({
  bool active = true,
  required NextGameRound next,
  bool accessible = false,
  double textScale = 1,
  bool effects = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      accessibleNavigation: accessible,
      textScaler: TextScaler.linear(textScale),
    ),
    child: ContinuousGameHost(
      play: round('First'),
      active: active,
      effectsEnabled: effects,
      prepareNext: next,
      builder: (context, attempt, feedback) => PlaySurface.controlled(
        session: attempt.session,
        onAction: attempt.captureActionHandler(),
        resolvedFeedback: feedback,
      ),
    ),
  ),
);

void main() {
  testWidgets('a modal pauses the result and does not resume automatically', (
    tester,
  ) async {
    await tester.pumpWidget(host(next: (_) async => round('Second')));
    await tester.pump();
    await tester.tap(find.text('A'));
    await tester.pump();
    final context = tester.element(find.byType(PlaySurface));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('Sound')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Second'), findsNothing);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(find.text('Next round'), findsOneWidget);
    expect(find.text('Second'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'scoring feedback is immediate, optional and never replayed by a timer',
    (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        host(effects: true, next: (_) async => round('Second')),
      );
      await tester.pump();
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(
        calls.where((call) => call == 'HapticFeedback.vibrate'),
        hasLength(1),
      );
      expect(calls.where((call) => call == 'SystemSound.play'), hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      expect(calls.where((call) => call == 'SystemSound.play'), hasLength(1));
      await tester.pumpWidget(
        host(effects: false, next: (_) async => round('First')),
      );
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(calls.where((call) => call == 'SystemSound.play'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'large text keeps scoring and Next round within a small viewport',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        host(
          accessible: true,
          textScale: 2,
          next: (_) async => round('Second'),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'scores without Done, then advances once into a different puzzle',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          next: (_) async {
            calls++;
            return round('Second');
          },
        ),
      );
      await tester.pump();
      await tester.tap(find.text('B'));
      await tester.pump();
      expect(find.text('First'), findsOneWidget);
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(find.text('Done'), findsNothing);
      expect(find.text('1 / 1'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 999));
      expect(find.text('Second'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(find.text('Second'), findsOneWidget);
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('offscreen completion cannot change the current puzzle', (
    tester,
  ) async {
    final pending = Completer<PlayDocument?>();
    await tester.pumpWidget(host(next: (_) => pending.future));
    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.pumpWidget(host(active: false, next: (_) => pending.future));
    pending.complete(round('Second'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Second'), findsNothing);
    await tester.pumpWidget(host(next: (_) async => round('Second')));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Next round'), findsOneWidget);
    expect(find.text('Second'), findsNothing);
    await tester.tap(find.text('Next round'));
    await tester.pump();
    expect(find.text('Second'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('accessible navigation holds the result until Next round', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(accessible: true, next: (_) async => round('Second')),
    );
    await tester.pump();
    await tester.tap(find.text('A'));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Second'), findsNothing);
    expect(find.text('Next round'), findsOneWidget);
    await tester.tap(find.text('Next round'));
    await tester.pump();
    expect(find.text('Second'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'failed supply remains retryable and never repeats the same answer',
    (tester) async {
      var requests = 0;
      await tester.pumpWidget(
        host(
          next: (_) async {
            requests++;
            return requests == 1 ? null : round('Second');
          },
        ),
      );
      await tester.pump();
      await tester.tap(find.text('A'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Next round'), findsOneWidget);
      expect(requests, 1);
      await tester.tap(find.text('Next round'));
      await tester.pump();
      expect(find.text('Second'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
