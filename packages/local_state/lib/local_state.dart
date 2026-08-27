library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:sqlite3/sqlite3.dart';

enum InterestKind { interest, learning }

enum OutboxPriority {
  analytics(0),
  normal(50),
  critical(100);

  const OutboxPriority(this.value);
  final int value;
}

final class FeedResumeState {
  const FeedResumeState({
    required this.cursor,
    required this.windowRevisionIds,
    required this.updatedAt,
  });

  final String? cursor;
  final List<String> windowRevisionIds;
  final DateTime updatedAt;
}

final class CreatorDraft {
  const CreatorDraft({
    required this.id,
    required this.document,
    required this.updatedAt,
  });

  final String id;
  final Map<String, Object?> document;
  final DateTime updatedAt;
}

final class LocalAssetRecord {
  const LocalAssetRecord({
    required this.id,
    required this.path,
    required this.kind,
    required this.uploadState,
    required this.updatedAt,
    this.uploadSessionId,
    this.metadata = const {},
  });

  final String id;
  final String path;
  final String kind;
  final String uploadState;
  final String? uploadSessionId;
  final Map<String, Object?> metadata;
  final DateTime updatedAt;
}

final class PendingEvent {
  const PendingEvent({
    required this.eventId,
    required this.event,
    required this.priority,
    required this.attemptCount,
    required this.createdAt,
    this.nextAttemptAt,
  });

  final String eventId;
  final Map<String, Object?> event;
  final OutboxPriority priority;
  final int attemptCount;
  final DateTime createdAt;
  final DateTime? nextAttemptAt;
}

final class OutboxPolicy {
  const OutboxPolicy({
    this.maxCount = 1000,
    this.maxBytes = 1024 * 1024,
    this.maxAge = const Duration(days: 14),
    this.maxBackoff = const Duration(hours: 1),
  });

  final int maxCount;
  final int maxBytes;
  final Duration maxAge;
  final Duration maxBackoff;
}

final class UnsupportedLocalSchemaException implements Exception {
  const UnsupportedLocalSchemaException({
    required this.foundVersion,
    required this.supportedVersion,
  });

  final int foundVersion;
  final int supportedVersion;

  @override
  String toString() =>
      'Local database schema $foundVersion is newer than supported '
      '$supportedVersion.';
}

typedef ActorIdFactory = String Function();

final class MosaicLocalStore {
  MosaicLocalStore._(
    this._db, {
    required this.policy,
    required this.maxFeedWindowRevisionIds,
    required ActorIdFactory actorIdFactory,
  }) : _actorIdFactory = actorIdFactory;

  static const int schemaVersion = 1;
  static const int defaultMaxFeedWindowRevisionIds = 64;

  final Database _db;
  final OutboxPolicy policy;
  final int maxFeedWindowRevisionIds;
  final ActorIdFactory _actorIdFactory;

  static MosaicLocalStore open(
    String path, {
    OutboxPolicy policy = const OutboxPolicy(),
    int maxFeedWindowRevisionIds = defaultMaxFeedWindowRevisionIds,
    ActorIdFactory actorIdFactory = _randomUuidV4,
  }) {
    _validateFeedWindowLimit(maxFeedWindowRevisionIds);
    Database? candidate;
    try {
      candidate = sqlite3.open(path);
      final store = MosaicLocalStore._(
        candidate,
        policy: policy,
        maxFeedWindowRevisionIds: maxFeedWindowRevisionIds,
        actorIdFactory: actorIdFactory,
      );
      store._verifyIntegrity();
      store._migrate();
      return store;
    } on UnsupportedLocalSchemaException {
      candidate?.close();
      rethrow;
    } on Object {
      candidate?.close();
      _quarantineCorruptDatabase(path);
      final db = sqlite3.open(path);
      final store = MosaicLocalStore._(
        db,
        policy: policy,
        maxFeedWindowRevisionIds: maxFeedWindowRevisionIds,
        actorIdFactory: actorIdFactory,
      );
      store._migrate();
      return store;
    }
  }

