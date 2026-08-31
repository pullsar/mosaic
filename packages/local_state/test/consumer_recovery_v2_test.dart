import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:local_state/local_state.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const _actorToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

MosaicEventEnvelope _event() => MosaicEventEnvelope(
  eventId: 'evt_v1',
  event: MosaicEventName.playStarted,
  occurredAt: DateTime.utc(2026, 8, 28, 12),
  actorId: 'actor_v1',
  sessionId: 'session_v1',
  playRevisionId: 'rev_old',
);

void main() {
  test('guest engagement metadata is narrowly persisted and cleared', () {
    final store = MosaicLocalStore.openInMemory();
    const encoded = '{"seenIdentities":["request\\u0000revision"]}';
    store.saveGuestEngagementJson(encoded);
    expect(store.loadGuestEngagementJson(), encoded);
    store.clearGuestEngagementJson();
    expect(store.loadGuestEngagementJson(), isNull);
    store.close();
  });

  test(
    'v1 local consumer data migrates to v2 without identity or outbox loss',
    () {
      final temp = Directory.systemTemp.createTempSync('mosaic-consumer-v1-');
      final path = '${temp.path}/mosaic.db';
      try {
        final raw = sqlite3.open(path);
        raw.execute('''
        create table metadata (
          key text primary key,
          value text not null
        )
      ''');
        raw.execute('''
        create table topic_preferences (
          kind text not null,
          topic_id text not null,
          primary key (kind, topic_id)
        )
      ''');
        raw.execute('''
        create table feed_resume (
          singleton integer primary key check(singleton = 1),
          cursor text,
          window_json text not null,
          updated_at text not null
        )
      ''');
        raw.execute('''
        create table event_outbox (
          event_id text primary key,
          event_json text not null,
          byte_size integer not null,
          priority integer not null,
          attempt_count integer not null default 0,
          next_attempt_at text,
          created_at text not null
        )
      ''');
        raw.execute('insert into metadata (key, value) values (?, ?)', [
          'actor_id',
          'actor_v1',
        ]);
        raw.execute('insert into metadata (key, value) values (?, ?)', [
          'actor_access_token',
          _actorToken,
        ]);
        raw.execute(
          'insert into topic_preferences (kind, topic_id) values (?, ?)',
          ['interest', 'science'],
        );
        raw.execute(
          '''
        insert into feed_resume (singleton, cursor, window_json, updated_at)
        values (1, ?, ?, ?)
        ''',
          [
            'cursor_v1',
            jsonEncode(<String>['rev_old']),
            DateTime.utc(2026, 8, 28, 12).toIso8601String(),
          ],
        );
        final encodedEvent = jsonEncode(_event().toJson());
        raw.execute(
          '''
        insert into event_outbox (
          event_id, event_json, byte_size, priority, attempt_count, created_at
        ) values (?, ?, ?, ?, 0, ?)
        ''',
          [
            'evt_v1',
            encodedEvent,
            Uint8List.fromList(utf8.encode(encodedEvent)).length,
            OutboxPriority.analytics.value,
            DateTime.utc(2026, 8, 28, 12).toIso8601String(),
          ],
        );
        raw.execute('pragma user_version = 1');
        raw.close();

        final store = MosaicLocalStore.open(path);
        expect(store.userVersion, 2);
        final actor = store.getOrCreateActorAccess();
        expect(actor.actorId, 'actor_v1');
        expect(actor.accessToken, _actorToken);
        expect(store.interests(InterestKind.interest), {'science'});
        expect(store.dueEvents().single.eventId, 'evt_v1');

        final oldResume = store.loadFeedResume();
        expect(oldResume?.cursor, 'cursor_v1');
        expect(oldResume?.windowRevisionIds, const ['rev_old']);
        expect(oldResume?.requestId, isNull);
        expect(oldResume?.visibleRevisionId, isNull);
        expect(oldResume?.visiblePosition, isNull);

        store.saveFeedResume(
          requestId: 'feed_v2',
          cursor: 'cursor_v2',
          visibleRevisionId: 'rev_visible',
          visiblePosition: 3,
          windowRevisionIds: const ['rev_visible', 'rev_next'],
          updatedAt: DateTime.utc(2026, 8, 29, 12),
        );
        final enriched = store.loadFeedResume();
        expect(enriched?.requestId, 'feed_v2');
        expect(enriched?.visibleRevisionId, 'rev_visible');
        expect(enriched?.visiblePosition, 3);
        store.close();
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
  );

  test('recent feed cache is hard-bounded and expires stale recovery data', () {
    final store = MosaicLocalStore.openInMemory();
    final now = DateTime.utc(2026, 8, 29, 12);
    store.saveRecentFeedCache(
      requestId: 'feed_many',
      items: List<Map<String, Object?>>.generate(
        20,
        (index) => <String, Object?>{'revisionId': 'rev_$index'},
      ),
      updatedAt: now,
    );
    expect(
      store.loadRecentFeedCache(now: now)?.items,
      hasLength(MosaicLocalStore.defaultRecentFeedCacheMaxItems),
    );

    final large = List<String>.filled(100 * 1024, 'x').join();
    store.saveRecentFeedCache(
      requestId: 'feed_bytes',
      items: List<Map<String, Object?>>.generate(
        4,
        (index) => <String, Object?>{
          'revisionId': 'large_$index',
          'payload': large,
        },
      ),
      updatedAt: now,
    );
    expect(store.loadRecentFeedCache(now: now)?.items, hasLength(2));

    store.saveRecentFeedCache(
      requestId: 'feed_stale',
      items: const <Map<String, Object?>>[
        <String, Object?>{'revisionId': 'stale'},
      ],
      updatedAt: now.subtract(const Duration(days: 3)),
    );
    expect(store.loadRecentFeedCache(now: now), isNull);
    expect(store.loadRecentFeedCache(now: now), isNull);
    store.close();
  });

  // dart format off
  test('migration failure preserves verified v1 database', () {
    final temp = Directory.systemTemp.createTempSync('mosaic-migrate-v1-');
    final path = '${temp.path}/mosaic.db';
    try {
      final raw = sqlite3.open(path);
      raw.execute('''
        create table feed_resume (
          singleton integer primary key check(singleton = 1),
          cursor text,
          window_json text not null,
          updated_at text not null
        )
      ''');
      raw.execute('create table recent_feed_cache (marker text not null)');
      raw.execute(
        'insert into recent_feed_cache (marker) values (?)',
        ['preserve_me'],
      );
      raw.execute('pragma user_version = 1');
      raw.close();

      expect(
        () => MosaicLocalStore.open(path),
        throwsA(isA<SqliteException>()),
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
      final marker = reopened
          .select('select marker from recent_feed_cache')
          .single['marker'] as String;
      final columns = reopened
          .select('pragma table_info(feed_resume)')
          .map((row) => row['name'] as String)
          .toSet();
      reopened.close();

      expect(persistedVersion, 1);
      expect(marker, 'preserve_me');
      expect(columns, isNot(contains('request_id')));
      expect(columns, isNot(contains('visible_revision_id')));
      expect(columns, isNot(contains('visible_position')));
    } finally {
      temp.deleteSync(recursive: true);
    }
  });
  // dart format on
}
