import 'dart:async';
import 'dart:convert';

import 'package:event_delivery/event_delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/consumer_runtime.dart';
import 'package:mosaic_app/consumer_search.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_schema/play_schema.dart';

const _actorToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
final _actorAccess = ActorAccessIdentity(
  actorId: 'actor_search_ui',
  accessToken: _actorToken,
);

final class _MemoryState implements ConsumerLocalState {
  @override
  Future<ConsumerPreferences> readPreferences() async => ConsumerPreferences();
  @override
  Future<void> writePreferences(ConsumerPreferences preferences) async {}
  @override
  Future<bool> readOnboardingCompleted() async => true;
  @override
  Future<void> writeOnboardingCompleted(bool completed) async {}
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
  @override
  Future<ConsumerPlayActionState?> readPlayActionState(String playId) async =>
      null;
  @override
  Future<void> writePlayActionState(ConsumerPlayActionState state) async {}
  @override
  Future<List<String>> readMutedTopicIds() async => const <String>[];
  @override
  Future<void> writeMutedTopicIds(Iterable<String> topicIds) async {}
}

final class _RecordingTelemetry implements Telemetry {
  final events = <({String name, Map<String, Object?> payload})>[];

  @override
  void event(String name, Map<String, Object?> payload) {
    events.add((name: name, payload: Map<String, Object?>.of(payload)));
  }

  @override
  void error(Object error, StackTrace stackTrace, {String? operation}) {}

  @override
  FutureOr<T> trace<T>(String operation, FutureOr<T> Function() body) => body();
}

Widget _app(ConsumerRuntime runtime, _RecordingTelemetry telemetry) =>
    MaterialApp(
      home: ConsumerDiscoverySearch(
        runtime: runtime,
        telemetry: telemetry,
        debounce: Duration.zero,
      ),
    );

http.Response _searchResponse({
  required String query,
  required String label,
  required String topicId,
  required String hashChar,
  String intent = 'interest',
}) => http.Response(
  jsonEncode(<String, Object?>{
    'requestId': 'request_$query',
    'intent': intent,
    'queryHash': hashChar * 64,
    'resultCount': 1,
    'items': <Object?>[
      <String, Object?>{
        'kind': 'topic',
        'position': 0,
        'topicId': topicId,
        'label': label,
        'matchKind': 'topic_prefix',
      },
    ],
    'nextCursor': null,
  }),
  200,
);

void main() {
  testWidgets('newer search result fences a slower stale response', (
    tester,
  ) async {
    final science = Completer<http.Response>();
    final travel = Completer<http.Response>();
    final telemetry = _RecordingTelemetry();
    final runtime = ConsumerRuntime(
      api: ConsumerApiClient(
        baseUri: Uri.parse('https://api.example.test/'),
        actorAccess: _actorAccess,
        client: MockClient((request) async {
          if (request.url.path == '/v1/topics') {
            return http.Response('{"topics":[]}', 200);
          }
          if (request.url.path == '/v1/actors') return http.Response('{}', 201);
          if (request.url.path == '/v1/search') {
            final body = jsonDecode(request.body) as Map<String, Object?>;
            return switch (body['query']) {
              'sci' => science.future,
              'tra' => travel.future,
              _ => http.Response('{}', 400),
            };
          }
          return http.Response('{}', 404);
        }),
      ),
      localState: _MemoryState(),
      capabilities: PlayCapabilityEnvelope.m1(),
    );
    addTearDown(runtime.close);

    await tester.pumpWidget(_app(runtime, telemetry));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('search-field')),
      'sci',
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('search-field')),
      'tra',
    );
    await tester.pump();

    travel.complete(
      _searchResponse(
        query: 'tra',
        label: 'Travel',
        topicId: 'travel',
        hashChar: 'b',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Travel'), findsOneWidget);

    science.complete(
      _searchResponse(
        query: 'sci',
        label: 'Science',
        topicId: 'science',
        hashChar: 'a',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Travel'), findsOneWidget);
    expect(find.text('Science'), findsNothing);

    final submitted = telemetry.events
        .where((event) => event.name == 'search_submitted')
        .toList();
    expect(submitted, hasLength(1));
    expect(submitted.single.payload['queryHash'], 'b' * 64);
    expect(submitted.single.payload.containsKey('query'), isFalse);
    expect(submitted.single.payload.values.contains('tra'), isFalse);
  });

  testWidgets(
    'refresh keeps old results visible and learning intent remains distinct',
    (tester) async {
      final piano = Completer<http.Response>();
      final intents = <String>[];
      final telemetry = _RecordingTelemetry();
      final runtime = ConsumerRuntime(
        api: ConsumerApiClient(
          baseUri: Uri.parse('https://api.example.test/'),
          actorAccess: _actorAccess,
          client: MockClient((request) async {
            if (request.url.path == '/v1/topics')
              return http.Response('{"topics":[]}', 200);
            if (request.url.path == '/v1/actors')
              return http.Response('{}', 201);
            if (request.url.path == '/v1/search') {
              final body = jsonDecode(request.body) as Map<String, Object?>;
              intents.add(body['intent'] as String);
              if (body['query'] == 'travel') {
                return _searchResponse(
                  query: 'travel',
                  label: 'Travel',
                  topicId: 'travel',
                  hashChar: 'c',
                  intent: body['intent'] as String,
                );
              }
              return piano.future;
            }
            return http.Response('{}', 404);
          }),
        ),
        localState: _MemoryState(),
        capabilities: PlayCapabilityEnvelope.m1(),
      );
      addTearDown(runtime.close);

      await tester.pumpWidget(_app(runtime, telemetry));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey<String>('search-field')),
        'travel',
      );
      await tester.pumpAndSettle();
      expect(find.text('Travel'), findsOneWidget);

      await tester.tap(find.text('Learn'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey<String>('search-field')),
        'piano',
      );
      await tester.pump();
      expect(find.text('Travel'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('search-loading')),
        findsOneWidget,
      );

      piano.complete(
        _searchResponse(
          query: 'piano',
          label: 'Piano',
          topicId: 'piano',
          hashChar: 'd',
          intent: 'learning',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Piano'), findsOneWidget);
      expect(intents, contains('learning'));
    },
  );
}
