import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:test/test.dart';

MosaicEventEnvelope _event(String id) => MosaicEventEnvelope(
  eventId: id,
  event: MosaicEventName.mediaPlayback,
  occurredAt: DateTime.utc(2026, 8, 28, 18),
  actorId: 'actor_web',
  sessionId: 'session_web',
  payload: {'id': id, 'browser': 'chrome', 'videoCodec': 'h264'},
);

String _databaseName(String suffix) =>
    'mosaic_event_test_${suffix}_${secureUuidV4()}';

void main() {
  test(
    'actor identity and queued events survive browser-store reopen',
    () async {
      final name = _databaseName('reopen');
      var store = await IndexedDbEventStore.open(databaseName: name);
      try {
        final actorId = await store.getOrCreateActorId();
        await store.bindActorToUser(actorId, 'user_1');
        await store.enqueue(_event('evt_1'));
        await store.close();

        store = await IndexedDbEventStore.open(databaseName: name);
        expect(await store.getOrCreateActorId(), actorId);
        expect(await store.boundUserId(), 'user_1');
        final due = await store.due(now: DateTime.utc(2026, 8, 29));
        expect(due, hasLength(1));
        expect(due.single.envelope.eventId, 'evt_1');
        expect(due.single.envelope.payload['videoCodec'], 'h264');
      } finally {
        await store.close();
        await IndexedDbEventStore.deleteDatabase(name);
      }
    },
  );

  test(
    'duplicate enqueue preserves retry identity and backoff state',
    () async {
      final name = _databaseName('dedupe');
      final store = await IndexedDbEventStore.open(databaseName: name);
      final now = DateTime.utc(2026, 8, 28, 18);
      try {
        await store.enqueue(_event('evt_retry'), createdAt: now);
        await store.markRetryableFailure('evt_retry', now: now);
        await store.enqueue(_event('evt_retry'), createdAt: now);

        expect(await store.due(now: now), isEmpty);
        final due = await store.due(now: now.add(const Duration(seconds: 2)));
        expect(due, hasLength(1));
        expect(due.single.envelope.eventId, 'evt_retry');
        expect(due.single.attemptCount, 1);
      } finally {
        await store.close();
        await IndexedDbEventStore.deleteDatabase(name);
      }
    },
  );

  test(
    'queue pressure evicts oldest low-value event before critical work',
    () async {
      final name = _databaseName('pressure');
      final store = await IndexedDbEventStore.open(
        databaseName: name,
        policy: const EventOutboxPolicy(maxCount: 2, maxBytes: 100000),
      );
      final now = DateTime.utc(2026, 8, 28, 18);
      try {
        await store.enqueue(
          _event('critical'),
          priority: EventPriority.critical,
          createdAt: now,
        );
        await store.enqueue(
          _event('analytics_old'),
          createdAt: now.add(const Duration(seconds: 1)),
        );
        await store.enqueue(
          _event('analytics_new'),
          createdAt: now.add(const Duration(seconds: 2)),
        );

        final ids = (await store.due(
          now: now.add(const Duration(minutes: 1)),
        )).map((queued) => queued.envelope.eventId).toSet();
        expect(ids, {'critical', 'analytics_new'});
      } finally {
        await store.close();
        await IndexedDbEventStore.deleteDatabase(name);
      }
    },
  );

  test(
    'critical events are last-resort hard-cap eviction candidates',
    () async {
      final name = _databaseName('critical');
      final store = await IndexedDbEventStore.open(
        databaseName: name,
        policy: const EventOutboxPolicy(maxCount: 1, maxBytes: 100000),
      );
      final now = DateTime.utc(2026, 8, 28, 18);
      try {
        await store.enqueue(
          _event('critical_a'),
          priority: EventPriority.critical,
          createdAt: now,
        );
        await store.enqueue(
          _event('critical_b'),
          priority: EventPriority.critical,
          createdAt: now.add(const Duration(seconds: 1)),
        );

        final ids = (await store.due(
          now: DateTime.utc(2026, 8, 29),
        )).map((queued) => queued.envelope.eventId).toSet();
        expect(ids, {'critical_b'});
      } finally {
        await store.close();
        await IndexedDbEventStore.deleteDatabase(name);
      }
    },
  );

  test(
    'age pruning drops stale analytics but preserves stale critical work',
    () async {
      final name = _databaseName('age');
      final store = await IndexedDbEventStore.open(
        databaseName: name,
        policy: const EventOutboxPolicy(
          maxCount: 10,
          maxBytes: 100000,
          maxAge: Duration(days: 1),
        ),
      );
      final old = DateTime.utc(2026, 8, 20);
      final now = DateTime.utc(2026, 8, 28);
      try {
        await store.enqueue(_event('analytics_old'), createdAt: old);
        await store.enqueue(
          _event('critical_old'),
          priority: EventPriority.critical,
          createdAt: old,
        );
        await store.enqueue(_event('analytics_new'), createdAt: now);

        final ids = (await store.due(
          now: now,
        )).map((queued) => queued.envelope.eventId).toSet();
        expect(ids, {'critical_old', 'analytics_new'});
      } finally {
        await store.close();
        await IndexedDbEventStore.deleteDatabase(name);
      }
    },
  );

  test('clear removes queued events without deleting actor identity', () async {
    final name = _databaseName('clear');
    final store = await IndexedDbEventStore.open(databaseName: name);
    try {
      final actorId = await store.getOrCreateActorId();
      await store.enqueue(_event('evt_1'));
      await store.enqueue(_event('evt_2'));

      await store.clear();

      expect(await store.due(now: DateTime.utc(2026, 8, 29)), isEmpty);
      expect(await store.getOrCreateActorId(), actorId);
    } finally {
      await store.close();
      await IndexedDbEventStore.deleteDatabase(name);
    }
  });

  test(
    'invalid production outbox policy fails before opening IndexedDB',
    () async {
      await expectLater(
        IndexedDbEventStore.open(
          databaseName: _databaseName('invalid_age'),
          policy: const EventOutboxPolicy(maxAge: Duration(seconds: -1)),
        ),
        throwsArgumentError,
      );
      await expectLater(
        IndexedDbEventStore.open(
          databaseName: _databaseName('invalid_backoff'),
          policy: const EventOutboxPolicy(maxBackoff: Duration(seconds: -1)),
        ),
        throwsArgumentError,
      );
    },
  );
}
