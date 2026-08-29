import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:web/web.dart' as web;

import 'event_delivery_core.dart';

const _eventsStore = 'events';
const _metadataStore = 'metadata';
const _actorIdKey = 'actor_id';
const _actorAccessTokenKey = 'actor_access_token';
const _boundUserIdKey = 'bound_user_id';
const _databaseVersion = 1;

/// Browser-persistent event outbox and actor identity backed by IndexedDB.
///
/// Values are stored as canonical JSON strings rather than arbitrary JS
/// objects. This keeps persistence deterministic across JS/Wasm compilers and
/// makes corrupt records fail closed through [MosaicEventEnvelope.fromJson].
final class IndexedDbEventStore implements EventOutbox, ActorIdentityStore {
  IndexedDbEventStore._(
    this._database,
    this.databaseName, {
    required this.policy,
  });

  final web.IDBDatabase _database;
  final String databaseName;
  final EventOutboxPolicy policy;
  Future<void> _writeTail = Future<void>.value();
  var _closed = false;

  static Future<IndexedDbEventStore> open({
    String databaseName = 'mosaic_event_runtime',
    EventOutboxPolicy policy = const EventOutboxPolicy(),
  }) async {
    final normalizedName = databaseName.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(
        databaseName,
        'databaseName',
        'must not be empty',
      );
    }
    _validatePolicy(policy);
    final factory = web.window.indexedDB;
    final request = factory.open(normalizedName, _databaseVersion);
    final completer = Completer<web.IDBDatabase>();

    request.onupgradeneeded = ((web.Event _) {
      try {
        final database = request.result as web.IDBDatabase;
        if (!database.objectStoreNames.contains(_eventsStore)) {
          database.createObjectStore(_eventsStore);
        }
        if (!database.objectStoreNames.contains(_metadataStore)) {
          database.createObjectStore(_metadataStore);
        }
      } on Object catch (error, stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      if (completer.isCompleted) return;
      completer.complete(request.result as web.IDBDatabase);
    }).toJS;
    request.onerror = ((web.Event _) {
      if (completer.isCompleted) return;
      completer.completeError(_requestFailure('open', request.error));
    }).toJS;
    request.onblocked = ((web.Event _) {
      if (completer.isCompleted) return;
      completer.completeError(
        StateError('IndexedDB open was blocked by another connection.'),
      );
    }).toJS;

    final database = await completer.future;
    database.onversionchange = ((web.Event _) {
      database.close();
    }).toJS;
    return IndexedDbEventStore._(database, normalizedName, policy: policy);
  }

  static Future<void> deleteDatabase(String databaseName) async {
    final normalizedName = databaseName.trim();
    if (normalizedName.isEmpty) return;
    final request = web.window.indexedDB.deleteDatabase(normalizedName);
    await _request<void>(request, (_) {});
  }

  @override
  Future<String> getOrCreateActorId() async =>
      (await getOrCreateActorAccess()).actorId;

  Future<ActorAccessIdentity> getOrCreateActorAccess() =>
      _serializeWrite(() async {
        _ensureOpen();
        final existingActorId = await _readMetadata(_actorIdKey);
        final existingToken = await _readMetadata(_actorAccessTokenKey);
        if (existingActorId != null &&
            existingActorId.isNotEmpty &&
            _isValidActorAccessToken(existingToken)) {
          return ActorAccessIdentity(
            actorId: existingActorId,
            accessToken: existingToken!,
          );
        }

        final actorAccess = ActorAccessIdentity(
          actorId: secureUuidV4(),
          accessToken: secureActorAccessToken(),
        );
        await _writeActorAccess(actorAccess);
        return actorAccess;
      });

  @override
  Future<void> bindActorToUser(String actorId, String userId) =>
      _serializeWrite(() async {
        _ensureOpen();
        final currentActor = await _readMetadata(_actorIdKey);
        if (currentActor == null || currentActor != actorId) {
          throw StateError('Cannot bind a different actor identity.');
        }
        final normalizedUser = userId.trim();
        if (normalizedUser.isEmpty) {
          throw ArgumentError.value(userId, 'userId', 'must not be empty');
        }
        await _writeMetadata(_boundUserIdKey, normalizedUser);
      });

