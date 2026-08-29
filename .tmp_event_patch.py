from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    if old not in text:
        raise SystemExit(f'expected block not found in {path}')
    file.write_text(text.replace(old, new, 1))


replace_once(
    'packages/local_state/lib/local_state.dart',
    """    nextAttemptAt: (row['next_attempt_at'] as String?) case final value?
        ? DateTime.parse(value)
        : null,
""",
    """    nextAttemptAt: row['next_attempt_at'] == null
        ? null
        : DateTime.parse(row['next_attempt_at'] as String),
""",
)

replace_once(
    'packages/event_delivery/lib/src/indexed_db_event_store.dart',
    """      final candidates =
          records
              .where((record) => record.priority != EventPriority.critical)
              .toList(growable: false)
            ..sort(_compareEvictionOrder);
      if (candidates.isEmpty) return;
""",
    """      final candidates = records.toList(growable: false)
        ..sort(_compareEvictionOrder);
      if (candidates.isEmpty) return;
""",
)

replace_once(
    'packages/local_state/test/local_state_test.dart',
    """  test(
    'critical pending mutation is never evicted solely to meet spool cap',
    () {
      final store = MosaicLocalStore.openInMemory(
        policy: const OutboxPolicy(maxCount: 1, maxBytes: 100000),
      );
      store.enqueueEvent(
        _event('critical_a'),
        priority: OutboxPriority.critical,
      );
      store.enqueueEvent(
        _event('critical_b'),
        priority: OutboxPriority.critical,
      );

      expect(store.outboxCount, 2);
      store.close();
    },
  );
""",
    """  test(
    'critical pending mutations are last-resort hard-cap eviction candidates',
    () {
      final store = MosaicLocalStore.openInMemory(
        policy: const OutboxPolicy(maxCount: 1, maxBytes: 100000),
      );
      final now = DateTime.utc(2026, 8, 27, 20);
      store.enqueueEvent(
        _event('critical_a'),
        priority: OutboxPriority.critical,
        createdAt: now,
      );
      store.enqueueEvent(
        _event('critical_b'),
        priority: OutboxPriority.critical,
        createdAt: now.add(const Duration(seconds: 1)),
      );

      expect(store.outboxCount, 1);
      expect(store.dueEvents(limit: 10).single.eventId, 'critical_b');
      store.close();
    },
  );
""",
)

replace_once(
    'packages/event_delivery/test_web/indexed_db_event_store_web_test.dart',
    """  test(
    'critical events are never evicted solely to meet the count cap',
    () async {
      final name = _databaseName('critical');
      final store = await IndexedDbEventStore.open(
        databaseName: name,
        policy: const EventOutboxPolicy(maxCount: 1, maxBytes: 100000),
      );
      try {
        await store.enqueue(
          _event('critical_a'),
          priority: EventPriority.critical,
        );
        await store.enqueue(
          _event('critical_b'),
          priority: EventPriority.critical,
        );

        final ids = (await store.due(
          now: DateTime.utc(2026, 8, 29),
        )).map((queued) => queued.envelope.eventId).toSet();
        expect(ids, {'critical_a', 'critical_b'});
      } finally {
        await store.close();
        await IndexedDbEventStore.deleteDatabase(name);
      }
    },
  );
""",
    """  test(
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
""",
)

replace_once(
    'docs/event-delivery.md',
    '- critical events are not evicted solely to satisfy count/byte pressure.\n',
    '- lower-priority events are evicted first; oldest critical events are evicted only as a last resort to enforce the hard count/byte cap.\n',
)
