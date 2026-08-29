import 'dart:convert';

import 'package:event_delivery/event_delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/consumer_onboarding.dart';
import 'package:mosaic_app/consumer_runtime.dart';
import 'package:mosaic_app/onboarding_localizations.dart';
import 'package:play_schema/play_schema.dart';

const _actorToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
final _actorAccess = ActorAccessIdentity(
  actorId: 'actor_onboarding',
  accessToken: _actorToken,
);

final class _MemoryConsumerState implements ConsumerLocalState {
  _MemoryConsumerState({
    ConsumerPreferences? preferences,
    this.onboardingCompleted = false,
  }) : preferences = preferences ?? ConsumerPreferences();

  ConsumerPreferences preferences;
  bool onboardingCompleted;
  var preferenceWrites = 0;

  @override
  Future<ConsumerPreferences> readPreferences() async => preferences;

  @override
  Future<void> writePreferences(ConsumerPreferences value) async {
    preferenceWrites += 1;
    preferences = value;
  }

  @override
  Future<bool> readOnboardingCompleted() async => onboardingCompleted;

  @override
  Future<void> writeOnboardingCompleted(bool completed) async {
    onboardingCompleted = completed;
  }

  @override
  Future<ConsumerFeedResume?> readFeedResume() async => null;

  @override
  Future<void> writeFeedResume(ConsumerFeedResume state) async {}

  @override
  Future<void> clearFeedResume() async {}

  @override
  Future<ConsumerFeedCache?> readRecentFeed({
    required PlayCapabilityEnvelope capabilities,
  }) async => null;

  @override
  Future<void> writeRecentFeed(ConsumerFeedCache state) async {}

  @override
  Future<void> clearRecentFeed() async {}
}

ConsumerRuntime _runtime(
  _MemoryConsumerState state, {
  int preferenceStatus = 204,
  VoidCallback? onPreferencePut,
}) {
  final client = MockClient((request) async {
    if (request.url.path == '/v1/topics') {
      final query = request.url.queryParameters['q']?.toLowerCase() ?? '';
      const topics = <Map<String, String>>[
        <String, String>{'id': 'science', 'label': 'Science'},
        <String, String>{'id': 'history', 'label': 'History'},
        <String, String>{'id': 'travel', 'label': 'Travel'},
      ];
      final filtered = topics
          .where((topic) => topic['label']!.toLowerCase().contains(query))
          .toList(growable: false);
      return http.Response(
        jsonEncode(<String, Object?>{'topics': filtered}),
        200,
      );
    }
    if (request.url.path == '/v1/actors') {
      return http.Response('{}', 201);
    }
    if (request.url.path == '/v1/actors/actor_onboarding/preferences') {
      onPreferencePut?.call();
      return http.Response('', preferenceStatus);
    }
    return http.Response('{}', 404);
  });
  return ConsumerRuntime(
    api: ConsumerApiClient(
      baseUri: Uri.parse('https://api.example.test/'),
      actorAccess: _actorAccess,
      client: client,
    ),
    localState: state,
    capabilities: PlayCapabilityEnvelope.m1(),
  );
}

Widget _app({
  required ConsumerRuntime runtime,
  required VoidCallback onFinished,
  Locale locale = const Locale('en'),
  double textScale = 1,
  bool disableAnimations = false,
  bool gate = false,
  Duration preferenceSyncDebounce = Duration.zero,
  Duration topicSearchDebounce = Duration.zero,
}) {
  final onboarding = gate
      ? ConsumerOnboardingGate(
          runtime: runtime,
          child: const Scaffold(body: Center(child: Text('Feed ready'))),
        )
      : ConsumerOnboarding(
          runtime: runtime,
          onFinished: onFinished,
          preferenceSyncDebounce: preferenceSyncDebounce,
          topicSearchDebounce: topicSearchDebounce,
        );
  return MaterialApp(
    locale: locale,
    supportedLocales: MosaicOnboardingStrings.supportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<Object>>[
      MosaicOnboardingStrings.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: onboarding,
    ),
  );
}

