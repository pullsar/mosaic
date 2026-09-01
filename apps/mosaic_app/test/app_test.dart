import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/app_event_runtime.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/event_runtime_resources.dart';
import 'package:mosaic_app/main.dart';
import 'package:play_schema/play_schema.dart';

final class _AppOutbox implements EventOutbox {
  @override
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  }) async {}

  @override
  Future<List<QueuedEvent>> due({DateTime? now, int limit = 50}) async =>
      const <QueuedEvent>[];

  @override
  Future<void> markDelivered(String eventId) async {}

  @override
  Future<void> markRetryableFailure(String eventId, {DateTime? now}) async {}

  @override
  Future<void> discard(String eventId) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<void> close() async {}
}

final class _SeededAppState implements ConsumerLocalState {
  _SeededAppState(this.cache);

  final ConsumerFeedCache cache;

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
  }) async => cache;

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

ConsumerFeedItem _seededItem() => ConsumerFeedItem.fromJson(
  <String, Object?>{
    'playId': 'play_app_share',
    'revisionId': 'revision_app_share',
    'sourceBucket': 'known',
    'document': <String, Object?>{
      'schemaVersion': 1,
      'id': 'play_app_share',
      'revisionId': 'revision_app_share',
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

void main() {
  testWidgets('first launch opens the guest discovery feed', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MosaicApp()));
    await tester.pumpAndSettle();

    expect(find.text('What are you into?'), findsNothing);
    expect(find.byKey(const ValueKey<String>('guest-home')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('feed-empty-retry')),
      findsOneWidget,
    );
  });

  testWidgets('real guest feed exposes exact Save Share More utilities', (
    tester,
  ) async {
    final state = _SeededAppState(
      ConsumerFeedCache(
        requestId: 'request_app_share',
        items: <ConsumerFeedItem>[_seededItem()],
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    final runtime = AppEventRuntime.create(
      resources: AppEventResources(
        outbox: _AppOutbox(),
        consumerLocalState: state,
        actorId: 'actor_app_share',
        actorAccessToken: 'A' * 43,
        close: () async {},
      ),
    );

    await tester.pumpWidget(
      ProviderScope(child: MosaicApp(eventRuntime: runtime)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('play-action-save')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('play-action-share')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('play-action-more')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('play-action-more-like')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('play-action-share')));
    await tester.pump();
    expect(find.text('Share links are opening soon'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'real RTL app keeps English authored Play LTR while shell remains RTL',
    (tester) async {
      final state = _SeededAppState(
        ConsumerFeedCache(
          requestId: 'request_app_rtl',
          items: <ConsumerFeedItem>[_seededItem()],
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      final runtime = AppEventRuntime.create(
        resources: AppEventResources(
          outbox: _AppOutbox(),
          consumerLocalState: state,
          actorId: 'actor_app_rtl',
          actorAccessToken: 'A' * 43,
          close: () async {},
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MosaicApp(
            eventRuntime: runtime,
            locale: const Locale('ar', 'XB'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        Directionality.of(
          tester.element(find.byKey(const ValueKey<String>('guest-home'))),
        ),
        TextDirection.rtl,
      );
      expect(
        Directionality.of(tester.element(find.text('Pick one.'))),
        TextDirection.ltr,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
