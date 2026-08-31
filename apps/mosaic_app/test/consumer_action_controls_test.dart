import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/app_event_runtime.dart';
import 'package:mosaic_app/consumer_action_controller.dart';
import 'package:mosaic_app/consumer_action_controls.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_feed.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/event_runtime_resources.dart';
import 'package:play_schema/play_schema.dart';

final class _MemoryOutbox implements EventOutbox {
  final events = <MosaicEventEnvelope>[];

  @override
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  }) async => events.add(event);

  @override
  Future<List<QueuedEvent>> due({DateTime? now, int limit = 50}) async =>
      const [];
  @override
  Future<void> markDelivered(String eventId) async {}
  @override
  Future<void> markRetryableFailure(String eventId, {DateTime? now}) async {}
  @override
  Future<void> discard(String eventId) async {}
  @override
  Future<void> clear() async => events.clear();
  @override
  Future<void> close() async {}
}

final class _MemoryState implements ConsumerLocalState {
  final actions = <String, ConsumerPlayActionState>{};
  final mutedTopics = <String>{};

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
      actions[playId];
  @override
  Future<void> writePlayActionState(ConsumerPlayActionState state) async =>
      actions[state.playId] = state;
  @override
  Future<List<String>> readMutedTopicIds() async =>
      mutedTopics.toList()..sort();
  @override
  Future<void> writeMutedTopicIds(Iterable<String> topicIds) async {
    mutedTopics
      ..clear()
      ..addAll(topicIds);
  }
}

final class _Harness {
  _Harness() {
    runtime = AppEventRuntime.create(
      resources: AppEventResources(
        outbox: outbox,
        consumerLocalState: state,
        actorId: 'actor_controls',
        actorAccessToken: 'A' * 43,
        close: () async {},
      ),
    );
    controller = ConsumerActionController(
      eventRuntime: runtime,
      localState: state,
      eventIdFactory: () => 'event_${eventId++}',
      clock: () => DateTime.utc(2026, 8, 30),
    );
  }

  final outbox = _MemoryOutbox();
  final state = _MemoryState();
  late final AppEventRuntime runtime;
  late final ConsumerActionController controller;
  var eventId = 0;
  var advances = 0;
  final advanceReasons = <ConsumerFeedAdvanceReason>[];

  Future<bool> advance(ConsumerFeedAdvanceReason reason) async {
    advances += 1;
    advanceReasons.add(reason);
    return true;
  }

  Future<void> close() async {
    controller.dispose();
    await runtime.close();
  }
}

void main() {
  testWidgets('active controls stay compact and hide unavailable Share', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.close);

    await tester.pumpWidget(_app(harness));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('play-action-save')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('play-action-more-like')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('play-action-more')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('play-action-share')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('play-action-save')));
    await tester.pumpAndSettle();
    expect(harness.outbox.events.single.event, MosaicEventName.playSaved);
  });

  testWidgets('Not interested advances without a blocking modal', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.close);

    await tester.pumpWidget(_app(harness));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('play-action-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not interested'));
    await tester.pumpAndSettle();

    expect(
      harness.outbox.events.single.event,
      MosaicEventName.playNotInterested,
    );
    expect(harness.advances, 1);
    expect(harness.advanceReasons, <ConsumerFeedAdvanceReason>[
      ConsumerFeedAdvanceReason.notInterested,
    ]);
  });

  testWidgets('muting the current topic is durable and advances', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.close);

    await tester.pumpWidget(_app(harness));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('play-action-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mute Testing'));
    await tester.pumpAndSettle();

    expect(harness.outbox.events.single.event, MosaicEventName.topicMuted);
    expect(harness.controller.isTopicMuted('testing'), isTrue);
    expect(harness.advances, 1);
    expect(harness.advanceReasons, <ConsumerFeedAdvanceReason>[
      ConsumerFeedAdvanceReason.topicMuted,
    ]);
  });

  testWidgets('Report advances with an explicit non-swipe reason', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.close);

    await tester.pumpWidget(_app(harness));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('play-action-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spam'));
    await tester.pumpAndSettle();

    expect(harness.advances, 1);
    expect(harness.advanceReasons, <ConsumerFeedAdvanceReason>[
      ConsumerFeedAdvanceReason.reported,
    ]);
  });

  testWidgets('muted topics remain reachable and reversible', (tester) async {
    final harness = _Harness();
    harness.state.mutedTopics.add('history');
    addTearDown(harness.close);

    await tester.pumpWidget(_app(harness));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('play-action-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Muted topics'));
    await tester.pumpAndSettle();

    expect(find.text('History'), findsOneWidget);
    expect(find.text('Unmute'), findsOneWidget);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    expect(harness.outbox.events.single.event, MosaicEventName.topicUnmuted);
    expect(harness.controller.isTopicMuted('history'), isFalse);
    expect(harness.advances, 0);
  });

  testWidgets('inactive Play does not expose or eagerly load controls', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.close);

    await tester.pumpWidget(_app(harness, active: false));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('play-action-save')),
      findsNothing,
    );
    expect(harness.controller.stateFor('play_controls'), isNull);
  });
}

Widget _app(_Harness harness, {bool active = true}) => MaterialApp(
  home: ConsumerActionControls(
    item: _item(),
    feedRequestId: 'feed_controls',
    controller: harness.controller,
    onAdvance: harness.advance,
    active: active,
    child: const ColoredBox(color: Colors.black),
  ),
);

ConsumerFeedItem _item() => ConsumerFeedItem.fromJson(
  <String, Object?>{
    'playId': 'play_controls',
    'revisionId': 'revision_controls',
    'sourceBucket': 'known',
    'document': <String, Object?>{
      'schemaVersion': 1,
      'id': 'play_controls',
      'revisionId': 'revision_controls',
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
              <String, Object?>{
                'type': 'text',
                'role': 'prompt',
                'value': 'Pick one.',
              },
            ],
          },
          'input': <String, Object?>{'type': 'tap', 'label': 'Done'},
          'validation': <String, Object?>{'type': 'none'},
          'transition': <String, Object?>{'default': r'$end'},
        },
      },
    },
  },
  compatibilityChecker: const PlayCompatibilityChecker(),
  capabilities: PlayCapabilityEnvelope.m1(),
);