void main() {
  testWidgets(
    'interest and learning selections stay independent through back and finish',
    (tester) async {
      final state = _MemoryConsumerState();
      final runtime = _runtime(state);
      addTearDown(runtime.close);
      var finished = false;

      await tester.pumpWidget(
        _app(runtime: runtime, onFinished: () => finished = true),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'sci');
      await tester.pumpAndSettle();
      expect(find.text('Science'), findsOneWidget);
      expect(find.text('History'), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('topic-science')));
      await tester.pumpAndSettle();
      expect(state.preferences.interestTopicIds, const ['science']);
      expect(state.preferences.learningTopicIds, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey<String>('interests-continue')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Want to learn more about?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('topic-history')));
      await tester.pumpAndSettle();
      expect(state.preferences.interestTopicIds, const ['science']);
      expect(state.preferences.learningTopicIds, const ['history']);

      await tester.tap(find.byKey(const ValueKey<String>('learning-back')));
      await tester.pumpAndSettle();
      expect(find.text('What are you into?'), findsOneWidget);
      expect(state.preferences.interestTopicIds, const ['science']);
      expect(state.preferences.learningTopicIds, const ['history']);

      await tester.tap(
        find.byKey(const ValueKey<String>('interests-continue')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('learning-continue')));
      await tester.pumpAndSettle();

      expect(finished, isTrue);
      expect(state.onboardingCompleted, isTrue);
      expect(state.preferences.interestTopicIds, const ['science']);
      expect(state.preferences.learningTopicIds, const ['history']);
      expect(state.preferenceWrites, greaterThanOrEqualTo(2));
    },
  );

  testWidgets(
    'rapid topic taps persist locally but collapse to one remote replacement',
    (tester) async {
      final state = _MemoryConsumerState();
      var preferencePuts = 0;
      final runtime = _runtime(
        state,
        onPreferencePut: () => preferencePuts += 1,
      );
      addTearDown(runtime.close);

      await tester.pumpWidget(
        _app(
          runtime: runtime,
          onFinished: () {},
          preferenceSyncDebounce: const Duration(milliseconds: 250),
        ),
      );
      await tester.pumpAndSettle();

      for (final id in const ['science', 'history', 'travel']) {
        await tester.tap(find.byKey(ValueKey<String>('topic-$id')));
        await tester.pump();
      }

      expect(state.preferenceWrites, 3);
      expect(state.preferences.interestTopicIds.toSet(), {
        'science',
        'history',
        'travel',
      });
      expect(preferencePuts, 0);

      await tester.pump(const Duration(milliseconds: 249));
      expect(preferencePuts, 0);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pump();
      expect(preferencePuts, 1);
    },
  );

  testWidgets(
    'Surprise and Skip clear their own sets and remote failure never blocks',
    (tester) async {
      final state = _MemoryConsumerState(
        preferences: ConsumerPreferences(
          interestTopicIds: const ['travel'],
          learningTopicIds: const ['history'],
        ),
      );
      final runtime = _runtime(state, preferenceStatus: 503);
      addTearDown(runtime.close);
      var finished = false;

      await tester.pumpWidget(
        _app(runtime: runtime, onFinished: () => finished = true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Surprise me'));
      await tester.pumpAndSettle();
      expect(find.text('Want to learn more about?'), findsOneWidget);
      expect(state.preferences.interestTopicIds, isEmpty);
      expect(state.preferences.learningTopicIds, const ['history']);

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(finished, isTrue);
      expect(state.onboardingCompleted, isTrue);
      expect(state.preferences.interestTopicIds, isEmpty);
      expect(state.preferences.learningTopicIds, isEmpty);
    },
  );

  testWidgets('completed onboarding launches the feed directly', (
    tester,
  ) async {
    final state = _MemoryConsumerState(onboardingCompleted: true);
    final runtime = _runtime(state, preferenceStatus: 503);
    addTearDown(runtime.close);

    await tester.pumpWidget(
      _app(runtime: runtime, onFinished: () {}, gate: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Feed ready'), findsOneWidget);
    expect(find.text('What are you into?'), findsNothing);
  });

  testWidgets('selected topics expose explicit selected semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final state = _MemoryConsumerState();
    final runtime = _runtime(state);
    addTearDown(runtime.close);

    await tester.pumpWidget(_app(runtime: runtime, onFinished: () {}));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('topic-science')));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Science, selected'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('pseudo RTL survives 390x844 expanded text with reduced motion', (
    tester,
  ) async {
    final state = _MemoryConsumerState();
    final runtime = _runtime(state);
    addTearDown(runtime.close);

    await tester.pumpWidget(
      _app(
        runtime: runtime,
        onFinished: () {},
        locale: const Locale('ar', 'XB'),
        textScale: 1.6,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(ConsumerOnboarding));
    expect(Directionality.of(context), TextDirection.rtl);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey<String>('interests-continue')));
    await tester.pumpAndSettle();
    expect(Directionality.of(context), TextDirection.rtl);
    expect(tester.takeException(), isNull);
  });
}
