import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/app_event_runtime.dart';
import 'package:mosaic_app/consumer_action_controller.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/event_runtime_resources.dart';
import 'package:play_schema/play_schema.dart';

final class _RecordedEvent {
  const _RecordedEvent(this.envelope, this.priority);

  final MosaicEventEnvelope envelope;
  final EventPriority priority;
}

final class _MemoryOutbox implements EventOutbox {
  final events = <_RecordedEvent>[];
  Object? enqueueError;

  @override
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  }) async {
    final error = enqueueError;
    if (error != null) throw error;
    events.add(_RecordedEvent(event, priority));
  }

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
  Object? writeActionError;
  Object? writeMutedError;

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
  Future<void> writePlayActionState(ConsumerPlayActionState state) async {
    final error = writeActionError;
    if (error != null) throw error;
    actions[state.playId] = state;
  }

  @override
  Future<List<String>> readMutedTopicIds() async =>
      mutedTopics.toList()..sort();

  @override
  Future<void> writeMutedTopicIds(Iterable<String> topicIds) async {
    final error = writeMutedError;
    if (error != null) throw error;
    mutedTopics
      ..clear()
      ..addAll(topicIds);
  }
}

AppEventRuntime _runtime(_MemoryOutbox outbox, _MemoryState state) =>
    AppEventRuntime.create(
      resources: AppEventResources(
        outbox: outbox,
        consumerLocalState: state,
        actorId: 'actor_actions',
        actorAccessToken: 'A' * 43,
        close: () async {},
      ),
    );

