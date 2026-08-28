import 'dart:async';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:test/test.dart';

final class _MemoryOutbox implements EventOutbox {
  final events = <QueuedEvent>[];
  final enqueued = Completer<void>();
  var delivered = <String>[];
  var discarded = <String>[];
  var failed = <String>[];

  @override
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  }) async {
    if (events.any((queued) => queued.envelope.eventId == event.eventId))
      return;
    events.add(
      QueuedEvent(
        envelope: event,
        priority: priority,
        attemptCount: 0,
        createdAt: createdAt ?? DateTime.utc(2026, 8, 28),
      ),
    );
    if (!enqueued.isCompleted) enqueued.complete();
  }

  @override
  Future<List<QueuedEvent>> due({DateTime? now, int limit = 50}) async =>
      events.take(limit).toList(growable: false);

  @override
  Future<void> markDelivered(String eventId) async {
    delivered.add(eventId);
    events.removeWhere((queued) => queued.envelope.eventId == eventId);
  }

  @override
  Future<void> markRetryableFailure(String eventId, {DateTime? now}) async {
    failed.add(eventId);
  }

  @override
  Future<void> discard(String eventId) async {
    discarded.add(eventId);
    events.removeWhere((queued) => queued.envelope.eventId == eventId);
  }

  @override
  Future<void> clear() async => events.clear();

  @override
  Future<void> close() async {}
}

final class _SequenceTransport implements EventTransport {
  _SequenceTransport(this.results, {this.gate});

  final List<EventDeliveryResult> results;
  final Completer<void>? gate;
  var calls = 0;

  @override
  Future<EventDeliveryResult> deliver(MosaicEventEnvelope event) async {
    calls += 1;
    await gate?.future;
    return results.removeAt(0);
  }

  @override
  Future<void> close() async {}
}

MosaicEventEnvelope _event(String id) => MosaicEventEnvelope(
  eventId: id,
  event: MosaicEventName.playStarted,
  occurredAt: DateTime.utc(2026, 8, 28, 18),
  actorId: 'actor_1',
  sessionId: 'session_1',
);

void main() {
  test(
    'telemetry captures a stable envelope before asynchronous context resolves',
    () async {
      final outbox = _MemoryOutbox();
      final contextGate = Completer<EventContext>();
      final payload = <String, Object?>{
        'phase': 'firstFramePainted',
        'nested': <String, Object?>{'codec': 'h264'},
      };
      final telemetry = MosaicEventTelemetry(
        outbox: outbox,
        contextProvider: () => contextGate.future,
        eventIdFactory: () => 'evt_fixed',
        clock: () => DateTime.utc(2026, 8, 28, 18, 30),
      );

      telemetry.event(MosaicEventName.mediaPlayback, payload);
      (payload['nested']! as Map<String, Object?>)['codec'] = 'mutated';
      contextGate.complete(
        EventContext(
          actorId: 'actor_fixed',
          sessionId: 'session_fixed',
          feedRequestId: 'feed_1',
          playRevisionId: 'rev_1',
        ),
      );
      await outbox.enqueued.future;

      final event = outbox.events.single.envelope;
      expect(event.eventId, 'evt_fixed');
      expect(event.occurredAt, DateTime.utc(2026, 8, 28, 18, 30));
      expect(event.actorId, 'actor_fixed');
      expect(event.sessionId, 'session_fixed');
      expect(event.feedRequestId, 'feed_1');
      expect(event.playRevisionId, 'rev_1');
      expect((event.payload['nested']! as Map)['codec'], 'h264');
    },
  );

  test('invalid telemetry payload is isolated from the observed feature', () {
    final outbox = _MemoryOutbox();
    final errors = <String>[];
    final telemetry = MosaicEventTelemetry(
      outbox: outbox,
      contextProvider: () =>
          EventContext(actorId: 'actor', sessionId: 'session'),
      eventIdFactory: () => 'evt',
      onInternalError: (error, stackTrace, {operation}) {
        errors.add(operation ?? 'unknown');
      },
    );

    expect(
      () => telemetry.event(MosaicEventName.playStarted, {'bad': Object()}),
      returnsNormally,
    );
    expect(errors, ['event_prepare']);
  });

  test(
    'retryable delivery stops the drain and leaves later events untouched',
    () async {
      final outbox = _MemoryOutbox();
      await outbox.enqueue(_event('evt_1'));
      await outbox.enqueue(_event('evt_2'));
      final transport = _SequenceTransport([
        const EventDeliveryResult(EventDeliveryDisposition.retryableFailure),
      ]);
      final controller = EventDrainController(
        outbox: outbox,
        transport: transport,
      );

      final summary = await controller.drain(
        now: DateTime.utc(2026, 8, 28, 18),
      );

      expect(summary.delivered, 0);
      expect(summary.retryDeferred, 1);
      expect(outbox.failed, ['evt_1']);
      expect(transport.calls, 1);
      expect(outbox.events.map((event) => event.envelope.eventId), [
        'evt_1',
        'evt_2',
      ]);
    },
  );

  test('permanent rejection is discarded and drain continues', () async {
    final outbox = _MemoryOutbox();
    await outbox.enqueue(_event('evt_bad'));
    await outbox.enqueue(_event('evt_good'));
    final transport = _SequenceTransport([
      const EventDeliveryResult(
        EventDeliveryDisposition.rejected,
        statusCode: 400,
      ),
      const EventDeliveryResult(
        EventDeliveryDisposition.accepted,
        statusCode: 202,
      ),
    ]);
    final rejected = <String>[];
    final controller = EventDrainController(
      outbox: outbox,
      transport: transport,
      onRejected: (event, result) => rejected.add(event.eventId),
    );

    final summary = await controller.drain();

    expect(summary.rejected, 1);
    expect(summary.delivered, 1);
    expect(outbox.discarded, ['evt_bad']);
    expect(outbox.delivered, ['evt_good']);
    expect(rejected, ['evt_bad']);
    expect(outbox.events, isEmpty);
  });

  test('concurrent drain requests coalesce into one transport pass', () async {
    final outbox = _MemoryOutbox();
    await outbox.enqueue(_event('evt_1'));
    final gate = Completer<void>();
    final transport = _SequenceTransport([
      const EventDeliveryResult(
        EventDeliveryDisposition.accepted,
        statusCode: 202,
      ),
    ], gate: gate);
    final controller = EventDrainController(
      outbox: outbox,
      transport: transport,
    );

    final first = controller.drain();
    final second = controller.drain();
    expect(identical(first, second), isTrue);
    gate.complete();

    expect((await first).delivered, 1);
    expect(transport.calls, 1);
  });

  test('secure UUID generator produces RFC 4122 version 4 shape', () {
    final value = secureUuidV4();
    expect(
      value,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });
}
