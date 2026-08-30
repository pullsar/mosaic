import 'dart:convert';

import 'package:event_delivery/event_delivery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/consumer_runtime.dart';
import 'package:play_schema/play_schema.dart';

const _actorToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
final _actorAccess = ActorAccessIdentity(
  actorId: 'actor_runtime',
  accessToken: _actorToken,
);

Map<String, Object?> _play(String id, String revisionId) => <String, Object?>{
  'schemaVersion': 1,
  'id': id,
  'revisionId': revisionId,
  'format': 'discover',
  'classification': 'fact',
  'topics': <String>['science'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 10,
  'assets': <String>[],
  'sources': <Object?>[],
  'entryState': 'start',
  'states': <String, Object?>{
    'start': <String, Object?>{
      'presentation': <String, Object?>{
        'layers': <Object?>[
          <String, Object?>{'type': 'text', 'value': 'Play $id'},
        ],
      },
      'input': <String, Object?>{'type': 'tap'},
      'validation': <String, Object?>{'type': 'none'},
      'transition': <String, Object?>{},
    },
  },
};

Map<String, Object?> _feed({
  int itemCount = 1,
  String requestId = 'feed_runtime',
  String? nextCursor = 'cursor_next',
}) => <String, Object?>{
  'requestId': requestId,
  'rankingConfigVersion': 'm2-rules-v1',
  'fallback': false,
  'items': List<Object?>.generate(itemCount, (index) {
    final playId = 'play_$index';
    final revisionId = 'rev_$index';
    return <String, Object?>{
      'playId': playId,
      'revisionId': revisionId,
      'sourceBucket': 'known',
      'document': _play(playId, revisionId),
    };
  }),
  'nextCursor': nextCursor,
};

ConsumerFeedCache _cache(DateTime updatedAt) {
  final page = ConsumerFeedPage.fromJson(
    _feed(nextCursor: null),
    compatibilityChecker: const PlayCompatibilityChecker(),
    capabilities: PlayCapabilityEnvelope.m1(),
  );
  return ConsumerFeedCache(
    requestId: page.requestId,
    items: page.items,
    updatedAt: updatedAt,
  );
}

final class _MemoryConsumerState implements ConsumerLocalState {
  ConsumerPreferences preferences = ConsumerPreferences();
  ConsumerFeedResume? resume;
  ConsumerFeedCache? recent;
  var onboardingCompleted = false;
  var clearResumeCalls = 0;
  var clearRecentCalls = 0;
  var throwPreferenceWrite = false;
  var throwOnboardingWrite = false;

  @override
  Future<ConsumerPreferences> readPreferences() async => preferences;

  @override
  Future<void> writePreferences(ConsumerPreferences value) async {
    if (throwPreferenceWrite) throw StateError('local write failed');
    preferences = value;
  }

  @override
  Future<bool> readOnboardingCompleted() async => onboardingCompleted;

  @override
  Future<void> writeOnboardingCompleted(bool completed) async {
    if (throwOnboardingWrite) throw StateError('completion write failed');
    onboardingCompleted = completed;
  }

  @override
  Future<ConsumerFeedResume?> readFeedResume() async => resume;

  @override
  Future<void> writeFeedResume(ConsumerFeedResume value) async {
    resume = value;
  }

  @override
  Future<void> clearFeedResume() async {
    clearResumeCalls += 1;
    resume = null;
  }

  @override
  Future<ConsumerFeedCache?> readRecentFeed({
    required PlayCapabilityEnvelope capabilities,
  }) async => recent;

  @override
  Future<void> writeRecentFeed(ConsumerFeedCache value) async {
    recent = value;
  }

  @override
  Future<void> clearRecentFeed() async {
    clearRecentCalls += 1;
    recent = null;
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

ConsumerApiClient _client(http.Client client) => ConsumerApiClient(
  baseUri: Uri.parse('https://api.example.test/'),
  actorAccess: _actorAccess,
  client: client,
);

void main() {
  test(
    'preference intent persists locally before a retryable remote failure',
    () async {
      final local = _MemoryConsumerState();
      final desired = ConsumerPreferences(
        interestTopicIds: const ['science'],
        learningTopicIds: const ['piano'],
      );
      final api = _client(
        MockClient((request) async {
          expect(local.preferences.interestTopicIds, const ['science']);
          expect(local.preferences.learningTopicIds, const ['piano']);
          expect(request.url.path, '/v1/actors');
          return http.Response('{}', 503);
        }),
      );
      final runtime = ConsumerRuntime(
        api: api,
        localState: local,
        capabilities: PlayCapabilityEnvelope.m1(),
      );

      final result = await runtime.savePreferences(desired);

      expect(result.localPersisted, isTrue);
      expect(result.synced, isFalse);
      expect(result.remoteFailure, ConsumerApiFailureKind.retryable);
      expect(local.preferences.interestTopicIds, const ['science']);
      runtime.close();
    },
  );

  test(
    'local-only preference persistence does not touch the network',
    () async {
      final local = _MemoryConsumerState();
      var networkCalled = false;
      final runtime = ConsumerRuntime(
        api: _client(
          MockClient((request) async {
            networkCalled = true;
            return http.Response('{}', 500);
          }),
        ),
        localState: local,
        capabilities: PlayCapabilityEnvelope.m1(),
      );
      final desired = ConsumerPreferences(
        interestTopicIds: const ['science'],
        learningTopicIds: const ['history'],
      );

      final persisted = await runtime.persistPreferencesLocally(desired);

      expect(persisted, isTrue);
      expect(networkCalled, isFalse);
      expect(local.preferences.interestTopicIds, const ['science']);
      expect(local.preferences.learningTopicIds, const ['history']);
      runtime.close();
    },
  );

  test(
    'failed local preference persistence prevents remote mutation',
    () async {
      final local = _MemoryConsumerState()..throwPreferenceWrite = true;
      var networkCalled = false;
      final runtime = ConsumerRuntime(
        api: _client(
          MockClient((request) async {
            networkCalled = true;
            return http.Response('{}', 201);
          }),
        ),
        localState: local,
        capabilities: PlayCapabilityEnvelope.m1(),
      );

      final result = await runtime.savePreferences(
        ConsumerPreferences(interestTopicIds: const ['science']),
      );

      expect(result.localPersisted, isFalse);
      expect(networkCalled, isFalse);
      runtime.close();
    },
  );

  test('onboarding completion remains an explicit local marker', () async {
    final local = _MemoryConsumerState();
    final runtime = ConsumerRuntime(
      localState: local,
      capabilities: PlayCapabilityEnvelope.m1(),
    );

    expect(await runtime.readOnboardingCompleted(), isFalse);
    expect(await runtime.writeOnboardingCompleted(true), isTrue);
    expect(await runtime.readOnboardingCompleted(), isTrue);

    local.throwOnboardingWrite = true;
    expect(await runtime.writeOnboardingCompleted(false), isFalse);
    expect(await runtime.readOnboardingCompleted(), isTrue);
    runtime.close();
  });

  test('invalid cursor is cleared and retried fresh exactly once', () async {
    final local = _MemoryConsumerState();
    var feedCalls = 0;
    final runtime = ConsumerRuntime(
      api: _client(
        MockClient((request) async {
          if (request.url.path == '/v1/actors') return http.Response('{}', 201);
          feedCalls += 1;
          final body = jsonDecode(request.body) as Map<String, Object?>;
          if (feedCalls == 1) {
            expect(body['cursor'], 'stale_cursor');
            return http.Response('{"error":"invalid_feed_cursor"}', 400);
          }
          expect(body['cursor'], isNull);
          return http.Response(jsonEncode(_feed()), 200);
        }),
      ),
      localState: local,
      capabilities: PlayCapabilityEnvelope.m1(),
      clock: () => DateTime.utc(2026, 8, 29, 16),
    );

    final result = await runtime.fetchFeed(cursor: 'stale_cursor');

    expect(feedCalls, 2);
    expect(local.clearResumeCalls, 1);
    expect(result.cursorReset, isTrue);
    expect(result.loadedFromNetwork, isTrue);
    expect(local.resume?.requestId, 'feed_runtime');
    expect(local.resume?.cursor, 'cursor_next');
    expect(local.recent?.requestId, 'feed_runtime');
    runtime.close();
  });

  test(
    'retryable feed failure exposes recent validated recovery content',
    () async {
      final now = DateTime.utc(2026, 8, 29, 16);
      final local = _MemoryConsumerState()..recent = _cache(now);
      final runtime = ConsumerRuntime(
        api: _client(
          MockClient((request) async {
            if (request.url.path == '/v1/actors') {
              return http.Response('{}', 201);
            }
            return http.Response('{}', 503);
          }),
        ),
        localState: local,
        capabilities: PlayCapabilityEnvelope.m1(),
        clock: () => now,
      );

      final result = await runtime.fetchFeed();

      expect(result.failure, ConsumerApiFailureKind.retryable);
      expect(result.recovered?.items.single.revisionId, 'rev_0');
      expect(result.hasUsableContent, isTrue);
      runtime.close();
    },
  );

  test(
    'stale recent feed is cleared instead of being served forever',
    () async {
      final now = DateTime.utc(2026, 8, 29, 16);
      final local = _MemoryConsumerState()
        ..recent = _cache(now.subtract(const Duration(days: 3)));
      final runtime = ConsumerRuntime(
        api: _client(
          MockClient((request) async {
            if (request.url.path == '/v1/actors') {
              return http.Response('{}', 201);
            }
            return http.Response('{}', 503);
          }),
        ),
        localState: local,
        capabilities: PlayCapabilityEnvelope.m1(),
        clock: () => now,
      );

      final result = await runtime.fetchFeed();

      expect(result.failure, ConsumerApiFailureKind.retryable);
      expect(result.recovered, isNull);
      expect(local.clearRecentCalls, 1);
      expect(local.recent, isNull);
      runtime.close();
    },
  );

  test(
    'coordinator fetch does not replace the visible recovery window',
    () async {
      final now = DateTime.utc(2026, 8, 29, 16);
      final local = _MemoryConsumerState()
        ..recent = _cache(now)
        ..resume = ConsumerFeedResume(
          requestId: 'feed_runtime',
          cursor: 'cursor_existing',
          visibleRevisionId: 'rev_0',
          visiblePosition: 0,
          windowRevisionIds: const ['rev_0'],
          updatedAt: now,
        );
      final runtime = ConsumerRuntime(
        api: _client(
          MockClient((request) async {
            if (request.url.path == '/v1/actors') {
              return http.Response('{}', 201);
            }
            return http.Response(
              jsonEncode(
                _feed(requestId: 'feed_new', nextCursor: 'cursor_new'),
              ),
              200,
            );
          }),
        ),
        localState: local,
        capabilities: PlayCapabilityEnvelope.m1(),
        clock: () => now,
      );

      final result = await runtime.fetchFeed(persistPage: false);

      expect(result.page?.requestId, 'feed_new');
      expect(local.recent?.requestId, 'feed_runtime');
      expect(local.resume?.requestId, 'feed_runtime');
      expect(local.resume?.cursor, 'cursor_existing');
      runtime.close();
    },
  );

  test(
    'persisted visible position disambiguates reused revision ids',
    () async {
      final now = DateTime.utc(2026, 8, 29, 16);
      final local = _MemoryConsumerState();
      final first = ConsumerFeedItem.fromJson(
        <String, Object?>{
          'playId': 'play_first',
          'revisionId': 'rev_shared',
          'sourceBucket': 'known',
          'document': _play('play_first', 'rev_shared'),
        },
        compatibilityChecker: const PlayCompatibilityChecker(),
        capabilities: PlayCapabilityEnvelope.m1(),
      );
      final second = ConsumerFeedItem.fromJson(
        <String, Object?>{
          'playId': 'play_second',
          'revisionId': 'rev_shared',
          'sourceBucket': 'known',
          'document': _play('play_second', 'rev_shared'),
        },
        compatibilityChecker: const PlayCompatibilityChecker(),
        capabilities: PlayCapabilityEnvelope.m1(),
      );
      final runtime = ConsumerRuntime(
        localState: local,
        capabilities: PlayCapabilityEnvelope.m1(),
        clock: () => now,
      );

      final persisted = await runtime.persistFeedWindow(
        requestId: 'feed_shared_revision',
        cursor: 'cursor_shared',
        visibleRevisionId: 'rev_shared',
        visiblePosition: 1,
        items: [first, second],
      );

      expect(persisted, isTrue);
      expect(local.resume?.visiblePosition, 1);
      expect(local.resume?.visibleRevisionId, 'rev_shared');
      expect(local.recent?.items[1].playId, 'play_second');
      runtime.close();
    },
  );

  test('successful feed caches at most the bounded recent window', () async {
    final local = _MemoryConsumerState();
    final runtime = ConsumerRuntime(
      api: _client(
        MockClient((request) async {
          if (request.url.path == '/v1/actors') return http.Response('{}', 201);
          return http.Response(jsonEncode(_feed(itemCount: 20)), 200);
        }),
      ),
      localState: local,
      capabilities: PlayCapabilityEnvelope.m1(),
      clock: () => DateTime.utc(2026, 8, 29, 16),
    );

    final result = await runtime.fetchFeed(limit: 20);

    expect(result.page?.items, hasLength(20));
    expect(local.recent?.items, hasLength(ConsumerRuntime.recentFeedMaxItems));
    expect(
      local.resume?.windowRevisionIds,
      hasLength(ConsumerRuntime.recentFeedMaxItems),
    );
    runtime.close();
  });
}
