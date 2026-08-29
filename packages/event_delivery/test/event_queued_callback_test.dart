import 'dart:async';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:test/test.dart';

final class _GatedOutbox implements EventOutbox {
  final allowEnqueue = Completer<void>();
  final stored = Completer<MosaicEventEnvelope>();

  @override
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  }) async {
    await allowEnqueue.future;
    if (!stored.isCompleted) stored.complete(event);
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
  Future<void> clear() async {}

  @override
  Future<void> close() async {}
}

void main() {
  test('queued callback cannot run before durable enqueue completes', () async {
    final outbox = _GatedOutbox();
    final queued = Completer<void>();
    final telemetry = MosaicEventTelemetry(
      outbox: outbox,
      contextProvider: () =>
          EventContext(actorId: 'actor_1', sessionId: 'session_1'),
      eventIdFactory: () => 'evt_1',
      onQueued: queued.complete,
    );

    telemetry.event(MosaicEventName.mediaPlayback, const {
      'phase': 'playbackError',
    });
    await Future<void>.delayed(Duration.zero);
    expect(queued.isCompleted, isFalse);

    outbox.allowEnqueue.complete();
    final stored = await outbox.stored.future;
    await queued.future;

    expect(stored.eventId, 'evt_1');
    expect(stored.event, MosaicEventName.mediaPlayback);
  });

  test(
    'queued callback failure is isolated and reported as event_drain',
    () async {
      final outbox = _GatedOutbox();
      final reported = Completer<String?>();
      final telemetry = MosaicEventTelemetry(
        outbox: outbox,
        contextProvider: () =>
            EventContext(actorId: 'actor_1', sessionId: 'session_1'),
        eventIdFactory: () => 'evt_2',
        onQueued: () => throw StateError('offline'),
        onInternalError: (error, stackTrace, {operation}) {
          if (!reported.isCompleted) reported.complete(operation);
        },
      );

      telemetry.event(MosaicEventName.mediaPlayback, const {
        'phase': 'playbackError',
      });
      outbox.allowEnqueue.complete();

      expect((await outbox.stored.future).eventId, 'evt_2');
      expect(await reported.future, 'event_drain');
    },
  );
}
