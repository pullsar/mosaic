import 'dart:async';
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

const _actorToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
final _actorAccess = ActorAccessIdentity(
  actorId: 'actor_feed',
  accessToken: _actorToken,
);

final class _MemoryConsumerState implements ConsumerLocalState {
  ConsumerFeedResume? resume;
  ConsumerFeedCache? cache;
  Completer<void>? resumeWriteGate;
  int resumeWriteCalls = 0;
  int maxPersistedItems = 0;

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
    resumeWriteCalls += 1;
    final gate = resumeWriteGate;
    if (gate != null && !gate.isCompleted) await gate.future;
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
    if (state.items.length > maxPersistedItems) {
      maxPersistedItems = state.items.length;
    }
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

typedef _FeedResponder =
    FutureOr<http.Response> Function(String? cursor, int call);

ConsumerRuntime _runtime(
  _MemoryConsumerState state,
  _FeedResponder responder, {
  void Function(String? cursor)? onFeedRequest,
}) {
  var feedCalls = 0;
  final client = MockClient((request) async {
    if (request.url.path == '/v1/actors') return http.Response('{}', 201);
    if (request.url.path == '/v1/feed') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      final cursor = body['cursor'] as String?;
      feedCalls += 1;
      onFeedRequest?.call(cursor);
      return responder(cursor, feedCalls);
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

Widget _app(
  ConsumerRuntime runtime, {
  ConsumerFeedItemBuilder? itemBuilder,
  ConsumerFeedEventSink? onEvent,
  ConsumerFeedWarmWindowCallback? onWarmWindow,
  int pageSize = 6,
}) => MaterialApp(
  home: ConsumerFeed(
    runtime: runtime,
    pageSize: pageSize,
    onEvent: onEvent,
    onWarmWindow: onWarmWindow,
    itemBuilder:
        itemBuilder ??
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
);

void main() {
  testWidgets('restores cached visible position before a failed refresh', (
    tester,
  ) async {
    final state = _MemoryConsumerState();
    final cachedItems = [
      _item('cached_0'),
      _item('cached_1'),
      _item('cached_2'),
    ];
    state.cache = ConsumerFeedCache(
      requestId: 'request_cached',
      items: cachedItems,
      updatedAt: DateTime.now().toUtc(),
    );
    state.resume = ConsumerFeedResume(
      requestId: 'request_cached',
      cursor: 'cursor_cached',
      visibleRevisionId: cachedItems[1].revisionId,
      visiblePosition: 1,
      windowRevisionIds: cachedItems.map((item) => item.revisionId).toList(),
      updatedAt: DateTime.now().toUtc(),
    );
    final refresh = Completer<http.Response>();
    final runtime = _runtime(state, (cursor, call) => refresh.future);
    addTearDown(runtime.close);

    await tester.pumpWidget(_app(runtime));
    await tester.pump();
    await tester.pump();

    expect(find.text('cached_1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('consumer-feed-pager')),
      findsOneWidget,
    );

    refresh.complete(http.Response('{"error":"temporary"}', 503));
    await tester.pumpAndSettle();
    expect(find.text('cached_1'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('feed-retry')), findsOneWidget);
  });

  testWidgets('direct manipulation locks only the active vertical page', (
    tester,
  ) async {
    final state = _MemoryConsumerState();
    final runtime = _runtime(
      state,
      (cursor, call) => http.Response(
        jsonEncode(
          _page('request_a', [_item('play_0'), _item('play_1')], null),
        ),
        200,
      ),
    );
    addTearDown(runtime.close);
    ValueChanged<bool>? activeManipulation;

    await tester.pumpWidget(
      _app(
        runtime,
        itemBuilder:
            (
              context,
              item, {
              required feedRequestId,
              required active,
              required onDirectManipulationChanged,
            }) {
              if (active) activeManipulation = onDirectManipulationChanged;
              return Center(child: Text(item.playId));
            },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('play_0'), findsOneWidget);

    activeManipulation!(true);
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey<String>('consumer-feed-pager')),
      const Offset(0, -700),
    );
    await tester.pumpAndSettle();
    expect(find.text('play_0'), findsOneWidget);

    activeManipulation!(false);
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey<String>('consumer-feed-pager')),
      const Offset(0, -700),
    );
    await tester.pumpAndSettle();
    expect(find.text('play_1'), findsOneWidget);
  });

  testWidgets('fetch-ahead suppresses duplicate concurrent cursor requests', (
    tester,
  ) async {
    final state = _MemoryConsumerState();
    final nextPage = Completer<http.Response>();
    final requested = <String?>[];
    final runtime = _runtime(state, (cursor, call) {
      if (cursor == null) {
        return http.Response(
          jsonEncode(
            _page(
              'request_a',
              List.generate(6, (index) => _item('play_$index')),
              'cursor_6',
            ),
          ),
          200,
        );
      }
      return nextPage.future;
    }, onFeedRequest: requested.add);
    addTearDown(runtime.close);

    await tester.pumpWidget(_app(runtime));
    await tester.pumpAndSettle();

    for (var index = 0; index < 5; index += 1) {
      await tester.drag(
        find.byKey(const ValueKey<String>('consumer-feed-pager')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
    }

    expect(requested.where((cursor) => cursor == 'cursor_6'), hasLength(1));
    nextPage.complete(
      http.Response(
        jsonEncode(
          _page(
            'request_a',
            List.generate(6, (index) => _item('play_${index + 6}')),
            null,
          ),
        ),
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(requested.where((cursor) => cursor == 'cursor_6'), hasLength(1));
  });

  testWidgets(
    'invalid cursor preserves visible Play until fresh decision exists',
    (tester) async {
      final state = _MemoryConsumerState();
      final oldItems = [_item('old_0'), _item('old_1')];
      state.cache = ConsumerFeedCache(
        requestId: 'request_old',
        items: oldItems,
        updatedAt: DateTime.now().toUtc(),
      );
      state.resume = ConsumerFeedResume(
        requestId: 'request_old',
        cursor: 'stale_cursor',
        visibleRevisionId: oldItems[1].revisionId,
        visiblePosition: 1,
        windowRevisionIds: oldItems.map((item) => item.revisionId).toList(),
        updatedAt: DateTime.now().toUtc(),
      );
      final requested = <String?>[];
      final runtime = _runtime(state, (cursor, call) {
        if (cursor == 'stale_cursor') {
          return http.Response('{"error":"invalid_feed_cursor"}', 400);
        }
        return http.Response(
          jsonEncode(
            _page('request_fresh', [_item('fresh_0'), _item('fresh_1')], null),
          ),
          200,
        );
      }, onFeedRequest: requested.add);
      addTearDown(runtime.close);

      await tester.pumpWidget(_app(runtime));
      await tester.pumpAndSettle();

      expect(requested, ['stale_cursor', null]);
      expect(find.text('old_1'), findsOneWidget);
      expect(state.resume?.cursor, isNull);

      await tester.drag(
        find.byKey(const ValueKey<String>('consumer-feed-pager')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      expect(find.text('fresh_0'), findsOneWidget);
      expect(state.resume?.requestId, 'request_fresh');
    },
  );

  testWidgets('paging emits canonical context and active-page ownership', (
    tester,
  ) async {
    final state = _MemoryConsumerState();
    final events = <String>[];
    final runtime = _runtime(
      state,
      (cursor, call) => http.Response(
        jsonEncode(
          _page('request_events', [_item('event_0'), _item('event_1')], null),
        ),
        200,
      ),
    );
    addTearDown(runtime.close);

    await tester.pumpWidget(
      _app(
        runtime,
        onEvent:
            (
              event, {
              required feedRequestId,
              required playRevisionId,
              required payload,
            }) {
              events.add('$event:$feedRequestId:$playRevisionId');
            },
        itemBuilder:
            (
              context,
              item, {
              required feedRequestId,
              required active,
              required onDirectManipulationChanged,
            }) => SizedBox.expand(
              key: ValueKey<String>('active:${item.playId}:$active'),
              child: Center(child: Text(item.playId)),
            ),
      ),
    );
    await tester.pumpAndSettle();

    expect(events.take(3), [
      'play_impression:request_events:revision_event_0',
      'play_visible:request_events:revision_event_0',
      'play_started:request_events:revision_event_0',
    ]);
    expect(
      find.byKey(const ValueKey<String>('active:event_0:true')),
      findsOneWidget,
    );

    await tester.drag(
      find.byKey(const ValueKey<String>('consumer-feed-pager')),
      const Offset(0, -700),
    );
    await tester.pumpAndSettle();

    expect(
      events,
      containsAllInOrder([
        'play_dismissed:request_events:revision_event_0',
        'play_impression:request_events:revision_event_1',
        'play_visible:request_events:revision_event_1',
        'play_started:request_events:revision_event_1',
      ]),
    );
    expect(
      find.byKey(const ValueKey<String>('active:event_1:true')),
      findsOneWidget,
    );
  });

  testWidgets('rapid swipes coalesce persistence behind one active write', (
    tester,
  ) async {
    final state = _MemoryConsumerState()..resumeWriteGate = Completer<void>();
    final runtime = _runtime(
      state,
      (cursor, call) => http.Response(
        jsonEncode(
          _page(
            'request_persist',
            List.generate(6, (index) => _item('persist_$index')),
            null,
          ),
        ),
        200,
      ),
    );
    addTearDown(runtime.close);

    await tester.pumpWidget(_app(runtime));
    await tester.pumpAndSettle();
    expect(state.resumeWriteCalls, 1);

    for (var index = 0; index < 4; index += 1) {
      await tester.drag(
        find.byKey(const ValueKey<String>('consumer-feed-pager')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
    }

    expect(state.resumeWriteCalls, 1);
    state.resumeWriteGate!.complete();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(state.resumeWriteCalls, 2);
    expect(state.resume?.visiblePosition, 4);
    expect(state.resume?.visibleRevisionId, 'revision_persist_4');
  });

  testWidgets('long paging keeps persisted and warm windows hard-bounded', (
    tester,
  ) async {
    final state = _MemoryConsumerState();
    var pageNumber = 0;
    var maximumWarmWindow = 0;
    final runtime = _runtime(state, (cursor, call) {
      final start = pageNumber * 6;
      pageNumber += 1;
      return http.Response(
        jsonEncode(
          _page(
            'request_long',
            List.generate(6, (index) => _item('long_${start + index}')),
            pageNumber < 20 ? 'cursor_${pageNumber * 6}' : null,
          ),
        ),
        200,
      );
    });
    addTearDown(runtime.close);

    await tester.pumpWidget(
      _app(
        runtime,
        onWarmWindow: (context, items) {
          if (items.length > maximumWarmWindow)
            maximumWarmWindow = items.length;
        },
      ),
    );
    await tester.pumpAndSettle();

    for (var index = 0; index < 100; index += 1) {
      await tester.drag(
        find.byKey(const ValueKey<String>('consumer-feed-pager')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
    }

    expect(
      state.maxPersistedItems,
      lessThanOrEqualTo(ConsumerFeedCache.maxItems),
    );
    expect(
      state.cache?.items.length,
      lessThanOrEqualTo(ConsumerFeedCache.maxItems),
    );
    expect(maximumWarmWindow, lessThanOrEqualTo(3));
    expect(tester.takeException(), isNull);
  });
}

ConsumerFeedItem _item(String id) => ConsumerFeedItem.fromJson(
  <String, Object?>{
    'playId': id,
    'revisionId': 'revision_$id',
    'sourceBucket': 'known',
    'document': _play(id),
  },
  compatibilityChecker: const PlayCompatibilityChecker(),
  capabilities: PlayCapabilityEnvelope.m1(),
);

Map<String, Object?> _page(
  String requestId,
  List<ConsumerFeedItem> items,
  String? nextCursor,
) => <String, Object?>{
  'requestId': requestId,
  'rankingConfigVersion': 'ranking_test',
  'fallback': false,
  'items': items
      .map(
        (item) => <String, Object?>{
          'playId': item.playId,
          'revisionId': item.revisionId,
          'sourceBucket': item.sourceBucket.wireName,
          'document': item.validatedDocumentJson,
        },
      )
      .toList(growable: false),
  'nextCursor': nextCursor,
};

Map<String, Object?> _play(String id) => <String, Object?>{
  'schemaVersion': 1,
  'id': id,
  'revisionId': 'revision_$id',
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
          <String, Object?>{'type': 'text', 'role': 'prompt', 'value': id},
        ],
      },
      'input': <String, Object?>{'type': 'tap', 'label': 'Done'},
      'validation': <String, Object?>{'type': 'none'},
      'transition': <String, Object?>{'default': r'$end'},
    },
  },
};