  Future<String?> boundUserId() => _readMetadata(_boundUserIdKey);

  @override
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  }) => _serializeWrite(() async {
    _ensureOpen();
    final existing = await _readEventRecord(event.eventId);
    if (existing != null) return;

    final encodedEvent = jsonEncode(event.toJson());
    final record = _WebEventRecord(
      event: event,
      encodedEventBytes: utf8.encode(encodedEvent).length,
      priority: priority,
      attemptCount: 0,
      createdAt: (createdAt ?? DateTime.now()).toUtc(),
    );
    await _writeEventRecord(record);
    await _pruneUnlocked(now: record.createdAt);
  });

  @override
  Future<List<QueuedEvent>> due({DateTime? now, int limit = 50}) async {
    _ensureOpen();
    if (limit <= 0) return const [];
    final instant = (now ?? DateTime.now()).toUtc();
    final records = await _readAllEventRecords();
    records.removeWhere(
      (record) =>
          record.nextAttemptAt != null &&
          record.nextAttemptAt!.isAfter(instant),
    );
    records.sort(_compareQueueOrder);
    return records
        .take(limit)
        .map((record) => record.toQueuedEvent())
        .toList(growable: false);
  }

  @override
  Future<void> markDelivered(String eventId) =>
      _serializeWrite(() => _deleteEvent(eventId));

  @override
  Future<void> discard(String eventId) =>
      _serializeWrite(() => _deleteEvent(eventId));

  @override
  Future<void> markRetryableFailure(String eventId, {DateTime? now}) =>
      _serializeWrite(() async {
        _ensureOpen();
        final record = await _readEventRecord(eventId);
        if (record == null) return;
        final attempts = record.attemptCount + 1;
        final exponentialSeconds = 1 << (attempts > 20 ? 20 : attempts);
        final maxSeconds = policy.maxBackoff.inSeconds;
        final seconds = exponentialSeconds < maxSeconds
            ? exponentialSeconds
            : maxSeconds;
        final retryAt = (now ?? DateTime.now()).toUtc().add(
          Duration(seconds: seconds),
        );
        await _writeEventRecord(
          record.copyWith(attemptCount: attempts, nextAttemptAt: retryAt),
        );
      });

  @override
  Future<void> clear() => _serializeWrite(() async {
    _ensureOpen();
    final transaction = _database.transaction(_eventsStore.toJS, 'readwrite');
    final completion = _transactionCompletion(transaction);
    transaction.objectStore(_eventsStore).clear();
    await completion;
  });

  @override
  Future<void> close() async {
    if (_closed) return;
    await _writeTail;
    _closed = true;
    _database.close();
  }

  Future<T> _serializeWrite<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _writeTail = _writeTail.then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<String?> _readMetadata(String key) async {
    _ensureOpen();
    final transaction = _database.transaction(_metadataStore.toJS, 'readonly');
    final request = transaction.objectStore(_metadataStore).get(key.toJS);
    return _request<String?>(request, (result) {
      final value = result?.dartify();
      return value is String ? value : null;
    });
  }

  Future<void> _writeMetadata(String key, String value) async {
    final transaction = _database.transaction(_metadataStore.toJS, 'readwrite');
    final completion = _transactionCompletion(transaction);
    transaction.objectStore(_metadataStore).put(value.toJS, key.toJS);
    await completion;
  }

  Future<void> _writeActorAccess(ActorAccessIdentity actorAccess) async {
    final transaction = _database.transaction(_metadataStore.toJS, 'readwrite');
    final completion = _transactionCompletion(transaction);
    final metadata = transaction.objectStore(_metadataStore);
    metadata.put(actorAccess.actorId.toJS, _actorIdKey.toJS);
    metadata.put(actorAccess.accessToken.toJS, _actorAccessTokenKey.toJS);
    // A rotated anonymous actor must never inherit a local account binding from
    // the previous actor. Keep identity replacement and binding invalidation in
    // one transaction so a crash cannot expose a mixed identity state.
    metadata.delete(_boundUserIdKey.toJS);
    await completion;
  }

  Future<_WebEventRecord?> _readEventRecord(String eventId) async {
    _ensureOpen();
    final transaction = _database.transaction(_eventsStore.toJS, 'readonly');
    final request = transaction.objectStore(_eventsStore).get(eventId.toJS);
    return _request<_WebEventRecord?>(request, (result) {
      final value = result?.dartify();
      if (value == null) return null;
      if (value is! String) {
        throw const FormatException('IndexedDB event record must be a string.');
      }
      return _WebEventRecord.decode(value);
    });
  }

  Future<List<_WebEventRecord>> _readAllEventRecords() async {
    _ensureOpen();
    final transaction = _database.transaction(_eventsStore.toJS, 'readonly');
    final request = transaction.objectStore(_eventsStore).getAll();
    return _request<List<_WebEventRecord>>(request, (result) {
      final value = result?.dartify();
      if (value is! List) return <_WebEventRecord>[];
      return value
          .map((entry) {
            if (entry is! String) {
              throw const FormatException(
                'IndexedDB event record must be a string.',
              );
            }
            return _WebEventRecord.decode(entry);
          })
          .toList(growable: true);
    });
  }

  Future<void> _writeEventRecord(_WebEventRecord record) async {
    final transaction = _database.transaction(_eventsStore.toJS, 'readwrite');
    final completion = _transactionCompletion(transaction);
    transaction
        .objectStore(_eventsStore)
        .put(record.encode().toJS, record.event.eventId.toJS);
    await completion;
  }

  Future<void> _deleteEvent(String eventId) async {
    _ensureOpen();
    final transaction = _database.transaction(_eventsStore.toJS, 'readwrite');
    final completion = _transactionCompletion(transaction);
    transaction.objectStore(_eventsStore).delete(eventId.toJS);
    await completion;
  }

  Future<void> _pruneUnlocked({required DateTime now}) async {
    var records = await _readAllEventRecords();
    final cutoff = now.subtract(policy.maxAge);
    for (final record in records.where(
      (record) =>
          record.priority != EventPriority.critical &&
          record.createdAt.isBefore(cutoff),
    )) {
      await _deleteEvent(record.event.eventId);
    }

    records = await _readAllEventRecords();
    while (_overCapacity(records)) {
      final candidates = records.toList(growable: false)
        ..sort(_compareEvictionOrder);
      if (candidates.isEmpty) return;
      final victim = candidates.first;
      await _deleteEvent(victim.event.eventId);
      records.removeWhere(
        (record) => record.event.eventId == victim.event.eventId,
      );
    }
  }

  bool _overCapacity(List<_WebEventRecord> records) {
    final bytes = records.fold<int>(
      0,
      (total, record) => total + record.encodedEventBytes,
    );
    return records.length > policy.maxCount || bytes > policy.maxBytes;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('IndexedDB event store is closed.');
  }
}

