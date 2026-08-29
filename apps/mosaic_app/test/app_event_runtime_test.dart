import 'dart:async';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/app_event_runtime.dart';
import 'package:mosaic_app/event_runtime_resources.dart';

const _actorToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

final class _MemoryOutbox implements EventOutbox {
  final queued = <QueuedEvent>[];
  final enqueued = Completer<void>();
  var closed = false;

  @override
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  }) async {
    queued.add(
      QueuedEvent(
        envelope: event,
        priority: priority,
        attemptCount: 0,
        createdAt: createdAt ?? DateTime.now().toUtc(),
      ),
    );
    if (!enqueued.isCompleted) enqueued.complete();
  }

  @override
  Future<List<QueuedEvent>> due({DateTime? now, int limit = 50}) async =>
      queued.take(limit).toList(growable: false);

  @override
  Future<void> markDelivered(String eventId) async {}

  @override
  Future<void> markRetryableFailure(String eventId, {DateTime? now}) async {}

  @override
  Future<void> discard(String eventId) async {}

  @override
  Future<void> clear() async => queued.clear();

  @override
  Future<void> close() async => closed = true;
}

AppEventResources _resources(_MemoryOutbox outbox) => AppEventResources(
  outbox: outbox,
  actorId: 'actor_app',
  actorAccessToken: _actorToken,
  close: outbox.close,
);

void main() {
  test(
    'queue-only runtime still persists actor session and revision context',
    () async {
      final outbox = _MemoryOutbox();
      final runtime = AppEventRuntime.create(
        resources: _resources(outbox),
        playRevisionId: 'rev_app',
      );

      runtime.telemetry.event(MosaicEventName.mediaPlayback, const {
        'browser': 'safari',
        'videoCodec': 'h264',
      });
      await outbox.enqueued.future;

      final event = outbox.queued.single.envelope;
      expect(runtime.deliveryConfigured, isFalse);
      expect(event.actorId, 'actor_app');
      expect(event.sessionId, runtime.sessionId);
      expect(event.playRevisionId, 'rev_app');
      expect(event.payload['browser'], 'safari');
      expect(runtime.resources.actorAccess.accessToken, _actorToken);

      await runtime.close();
      expect(outbox.closed, isTrue);
    },
  );

  test(
    'invalid production API degrades to queue-only and reports config error',
    () async {
      final outbox = _MemoryOutbox();
      final errors = <String>[];
      final runtime = AppEventRuntime.create(
        resources: _resources(outbox),
        playRevisionId: 'rev_app',
        apiBaseUrl: 'http://api.example.test/',
        onError: (error, stackTrace, {operation}) {
          errors.add(operation ?? 'unknown');
        },
      );

      expect(runtime.deliveryConfigured, isFalse);
      expect(errors, ['event_transport_config']);

      runtime.telemetry.event(MosaicEventName.mediaPlayback, const {
        'phase': 'playbackError',
      });
      await outbox.enqueued.future;
      expect(outbox.queued, hasLength(1));

      await runtime.close();
    },
  );
}
