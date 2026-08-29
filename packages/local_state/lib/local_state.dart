library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:sqlite3/sqlite3.dart';

final RegExp _actorAccessTokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

enum InterestKind { interest, learning }

final class LocalActorAccess {
  const LocalActorAccess({required this.actorId, required this.accessToken});

  final String actorId;
  final String accessToken;
}

enum OutboxPriority {
  analytics(0),
  normal(50),
  critical(100);

  const OutboxPriority(this.value);
  final int value;
}

final class FeedResumeState {
  const FeedResumeState({
    this.requestId,
    required this.cursor,
    this.visibleRevisionId,
    this.visiblePosition,
    required this.windowRevisionIds,
    required this.updatedAt,
  });

  final String? requestId;
  final String? cursor;
  final String? visibleRevisionId;
  final int? visiblePosition;
  final List<String> windowRevisionIds;
  final DateTime updatedAt;
}

final class RecentFeedCacheState {
  const RecentFeedCacheState({
    required this.requestId,
    required this.items,
    required this.updatedAt,
  });

  final String requestId;
  final List<Map<String, Object?>> items;
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

final class _CorruptLocalDatabaseException implements Exception {
  const _CorruptLocalDatabaseException();
}

typedef ActorIdFactory = String Function();
typedef ActorAccessTokenFactory = String Function();

final class MosaicLocalStore {
  MosaicLocalStore._(
    this._db, {
    required this.policy,
    required this.maxFeedWindowRevisionIds,
    required ActorIdFactory actorIdFactory,
    required ActorAccessTokenFactory actorAccessTokenFactory,
  }) : _actorIdFactory = actorIdFactory,
       _actorAccessTokenFactory = actorAccessTokenFactory;

  static const int schemaVersion = 2;
  static const int defaultMaxFeedWindowRevisionIds = 64;
  static const int defaultRecentFeedCacheMaxItems = 12;
  static const int defaultRecentFeedCacheMaxBytes = 256 * 1024;
  static const Duration defaultRecentFeedCacheMaxAge = Duration(days: 2);

  final Database _db;
  final OutboxPolicy policy;
  final int maxFeedWindowRevisionIds;
  final ActorIdFactory _actorIdFactory;
  final ActorAccessTokenFactory _actorAccessTokenFactory;

  static MosaicLocalStore open(
    String path, {
    OutboxPolicy policy = const OutboxPolicy(),
    int maxFeedWindowRevisionIds = defaultMaxFeedWindowRevisionIds,
    ActorIdFactory actorIdFactory = _randomUuidV4,
    ActorAccessTokenFactory actorAccessTokenFactory = _randomActorAccessToken,
  }) {
    _validateFeedWindowLimit(maxFeedWindowRevisionIds);
    final candidate = sqlite3.open(path);
    final store = MosaicLocalStore._(
      candidate,
      policy: policy,
      maxFeedWindowRevisionIds: maxFeedWindowRevisionIds,
      actorIdFactory: actorIdFactory,
      actorAccessTokenFactory: actorAccessTokenFactory,
    );

    try {
      store._verifyIntegrity();
    } on _CorruptLocalDatabaseException {
      candidate.close();
      return _recoverCorruptDatabase(
        path,
        policy: policy,
        maxFeedWindowRevisionIds: maxFeedWindowRevisionIds,
        actorIdFactory: actorIdFactory,
        actorAccessTokenFactory: actorAccessTokenFactory,
      );
    } on Object {
      candidate.close();
      rethrow;
    }

    try {
      store._migrate();
      return store;
    } on Object {
      candidate.close();
      rethrow;
    }
  }

  static MosaicLocalStore openInMemory({
    OutboxPolicy policy = const OutboxPolicy(),
    int maxFeedWindowRevisionIds = defaultMaxFeedWindowRevisionIds,
    ActorIdFactory actorIdFactory = _randomUuidV4,
    ActorAccessTokenFactory actorAccessTokenFactory = _randomActorAccessToken,
  }) {
    _validateFeedWindowLimit(maxFeedWindowRevisionIds);
    final store = MosaicLocalStore._(
      sqlite3.openInMemory(),
      policy: policy,
      maxFeedWindowRevisionIds: maxFeedWindowRevisionIds,
      actorIdFactory: actorIdFactory,
      actorAccessTokenFactory: actorAccessTokenFactory,
    );
    store._migrate();
    return store;
  }

  void close() => _db.close();

  int get userVersion {
    final rows = _db.select('pragma user_version');
    return rows.first.values.first as int;
  }

  String getOrCreateActorId() => getOrCreateActorAccess().actorId;