final class _WebEventRecord {
  const _WebEventRecord({
    required this.event,
    required this.encodedEventBytes,
    required this.priority,
    required this.attemptCount,
    required this.createdAt,
    this.nextAttemptAt,
  });

  final MosaicEventEnvelope event;
  final int encodedEventBytes;
  final EventPriority priority;
  final int attemptCount;
  final DateTime createdAt;
  final DateTime? nextAttemptAt;

  QueuedEvent toQueuedEvent() => QueuedEvent(
    envelope: event,
    priority: priority,
    attemptCount: attemptCount,
    createdAt: createdAt,
    nextAttemptAt: nextAttemptAt,
  );

  _WebEventRecord copyWith({int? attemptCount, DateTime? nextAttemptAt}) =>
      _WebEventRecord(
        event: event,
        encodedEventBytes: encodedEventBytes,
        priority: priority,
        attemptCount: attemptCount ?? this.attemptCount,
        createdAt: createdAt,
        nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      );

  String encode() => jsonEncode({
    'event': event.toJson(),
    'encodedEventBytes': encodedEventBytes,
    'priority': priority.name,
    'attemptCount': attemptCount,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (nextAttemptAt != null)
      'nextAttemptAt': nextAttemptAt!.toUtc().toIso8601String(),
  });

