import 'dart:convert';

import 'package:event_delivery/event_delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_feed.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/consumer_runtime.dart';
import 'package:play_schema/play_schema.dart';

const _actorToken = 'NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN';
final _actorAccess = ActorAccessIdentity(
  actorId: 'actor_network_acceptance',
  accessToken: _actorToken,
);

final class _MemoryConsumerState implements ConsumerLocalState {
  ConsumerFeedResume? resume;
  ConsumerFeedCache? cache;

  @override
  Future<ConsumerPreferences> readPreferences() async => ConsumerPreferences();

  @override
  Future<void> writePreferences(ConsumerPreferences preferences) async {}

  @override
  Future<bool> readOnboardingCompleted() async => true;

  @override
  Future<void> writeOnboardingCompleted(bool completed) async {}

  @override
  Future<ConsumerFeedResume?> readFeedResume() async => resume;

  @override
  Future<void> writeFeedResume(ConsumerFeedResume state) async {
    resume = state;
  }

  @override
  Future<void> clearFeedResume() async {
    resume = null;
  }

  @override
  Future<ConsumerFeedCache?> readRecentFeed({
    required PlayCapabilityEnvelope capabilities,
  }) async => cache;

  @override
  Future<void> writeRecentFeed(ConsumerFeedCache state) async {
    cache = state;
  }

  @override
  Future<void> clearRecentFeed() async {
    cache = null;
  }

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

void main() {
  testWidgets(
    'timed-out fetch-ahead keeps current Play usable, suppresses duplicate fetch and self-heals',
    (tester) async {
      final state = _MemoryConsumerState();
      var cursorCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/actors') return http.Response('{}', 201);
        if (request.url.path != '/v1/feed') return http.Response('{}', 404);

        final body = jsonDecode(request.body) as Map<String, Object?>;
        final cursor = body['cursor'] as String?;
        if (cursor == null) {
          return http.Response(
            jsonEncode(
              _page('request_network', <String>[
                'play_0',
                'play_1',
                'play_2',
              ], 'cursor_3'),
            ),
            200,
          );
        }

        expect(cursor, 'cursor_3');
        cursorCalls += 1;
        if (cursorCalls == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return http.Response(
            jsonEncode(
              _page('request_network', <String>['play_3', 'play_4'], null),
            ),
            200,
          );
        }
        return http.Response(
          jsonEncode(
            _page('request_network', <String>['play_3', 'play_4'], null),
          ),
          200,
        );
      });
      final api = ConsumerApiClient(
        baseUri: Uri.parse('https://api.example.test/'),
        actorAccess: _actorAccess,
        client: client,
        requestTimeout: const Duration(milliseconds: 20),
      );
      final runtime = ConsumerRuntime(
        api: api,
        localState: state,
        capabilities: PlayCapabilityEnvelope.m1(),
      );
      addTearDown(runtime.close);

      await tester.pumpWidget(
        MaterialApp(
          home: ConsumerFeed(
            runtime: runtime,
            pageSize: 3,
            fetchAheadItems: 1,
            warmAheadItems: 0,
            itemBuilder:
                (
                  context,
                  item, {
                  required feedRequestId,
                  required active,
                  required onDirectManipulationChanged,
                }) => ColoredBox(
                  color: active ? Colors.black : Colors.black12,
                  child: Center(child: Text(item.playId)),
                ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('play_0'), findsOneWidget);
      expect(cursorCalls, 0);
      expect(state.cache?.items.map((item) => item.playId), <String>[
        'play_0',
        'play_1',
        'play_2',
      ]);

      await _swipeNext(tester);
      expect(find.text('play_1'), findsOneWidget);

      // Fetch-ahead times out, but the already-rendered Play stays interactive.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(cursorCalls, 1);
      expect(find.text('play_1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('consumer-feed-pager')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('feed-retry')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(state.cache?.items.map((item) => item.playId), <String>[
        'play_0',
        'play_1',
        'play_2',
      ]);

      // Moving again cannot create a second automatic request for the failed cursor.
      await _swipeNext(tester);
      expect(find.text('play_2'), findsOneWidget);
      expect(cursorCalls, 1);

      // Explicit retry clears only the blocked-cursor fence and appends the same decision.
      await tester.tap(find.byKey(const ValueKey<String>('feed-retry')));
      await tester.pumpAndSettle();
      expect(cursorCalls, 2);
      expect(find.byKey(const ValueKey<String>('feed-retry')), findsNothing);
      expect(state.cache?.items.map((item) => item.playId), <String>[
        'play_0',
        'play_1',
        'play_2',
        'play_3',
        'play_4',
      ]);

      await _swipeNext(tester);
      expect(find.text('play_3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _swipeNext(WidgetTester tester) async {
  await tester.drag(
    find.byKey(const ValueKey<String>('consumer-feed-pager')),
    const Offset(0, -700),
  );
  await tester.pumpAndSettle();
}

Map<String, Object?> _page(
  String requestId,
  List<String> playIds,
  String? nextCursor,
) => <String, Object?>{
  'requestId': requestId,
  'rankingConfigVersion': 'm2-rules-v1',
  'fallback': false,
  'items': playIds
      .map(
        (playId) => <String, Object?>{
          'playId': playId,
          'revisionId': 'revision_$playId',
          'sourceBucket': 'known',
          'document': _play(playId),
        },
      )
      .toList(growable: false),
  'nextCursor': nextCursor,
};

Map<String, Object?> _play(String playId) => <String, Object?>{
  'schemaVersion': 1,
  'id': playId,
  'revisionId': 'revision_$playId',
  'format': 'play',
  'classification': 'challenge',
  'topics': <String>['testing'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 5,
  'assets': <String>[],
  'sources': <Object>[],
  'entryState': 'entry',
  'states': <String, Object?>{
    'entry': <String, Object?>{
      'presentation': <String, Object?>{
        'layers': <Object>[
          <String, Object?>{'type': 'text', 'role': 'prompt', 'value': playId},
        ],
      },
      'input': <String, Object?>{'type': 'tap', 'label': 'Done'},
      'validation': <String, Object?>{'type': 'none'},
      'transition': <String, Object?>{'default': r'$end'},
    },
  },
};