  static MosaicLocalStore openInMemory({
    OutboxPolicy policy = const OutboxPolicy(),
    int maxFeedWindowRevisionIds = defaultMaxFeedWindowRevisionIds,
    ActorIdFactory actorIdFactory = _randomUuidV4,
  }) {
    _validateFeedWindowLimit(maxFeedWindowRevisionIds);
    final store = MosaicLocalStore._(
      sqlite3.openInMemory(),
      policy: policy,
      maxFeedWindowRevisionIds: maxFeedWindowRevisionIds,
      actorIdFactory: actorIdFactory,
    );
    store._migrate();
    return store;
  }

  void close() => _db.close();

  int get userVersion {
    final rows = _db.select('pragma user_version');
    return rows.first.values.first as int;
  }

  String getOrCreateActorId() {
    final existing = _metadata('actor_id');
    if (existing != null && existing.isNotEmpty) return existing;
    final created = _actorIdFactory();
    _setMetadata('actor_id', created);
    return created;
  }

  void replaceInterests(InterestKind kind, Iterable<String> topicIds) {
    _transaction(() {
      _db.execute('delete from topic_preferences where kind = ?', [kind.name]);
      final unique = topicIds
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet();
      for (final topic in unique) {
        _db.execute(
          'insert into topic_preferences (kind, topic_id) values (?, ?)',
          [kind.name, topic],
        );
      }
    });
  }

  Set<String> interests(InterestKind kind) => _db
      .select(
        'select topic_id from topic_preferences where kind = ? order by topic_id',
        [kind.name],
      )
      .map((row) => row['topic_id'] as String)
      .toSet();