void main() {
  test('Save and More Like This remain distinct durable actions', () async {
    final outbox = _MemoryOutbox();
    final state = _MemoryState();
    final runtime = _runtime(outbox, state);
    addTearDown(runtime.close);
    var eventId = 0;
    final controller = ConsumerActionController(
      eventRuntime: runtime,
      localState: state,
      eventIdFactory: () => 'event_${eventId++}',
      clock: () => DateTime.utc(2026, 8, 29, 21),
    );
    addTearDown(controller.dispose);

    expect(
      await controller.toggleSave(
        playId: 'play_a',
        revisionId: 'rev_a',
        feedRequestId: 'feed_a',
      ),
      isTrue,
    );
    expect(
      await controller.moreLikeThis(
        playId: 'play_a',
        revisionId: 'rev_a',
        feedRequestId: 'feed_a',
      ),
      isTrue,
    );
    expect(
      await controller.moreLikeThis(
        playId: 'play_a',
        revisionId: 'rev_a',
        feedRequestId: 'feed_a',
      ),
      isTrue,
    );

    expect(outbox.events.map((event) => event.envelope.event), [
      MosaicEventName.playSaved,
      MosaicEventName.moreLikeThis,
    ]);
    expect(
      outbox.events.every((event) => event.priority == EventPriority.normal),
      isTrue,
    );
    final local = state.actions['play_a'];
    expect(local?.saved, isTrue);
    expect(local?.savedRevisionId, 'rev_a');
    expect(local?.moreLikeThis, isTrue);

    await controller.toggleSave(
      playId: 'play_a',
      revisionId: 'rev_a',
      feedRequestId: 'feed_a',
    );
    expect(outbox.events.last.envelope.event, MosaicEventName.playUnsaved);
    expect(state.actions['play_a']?.saved, isFalse);
    expect(state.actions['play_a']?.moreLikeThis, isTrue);
  });

  test('failed enqueue reverts optimistic play state', () async {
    final outbox = _MemoryOutbox();
    final state = _MemoryState();
    final runtime = _runtime(outbox, state);
    addTearDown(runtime.close);
    final errors = <Object>[];
    final controller = ConsumerActionController(
      eventRuntime: runtime,
      localState: state,
      onError: (error, stackTrace, {operation}) => errors.add(error),
    );
    addTearDown(controller.dispose);

    await controller.load(playId: 'play_a', revisionId: 'rev_a');
    outbox.enqueueError = StateError('disk full');
    expect(
      await controller.notInterested(
        playId: 'play_a',
        revisionId: 'rev_a',
        feedRequestId: 'feed_a',
      ),
      isFalse,
    );
    expect(controller.stateFor('play_a')?.notInterested, isFalse);
    expect(state.actions['play_a'], isNull);
    expect(errors, hasLength(1));
  });

  test(
    'durable enqueue remains committed when local action cache write fails',
    () async {
      final outbox = _MemoryOutbox();
      final state = _MemoryState()
        ..writeActionError = StateError('cache unavailable');
      final runtime = _runtime(outbox, state);
      addTearDown(runtime.close);
      final operations = <String?>[];
      final controller = ConsumerActionController(
        eventRuntime: runtime,
        localState: state,
        eventIdFactory: () => 'event_cache_failure',
        onError: (error, stackTrace, {operation}) => operations.add(operation),
      );
      addTearDown(controller.dispose);

      expect(
        await controller.toggleSave(
          playId: 'play_a',
          revisionId: 'rev_a',
          feedRequestId: 'feed_a',
        ),
        isTrue,
      );
      expect(outbox.events.single.envelope.event, MosaicEventName.playSaved);
      expect(controller.stateFor('play_a')?.saved, isTrue);
      expect(state.actions['play_a'], isNull);
      expect(operations, contains('consumer_action_save_cache'));
    },
  );

  test(
    'topic mute cache failure does not undo a durably queued intent',
    () async {
      final outbox = _MemoryOutbox();
      final state = _MemoryState()
        ..writeMutedError = StateError('cache unavailable');
      final runtime = _runtime(outbox, state);
      addTearDown(runtime.close);
      final operations = <String?>[];
      final controller = ConsumerActionController(
        eventRuntime: runtime,
        localState: state,
        eventIdFactory: () => 'event_topic_cache_failure',
        onError: (error, stackTrace, {operation}) => operations.add(operation),
      );
      addTearDown(controller.dispose);

      expect(
        await controller.setTopicMuted(
          topicId: 'travel',
          muted: true,
          feedRequestId: 'feed_a',
          playRevisionId: 'rev_a',
        ),
        isTrue,
      );
      expect(outbox.events.single.envelope.event, MosaicEventName.topicMuted);
      expect(controller.isTopicMuted('travel'), isTrue);
      expect(state.mutedTopics, isEmpty);
      expect(operations, contains('consumer_action_topic_mute_cache'));
    },
  );

  test('topic mute is reversible and Report is critical, not a mute', () async {
    final outbox = _MemoryOutbox();
    final state = _MemoryState();
    final runtime = _runtime(outbox, state);
    addTearDown(runtime.close);
    var eventId = 0;
    final controller = ConsumerActionController(
      eventRuntime: runtime,
      localState: state,
      eventIdFactory: () => 'event_${eventId++}',
      clock: () => DateTime.utc(2026, 8, 29, 22),
    );
    addTearDown(controller.dispose);

    expect(
      await controller.setTopicMuted(
        topicId: 'travel',
        muted: true,
        feedRequestId: 'feed_a',
        playRevisionId: 'rev_a',
      ),
      isTrue,
    );
    expect(controller.isTopicMuted('travel'), isTrue);
    expect(state.mutedTopics, {'travel'});

    expect(
      await controller.report(
        playId: 'play_a',
        revisionId: 'rev_a',
        feedRequestId: 'feed_a',
        reason: ConsumerReportReason.misleading,
        dismiss: true,
      ),
      isTrue,
    );
    expect(outbox.events.last.envelope.event, MosaicEventName.playReported);
    expect(outbox.events.last.priority, EventPriority.critical);
    expect(outbox.events.last.envelope.payload['reason'], 'misleading');
    expect(controller.isTopicMuted('travel'), isTrue);

    await controller.setTopicMuted(
      topicId: 'travel',
      muted: false,
      feedRequestId: 'feed_a',
      playRevisionId: 'rev_a',
    );
    expect(controller.isTopicMuted('travel'), isFalse);
    expect(state.mutedTopics, isEmpty);
    expect(outbox.events.last.envelope.event, MosaicEventName.topicUnmuted);
  });

  test('in-memory Play action cache stays bounded', () async {
    final outbox = _MemoryOutbox();
    final state = _MemoryState();
    final runtime = _runtime(outbox, state);
    addTearDown(runtime.close);
    final controller = ConsumerActionController(
      eventRuntime: runtime,
      localState: state,
    );
    addTearDown(controller.dispose);

    for (var index = 0; index < 65; index += 1) {
      await controller.load(
        playId: 'play_$index',
        revisionId: 'revision_$index',
      );
    }

    expect(controller.stateFor('play_0'), isNull);
    expect(controller.stateFor('play_64'), isNotNull);
  });
}