  LocalActorAccess getOrCreateActorAccess() {
    late LocalActorAccess result;
    _transaction(() {
      final existingActorId = _metadata('actor_id');
      final existingToken = _metadata('actor_access_token');
      if (existingActorId != null &&
          existingActorId.isNotEmpty &&
          existingToken != null &&
          _actorAccessTokenPattern.hasMatch(existingToken)) {
        result = LocalActorAccess(
          actorId: existingActorId,
          accessToken: existingToken,
        );
        return;
      }

      final actorId = _actorIdFactory().trim();
      final accessToken = _actorAccessTokenFactory().trim();
      if (actorId.isEmpty) {
        throw StateError('Actor ID factory returned an empty identifier.');
      }
      if (!_actorAccessTokenPattern.hasMatch(accessToken)) {
        throw StateError(
          'Actor access token factory returned an invalid token.',
        );
      }
      _setMetadata('actor_id', actorId);
      _setMetadata('actor_access_token', accessToken);
      result = LocalActorAccess(actorId: actorId, accessToken: accessToken);
    });
    return result;
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
    String? requestId,
    required String? cursor,
    String? visibleRevisionId,
    int? visiblePosition,
    required List<String> windowRevisionIds,
    DateTime? updatedAt,
  }) {
    if (visiblePosition != null && visiblePosition < 0) {
      throw ArgumentError.value(
        visiblePosition,
        'visiblePosition',
        'must be non-negative',
      );
    }
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
      insert into feed_resume (
        singleton, request_id, cursor, visible_revision_id, visible_position,
        window_json, updated_at
      ) values (1, ?, ?, ?, ?, ?, ?)
      on conflict(singleton) do update set
        request_id = excluded.request_id,
        cursor = excluded.cursor,
        visible_revision_id = excluded.visible_revision_id,
        visible_position = excluded.visible_position,
        window_json = excluded.window_json,
        updated_at = excluded.updated_at
      ''',
      [
        requestId,
        cursor,
        visibleRevisionId,
        visiblePosition,
        jsonEncode(boundedWindow),
        (updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
      ],
    );
  }

  FeedResumeState? loadFeedResume() {
    final rows = _db.select('''
      select request_id, cursor, visible_revision_id, visible_position,
             window_json, updated_at
        from feed_resume where singleton = 1
      ''');
    if (rows.isEmpty) return null;
    final row = rows.first;
    return FeedResumeState(
      requestId: row['request_id'] as String?,
      cursor: row['cursor'] as String?,
      visibleRevisionId: row['visible_revision_id'] as String?,
      visiblePosition: row['visible_position'] as int?,
      windowRevisionIds: (jsonDecode(row['window_json'] as String) as List)
          .cast<String>(),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  void saveRecentFeedCache({
    required String requestId,
    required List<Map<String, Object?>> items,
    DateTime? updatedAt,
  }) {
    final normalizedRequestId = requestId.trim();
    if (normalizedRequestId.isEmpty || normalizedRequestId.length > 200) {
      throw ArgumentError.value(
        requestId,
        'requestId',
        'must be 1 to 200 characters',
      );
    }

    final bounded = <Map<String, Object?>>[];
    for (final rawItem in items) {
      if (bounded.length >= defaultRecentFeedCacheMaxItems) break;
      final decoded = jsonDecode(jsonEncode(rawItem));
      if (decoded is! Map) {
        throw const FormatException(
          'Recent feed cache item must be an object.',
        );
      }
      final item = decoded.map((key, value) => MapEntry(key.toString(), value));
      final candidate = jsonEncode(<Object?>[...bounded, item]);
      if (utf8.encode(candidate).length > defaultRecentFeedCacheMaxBytes) break;
      bounded.add(item);
    }

    if (bounded.isEmpty) {
      clearRecentFeedCache();
      return;
    }
    final encoded = jsonEncode(bounded);
    _db.execute(
      '''
      insert into recent_feed_cache (
        singleton, request_id, items_json, byte_size, updated_at
      ) values (1, ?, ?, ?, ?)
      on conflict(singleton) do update set
        request_id = excluded.request_id,
        items_json = excluded.items_json,
        byte_size = excluded.byte_size,
        updated_at = excluded.updated_at
      ''',
      [
        normalizedRequestId,
        encoded,
        utf8.encode(encoded).length,
        (updatedAt ?? DateTime.now().toUtc()).toIso8601String(),
      ],
    );
  }

  RecentFeedCacheState? loadRecentFeedCache({DateTime? now}) {
    final rows = _db.select('''
      select request_id, items_json, updated_at
        from recent_feed_cache where singleton = 1
      ''');
    if (rows.isEmpty) return null;
    final row = rows.first;
    try {
      final updatedAt = DateTime.parse(row['updated_at'] as String).toUtc();
      final instant = (now ?? DateTime.now()).toUtc();
      if (instant.difference(updatedAt) > defaultRecentFeedCacheMaxAge) {
        clearRecentFeedCache();
        return null;
      }
      final decoded = jsonDecode(row['items_json'] as String);
      if (decoded is! List || decoded.length > defaultRecentFeedCacheMaxItems) {
        throw const FormatException('Recent feed cache payload is invalid.');
      }
      final items = decoded
          .map((value) {
            if (value is! Map) {
              throw const FormatException('Recent feed cache item is invalid.');
            }
            return value.map((key, nested) => MapEntry(key.toString(), nested));
          })
          .toList(growable: false);
      return RecentFeedCacheState(
        requestId: row['request_id'] as String,
        items: items,
        updatedAt: updatedAt,
      );
    } on Object {
      clearRecentFeedCache();
      return null;
    }
  }

  void clearRecentFeedCache() {
    _db.execute('delete from recent_feed_cache where singleton = 1');
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
        order by
          case when priority < ? then 0 else 1 end asc,
          priority asc,
          created_at asc
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
    late ResultSet result;
    try {
      result = _db.select('pragma quick_check(1)');
    } on SqliteException catch (error) {
      if (error.resultCode == SqlError.SQLITE_CORRUPT ||
          error.resultCode == SqlError.SQLITE_NOTADB) {
        throw const _CorruptLocalDatabaseException();
      }
      rethrow;
    }
    if (result.isEmpty || result.first.values.first != 'ok') {
      throw const _CorruptLocalDatabaseException();
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
            request_id text,
            cursor text,
            visible_revision_id text,
            visible_position integer,
            window_json text not null,
            updated_at text not null
          )
        ''');
        _db.execute('''
          create table recent_feed_cache (
            singleton integer primary key check(singleton = 1),
            request_id text not null,
            items_json text not null,
            byte_size integer not null,
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
        _db.execute('pragma user_version = $schemaVersion');
      });
      return;
    }
    if (version == 1) {
      _transaction(() {
        _db.execute('alter table feed_resume add column request_id text');
        _db.execute(
          'alter table feed_resume add column visible_revision_id text',
        );
        _db.execute(
          'alter table feed_resume add column visible_position integer',
        );
        _db.execute('''
          create table recent_feed_cache (
            singleton integer primary key check(singleton = 1),
            request_id text not null,
            items_json text not null,
            byte_size integer not null,
            updated_at text not null
          )
        ''');
        _db.execute('pragma user_version = $schemaVersion');
      });
    }
  }

  void _transaction(void Function() body) {
    _db.execute('begin immediate');
    try {
      body();
      _db.execute('commit');
    } catch (_) {
      _db.execute('rollback');
      rethrow;
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

  static void _validateFeedWindowLimit(int value) {
    if (value <= 0) {
      throw ArgumentError.value(
        value,
        'maxFeedWindowRevisionIds',
        'must be greater than zero',
      );
    }
  }

  static MosaicLocalStore _recoverCorruptDatabase(
    String path, {
    required OutboxPolicy policy,
    required int maxFeedWindowRevisionIds,
    required ActorIdFactory actorIdFactory,
    required ActorAccessTokenFactory actorAccessTokenFactory,
  }) {
    _quarantineCorruptDatabase(path);
    final db = sqlite3.open(path);
    final store = MosaicLocalStore._(
      db,
      policy: policy,
      maxFeedWindowRevisionIds: maxFeedWindowRevisionIds,
      actorIdFactory: actorIdFactory,
      actorAccessTokenFactory: actorAccessTokenFactory,
    );
    try {
      store._migrate();
      return store;
    } on Object {
      db.close();
      rethrow;
    }
  }

  static void _quarantineCorruptDatabase(String path) {
    final file = File(path);
    if (!file.existsSync()) return;
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    file.renameSync('$path.corrupt.$stamp');
    for (final suffix in ['-wal', '-shm']) {
      final sidecar = File('$path$suffix');
      if (sidecar.existsSync()) {
        sidecar.renameSync('$path.corrupt.$stamp$suffix');
      }
    }
  }
}

PendingEvent _pendingEventFromRow(Row row) {
  final priorityValue = row['priority'] as int;
  final priority = OutboxPriority.values.firstWhere(
    (candidate) => candidate.value == priorityValue,
    orElse: () => OutboxPriority.analytics,
  );
  return PendingEvent(
    eventId: row['event_id'] as String,
    event: (jsonDecode(row['event_json'] as String) as Map)
        .cast<String, Object?>(),
    priority: priority,
    attemptCount: row['attempt_count'] as int,
    createdAt: DateTime.parse(row['created_at'] as String),
    nextAttemptAt: row['next_attempt_at'] == null
        ? null
        : DateTime.parse(row['next_attempt_at'] as String),
  );
}

String _randomUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String pair(int index) => bytes[index].toRadixString(16).padLeft(2, '0');
  return '${pair(0)}${pair(1)}${pair(2)}${pair(3)}-'
      '${pair(4)}${pair(5)}-'
      '${pair(6)}${pair(7)}-'
      '${pair(8)}${pair(9)}-'
      '${pair(10)}${pair(11)}${pair(12)}${pair(13)}${pair(14)}${pair(15)}';
}

String _randomActorAccessToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}