  void saveFeedResume({
    required String? cursor,
    required List<String> windowRevisionIds,
    DateTime? updatedAt,
  }) {
    final boundedWindow = <String>[];
    final seen = <String>{};
    for (final revisionId in windowRevisionIds) {
      final normalized = revisionId.trim();
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      boundedWindow.add(normalized);
      if (boundedWindow.length >= maxFeedWindowRevisionIds) break;
    }

    _db.execute(
      '''
      insert into feed_resume (singleton, cursor, window_json, updated_at)
      values (1, ?, ?, ?)
      on conflict(singleton) do update set
        cursor = excluded.cursor,
        window_json = excluded.window_json,
        updated_at = excluded.updated_at
      ''',
      [
        cursor,
        jsonEncode(boundedWindow),
        (updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
      ],
    );
  }

  FeedResumeState? loadFeedResume() {
    final rows = _db.select(
      'select cursor, window_json, updated_at from feed_resume where singleton = 1',
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return FeedResumeState(
      cursor: row['cursor'] as String?,
      windowRevisionIds: (jsonDecode(row['window_json'] as String) as List)
          .cast<String>(),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  void saveDraft(CreatorDraft draft) {
    _db.execute(
      '''
      insert into creator_drafts (id, document_json, updated_at)
      values (?, ?, ?)
      on conflict(id) do update set
        document_json = excluded.document_json,
        updated_at = excluded.updated_at
      ''',
      [
        draft.id,
        jsonEncode(draft.document),
        draft.updatedAt.toUtc().toIso8601String(),
      ],
    );
  }

  CreatorDraft? loadDraft(String id) {
    final rows = _db.select(
      'select document_json, updated_at from creator_drafts where id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return CreatorDraft(
      id: id,
      document: (jsonDecode(row['document_json'] as String) as Map)
          .cast<String, Object?>(),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  void saveLocalAsset(LocalAssetRecord asset) {
    _db.execute(
      '''
      insert into local_assets (
        id, path, kind, upload_session_id, upload_state, metadata_json, updated_at
      ) values (?, ?, ?, ?, ?, ?, ?)
      on conflict(id) do update set
        path = excluded.path,
        kind = excluded.kind,
        upload_session_id = excluded.upload_session_id,
        upload_state = excluded.upload_state,
        metadata_json = excluded.metadata_json,
        updated_at = excluded.updated_at
      ''',
      [
        asset.id,
        asset.path,
        asset.kind,
        asset.uploadSessionId,
        asset.uploadState,
        jsonEncode(asset.metadata),
        asset.updatedAt.toUtc().toIso8601String(),
      ],
    );
  }

  LocalAssetRecord? loadLocalAsset(String id) {
    final rows = _db.select(
      '''
      select path, kind, upload_session_id, upload_state, metadata_json, updated_at
      from local_assets where id = ?
      ''',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return LocalAssetRecord(
      id: id,
      path: row['path'] as String,
      kind: row['kind'] as String,
      uploadSessionId: row['upload_session_id'] as String?,
      uploadState: row['upload_state'] as String,
      metadata: (jsonDecode(row['metadata_json'] as String) as Map)
          .cast<String, Object?>(),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  void enqueueEvent(
    MosaicEventEnvelope event, {
    OutboxPriority priority = OutboxPriority.analytics,
    DateTime? createdAt,
  }) {
    final encoded = jsonEncode(event.toJson());
    final instant = createdAt ?? DateTime.now().toUtc();
    _db.execute(
      '''
      insert into event_outbox (
        event_id, event_json, byte_size, priority, attempt_count, next_attempt_at, created_at
      ) values (?, ?, ?, ?, 0, null, ?)
      on conflict(event_id) do nothing
      ''',
      [
        event.eventId,
        encoded,
        utf8.encode(encoded).length,
        priority.value,
        instant.toIso8601String(),
      ],
    );
    pruneOutbox(now: instant);
  }

  List<PendingEvent> dueEvents({DateTime? now, int limit = 50}) {
    if (limit <= 0) return const [];
    final instant = (now ?? DateTime.now().toUtc()).toIso8601String();
    return _db
        .select(
          '''
          select event_id, event_json, priority, attempt_count, next_attempt_at, created_at
          from event_outbox
          where next_attempt_at is null or next_attempt_at <= ?
          order by priority desc, created_at asc
          limit ?
          ''',
          [instant, limit],
        )
        .map(_pendingEventFromRow)
        .toList(growable: false);
  }

  void markEventSent(String eventId) {
    _db.execute('delete from event_outbox where event_id = ?', [eventId]);
  }

  void markEventFailed(String eventId, {DateTime? now}) {
    final rows = _db.select(
      'select attempt_count from event_outbox where event_id = ?',
      [eventId],
    );
    if (rows.isEmpty) return;
    final attempts = (rows.first['attempt_count'] as int) + 1;
    final exponentialSeconds = 1 << min(attempts, 20);
    final delay = Duration(
      seconds: min(exponentialSeconds, policy.maxBackoff.inSeconds),
    );
    final retryAt = (now ?? DateTime.now().toUtc()).add(delay);
    _db.execute(
      '''
      update event_outbox
      set attempt_count = ?, next_attempt_at = ?
      where event_id = ?
      ''',
      [attempts, retryAt.toIso8601String(), eventId],
    );
  }

  int get outboxCount =>
      (_db.select('select count(*) as count from event_outbox').first['count']
          as int);

  int get outboxBytes =>
      (_db
              .select(
                'select coalesce(sum(byte_size), 0) as bytes from event_outbox',
              )
              .first['bytes']
          as int);

  void pruneOutbox({DateTime? now}) {
    final current = now ?? DateTime.now().toUtc();
    final cutoff = current.subtract(policy.maxAge).toIso8601String();
    _db.execute(
      'delete from event_outbox where priority < ? and created_at < ?',
      [OutboxPriority.critical.value, cutoff],
    );

    while (outboxCount > policy.maxCount || outboxBytes > policy.maxBytes) {
      final candidate = _db.select(
        '''
        select event_id from event_outbox
        where priority < ?
        order by priority asc, created_at asc
        limit 1
        ''',
        [OutboxPriority.critical.value],
      );
      if (candidate.isEmpty) break;
      _db.execute('delete from event_outbox where event_id = ?', [
        candidate.first['event_id'],
      ]);
    }
  }

  void _verifyIntegrity() {
    final result = _db.select('pragma quick_check(1)');
    if (result.isEmpty || result.first.values.first != 'ok') {
      throw StateError('Local database integrity check failed.');
    }
  }

  void _migrate() {
    final version = userVersion;
    if (version > schemaVersion) {
      throw UnsupportedLocalSchemaException(
        foundVersion: version,
        supportedVersion: schemaVersion,
      );
    }
    if (version == 0) {
      _transaction(() {
        _db.execute('''
          create table metadata (
            key text primary key,
            value text not null
          )
        ''');
        _db.execute('''
          create table topic_preferences (
            kind text not null,
            topic_id text not null,
            primary key (kind, topic_id)
          )
        ''');
        _db.execute('''
          create table feed_resume (
            singleton integer primary key check(singleton = 1),
            cursor text,
            window_json text not null,
            updated_at text not null
          )
        ''');
        _db.execute('''
          create table creator_drafts (
            id text primary key,
            document_json text not null,
            updated_at text not null
          )
        ''');
        _db.execute('''
          create table local_assets (
            id text primary key,
            path text not null,
            kind text not null,
            upload_session_id text,
            upload_state text not null,
            metadata_json text not null,
            updated_at text not null
          )
        ''');
        _db.execute('''
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
        _db.execute('''
          create index event_outbox_due_idx
          on event_outbox(priority desc, next_attempt_at, created_at)
        ''');
        _db.execute('pragma user_version = $schemaVersion');
      });
    }
  }

  String? _metadata(String key) {
    final rows = _db.select('select value from metadata where key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void _setMetadata(String key, String value) {
    _db.execute(
      '''
      insert into metadata (key, value) values (?, ?)
      on conflict(key) do update set value = excluded.value
      ''',
      [key, value],
    );
  }

  void _transaction(void Function() body) {
    _db.execute('begin immediate');
    try {
      body();
      _db.execute('commit');
    } on Object {
      _db.execute('rollback');
      rethrow;
    }
  }

  PendingEvent _pendingEventFromRow(Row row) {
    final priorityValue = row['priority'] as int;
    return PendingEvent(
      eventId: row['event_id'] as String,
      event: (jsonDecode(row['event_json'] as String) as Map)
          .cast<String, Object?>(),
      priority: OutboxPriority.values.firstWhere(
        (value) => value.value == priorityValue,
        orElse: () => OutboxPriority.normal,
      ),
      attemptCount: row['attempt_count'] as int,
      createdAt: DateTime.parse(row['created_at'] as String),
      nextAttemptAt: row['next_attempt_at'] == null
          ? null
          : DateTime.parse(row['next_attempt_at'] as String),
    );
  }

  static void _validateFeedWindowLimit(int limit) {
    if (limit <= 0) {
      throw ArgumentError.value(
        limit,
        'maxFeedWindowRevisionIds',
        'must be greater than zero',
      );
    }
  }

  static void _quarantineCorruptDatabase(String path) {
    if (path == ':memory:') return;
    final suffix = DateTime.now().toUtc().microsecondsSinceEpoch;
    for (final sidecar in const ['', '-wal', '-shm']) {
      final file = File('$path$sidecar');
      if (!file.existsSync()) continue;
      try {
        file.renameSync('$path.corrupt.$suffix$sidecar');
      } on FileSystemException {
        try {
          file.deleteSync();
        } on FileSystemException {
          // Let the subsequent open report the unrecoverable filesystem error.
        }
      }
    }
  }
}

String _randomUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
