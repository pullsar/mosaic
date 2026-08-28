import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:local_state/local_state.dart';
import 'package:test/test.dart';

MosaicEventEnvelope _event(String id) => MosaicEventEnvelope(
  eventId: id,
  event: MosaicEventName.playStarted,
  occurredAt: DateTime.utc(2026, 8, 28, 18),
  actorId: 'actor_1',
  sessionId: 'session_1',
  payload: {'id': id},
);

void main() {
  test('reuses local-state dedupe, ordering and retry backoff', () async {
    final store = MosaicLocalStore.openInMemory();
    final outbox = SqliteEventOutbox(store);
    final now = DateTime.utc(2026, 8, 28, 18);

    await outbox.enqueue(_event('analytics'), createdAt: now);
    await outbox.enqueue(
      _event('critical'),
      priority: EventPriority.critical,
      createdAt: now.add(const Duration(seconds: 1)),
    );
    await outbox.enqueue(_event('analytics'), createdAt: now);

    final first = await outbox.due(now: now.add(const Duration(seconds: 2)));
    expect(first.map((event) => event.envelope.eventId), [
      'critical',
      'analytics',
    ]);
    expect(first.first.priority, EventPriority.critical);

    await outbox.markRetryableFailure('critical', now: now);
    final immediatelyDue = await outbox.due(now: now);
    expect(immediatelyDue.map((event) => event.envelope.eventId), [
      'analytics',
    ]);
    final afterBackoff = await outbox.due(
      now: now.add(const Duration(seconds: 2)),
    );
    expect(afterBackoff.first.envelope.eventId, 'critical');
    expect(afterBackoff.first.attemptCount, 1);

    await outbox.close();
    store.close();
  });

  test('clear removes due and backoff-deferred events', () async {
    final store = MosaicLocalStore.openInMemory();
    final outbox = SqliteEventOutbox(store);
    final now = DateTime.utc(2026, 8, 28, 18);
    await outbox.enqueue(_event('evt_1'), createdAt: now);
    await outbox.enqueue(_event('evt_2'), createdAt: now);
    await outbox.markRetryableFailure('evt_2', now: now);

    await outbox.clear();

    expect(store.outboxCount, 0);
    await outbox.close();
    store.close();
  });

  test('adapter can own and close the underlying store explicitly', () async {
    final store = MosaicLocalStore.openInMemory();
    final outbox = SqliteEventOutbox(store, closeStoreOnClose: true);
    await outbox.close();

    await expectLater(() => outbox.due(), throwsStateError);
  });
}
