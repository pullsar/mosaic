import 'dart:io';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:local_state/local_state.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

MosaicEventEnvelope _event(String id) => MosaicEventEnvelope(
  eventId: id,
  event: MosaicEventName.playStarted,
  occurredAt: DateTime.utc(2026, 8, 27, 20),
  actorId: 'actor_test',
  sessionId: 'session_test',
  playRevisionId: 'rev_test',
);

void main() {
  test('durable semantic state survives close and reopen', () {
    final temp = Directory.systemTemp.createTempSync('mosaic-local-');
    final path = '${temp.path}/mosaic.db';
    try {
      var store = MosaicLocalStore.open(
        path,
        actorIdFactory: () => 'actor_fixed',
      );
      expect(store.getOrCreateActorId(), 'actor_fixed');
      store.replaceInterests(InterestKind.interest, ['travel', 'food']);
      store.replaceInterests(InterestKind.learning, ['piano']);
      store.saveFeedResume(
        cursor: 'cursor_2',
        windowRevisionIds: ['rev_a', 'rev_b'],
        updatedAt: DateTime.utc(2026, 8, 27, 20),
      );
      store.saveDraft(
        CreatorDraft(
          id: 'draft_1',
          document: const {'format': 'guess'},
          updatedAt: DateTime.utc(2026, 8, 27, 20),
        ),
      );
      store.saveLocalAsset(
        LocalAssetRecord(
          id: 'asset_1',
          path: '/tmp/photo.jpg',
          kind: 'image',
          uploadSessionId: 'upload_1',
          uploadState: 'paused',
          updatedAt: DateTime.utc(2026, 8, 27, 20),
        ),
      );
      store.enqueueEvent(_event('evt_1'));
      store.close();

      store = MosaicLocalStore.open(path);
      expect(store.getOrCreateActorId(), 'actor_fixed');
      expect(store.interests(InterestKind.interest), {'food', 'travel'});
      expect(store.interests(InterestKind.learning), {'piano'});
      expect(store.loadFeedResume()?.cursor, 'cursor_2');
      expect(store.loadFeedResume()?.windowRevisionIds, ['rev_a', 'rev_b']);
      expect(store.loadDraft('draft_1')?.document['format'], 'guess');
      expect(store.loadLocalAsset('asset_1')?.uploadSessionId, 'upload_1');
      expect(store.dueEvents().single.eventId, 'evt_1');
      store.close();
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('feed resume metadata is normalized, deduplicated, and bounded', () {
    final store = MosaicLocalStore.openInMemory(maxFeedWindowRevisionIds: 3);
    store.saveFeedResume(
      cursor: 'cursor_3',
      windowRevisionIds: [' rev_a ', 'rev_b', 'rev_a', '', 'rev_c', 'rev_d'],
    );

    expect(store.loadFeedResume()?.windowRevisionIds, [
      'rev_a',
      'rev_b',
      'rev_c',
    ]);
    store.close();
  });

  test('interest identifiers are canonicalized before persistence', () {
    final store = MosaicLocalStore.openInMemory();
    store.replaceInterests(InterestKind.interest, [
      ' travel ',
      'travel',
      ' ',
      'food',
    ]);

    expect(store.interests(InterestKind.interest), {'food', 'travel'});
    store.close();
  });

  test('duplicate event identity produces one outbox item', () {
    final store = MosaicLocalStore.openInMemory();
    store.enqueueEvent(_event('evt_1'));
    store.enqueueEvent(_event('evt_1'));
    expect(store.outboxCount, 1);
    store.close();
  });

  test('failed delivery backs off and acknowledgement removes event', () {
    final store = MosaicLocalStore.openInMemory();
    final now = DateTime.utc(2026, 8, 27, 20);
    store.enqueueEvent(_event('evt_retry'), createdAt: now);

    store.markEventFailed('evt_retry', now: now);
    expect(store.dueEvents(now: now), isEmpty);
    final pending = store
        .dueEvents(now: now.add(const Duration(seconds: 2)))
        .single;
    expect(pending.attemptCount, 1);
    expect(pending.nextAttemptAt, now.add(const Duration(seconds: 2)));

    store.markEventSent('evt_retry');
    expect(store.outboxCount, 0);
    store.close();
  });

  test(
    'non-positive due-event limits never expand into an unbounded query',
    () {
      final store = MosaicLocalStore.openInMemory();
      store.enqueueEvent(_event('evt_1'));

      expect(store.dueEvents(limit: 0), isEmpty);
      expect(store.dueEvents(limit: -1), isEmpty);
      store.close();
    },
  );

  test('spool pressure drops low-value events before critical events', () {
    final store = MosaicLocalStore.openInMemory(
      policy: const OutboxPolicy(maxCount: 2, maxBytes: 100000),
    );
    store.enqueueEvent(_event('critical'), priority: OutboxPriority.critical);
    store.enqueueEvent(_event('analytics_old'));
    store.enqueueEvent(_event('analytics_new'));

    final ids = store
        .dueEvents(limit: 10)
        .map((event) => event.eventId)
        .toSet();
    expect(ids, contains('critical'));
    expect(ids, contains('analytics_new'));
    expect(ids, isNot(contains('analytics_old')));
    store.close();
  });

  test('age pruning preserves critical pending mutations', () {
    final store = MosaicLocalStore.openInMemory(
      policy: const OutboxPolicy(maxAge: Duration(days: 1)),
    );
    final old = DateTime.utc(2026, 8, 20);
    store.enqueueEvent(_event('analytics_old'), createdAt: old);
    store.enqueueEvent(
      _event('critical_old'),
      priority: OutboxPriority.critical,
      createdAt: old,
    );

    store.pruneOutbox(now: DateTime.utc(2026, 8, 27));
    final ids = store
        .dueEvents(limit: 10)
        .map((event) => event.eventId)
        .toSet();
    expect(ids, {'critical_old'});
    store.close();
  });

  test(
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

  test('newer local schema is rejected without destructive quarantine', () {
    final temp = Directory.systemTemp.createTempSync('mosaic-newer-schema-');
    final path = '${temp.path}/mosaic.db';
    try {
      final newerVersion = MosaicLocalStore.schemaVersion + 1;
      final raw = sqlite3.open(path);
      raw.execute('pragma user_version = $newerVersion');
      raw.close();

      expect(
        () => MosaicLocalStore.open(path),
        throwsA(
          isA<UnsupportedLocalSchemaException>()
              .having(
                (error) => error.foundVersion,
                'foundVersion',
                newerVersion,
              )
              .having(
                (error) => error.supportedVersion,
                'supportedVersion',
                MosaicLocalStore.schemaVersion,
              ),
        ),
      );

      expect(
        temp.listSync().whereType<File>().where(
          (file) => file.path.contains('.corrupt.'),
        ),
        isEmpty,
      );
      final reopened = sqlite3.open(path);
      final persistedVersion =
          reopened.select('pragma user_version').first.values.first as int;
      reopened.close();
      expect(persistedVersion, newerVersion);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test('corrupt local database is quarantined and replaced safely', () {
    final temp = Directory.systemTemp.createTempSync('mosaic-corrupt-');
    final path = '${temp.path}/mosaic.db';
    try {
      File(path).writeAsStringSync('not a sqlite database');
      final store = MosaicLocalStore.open(
        path,
        actorIdFactory: () => 'actor_after_recovery',
      );
      expect(store.userVersion, MosaicLocalStore.schemaVersion);
      expect(store.getOrCreateActorId(), 'actor_after_recovery');
      store.close();

      final quarantined = temp.listSync().whereType<File>().where(
        (file) => file.path.contains('.corrupt.'),
      );
      expect(quarantined, isNotEmpty);
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
}