  factory _WebEventRecord.decode(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map) {
      throw const FormatException('IndexedDB event record must be an object.');
    }
    final eventRaw = value['event'];
    if (eventRaw is! Map) {
      throw const FormatException('IndexedDB event payload is missing.');
    }
    final eventMap = <String, Object?>{};
    for (final entry in eventRaw.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const FormatException('IndexedDB event keys must be strings.');
      }
      eventMap[key] = entry.value;
    }
    final bytes = value['encodedEventBytes'];
    final attempts = value['attemptCount'];
    final priorityName = value['priority'];
    final createdAtRaw = value['createdAt'];
    final nextAttemptAtRaw = value['nextAttemptAt'];
    if (bytes is! int || bytes < 0 || attempts is! int || attempts < 0) {
      throw const FormatException('IndexedDB event counters are invalid.');
    }
    if (priorityName is! String || createdAtRaw is! String) {
      throw const FormatException('IndexedDB event metadata is invalid.');
    }
    final createdAt = DateTime.tryParse(createdAtRaw);
    final nextAttemptAt = nextAttemptAtRaw == null
        ? null
        : nextAttemptAtRaw is String
        ? DateTime.tryParse(nextAttemptAtRaw)
        : null;
    if (createdAt == null ||
        (nextAttemptAtRaw != null && nextAttemptAt == null)) {
      throw const FormatException('IndexedDB event timestamps are invalid.');
    }
    final priority = EventPriority.values.where(
      (candidate) => candidate.name == priorityName,
    );
    if (priority.isEmpty) {
      throw const FormatException('IndexedDB event priority is invalid.');
    }
    return _WebEventRecord(
      event: MosaicEventEnvelope.fromJson(eventMap),
      encodedEventBytes: bytes,
      priority: priority.single,
      attemptCount: attempts,
      createdAt: createdAt.toUtc(),
      nextAttemptAt: nextAttemptAt?.toUtc(),
    );
  }
}

int _compareQueueOrder(_WebEventRecord left, _WebEventRecord right) {
  final priority = right.priority.value.compareTo(left.priority.value);
  if (priority != 0) return priority;
  return left.createdAt.compareTo(right.createdAt);
}

int _compareEvictionOrder(_WebEventRecord left, _WebEventRecord right) {
  final priority = left.priority.value.compareTo(right.priority.value);
  if (priority != 0) return priority;
  return left.createdAt.compareTo(right.createdAt);
}

Future<T> _request<T>(
  web.IDBRequest request,
  T Function(JSAny? result) decode,
) {
  final completer = Completer<T>();
  request.onsuccess = ((web.Event _) {
    if (completer.isCompleted) return;
    try {
      completer.complete(decode(request.result));
    } on Object catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
  }).toJS;
  request.onerror = ((web.Event _) {
    if (completer.isCompleted) return;
    completer.completeError(_requestFailure('request', request.error));
  }).toJS;
  return completer.future;
}

Future<void> _transactionCompletion(web.IDBTransaction transaction) {
  final completer = Completer<void>();
  transaction.oncomplete = ((web.Event _) {
    if (!completer.isCompleted) completer.complete();
  }).toJS;
  transaction.onerror = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        _requestFailure('transaction', transaction.error),
      );
    }
  }).toJS;
  transaction.onabort = ((web.Event _) {
    if (!completer.isCompleted) {
      completer.completeError(
        _requestFailure('transaction abort', transaction.error),
      );
    }
  }).toJS;
  return completer.future;
}

StateError _requestFailure(String operation, web.DOMException? error) {
  final name = error?.name ?? 'unknown';
  return StateError('IndexedDB $operation failed ($name).');
}

void _validatePolicy(EventOutboxPolicy policy) {
  if (policy.maxCount <= 0) {
    throw ArgumentError.value(
      policy.maxCount,
      'policy.maxCount',
      'must be positive',
    );
  }
  if (policy.maxBytes <= 0) {
    throw ArgumentError.value(
      policy.maxBytes,
      'policy.maxBytes',
      'must be positive',
    );
  }
  if (policy.maxAge.isNegative) {
    throw ArgumentError.value(
      policy.maxAge,
      'policy.maxAge',
      'must not be negative',
    );
  }
  if (policy.maxBackoff.isNegative) {
    throw ArgumentError.value(
      policy.maxBackoff,
      'policy.maxBackoff',
      'must not be negative',
    );
  }
}

bool _isValidActorAccessToken(String? value) =>
    value != null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);
