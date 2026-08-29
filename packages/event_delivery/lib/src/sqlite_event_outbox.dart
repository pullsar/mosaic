import 'package:analytics_contract/analytics_contract.dart';
import 'package:local_state/local_state.dart';
import 'package:platform_contracts/platform_contracts.dart';

import 'event_delivery_core.dart';

/// Thin asynchronous adapter over Mosaic's existing native SQLite outbox.
///
/// The store remains caller-owned by default so preferences/drafts/assets can
/// share the same database connection later without a second SQLite database.
final class SqliteEventOutbox implements EventOutbox {
  SqliteEventOutbox(this.store, {this.closeStoreOnClose = false});

  final MosaicLocalStore store;
  final bool closeStoreOnClose;
  var _closed = false;

  @override
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  }) async {
    _ensureOpen();
    store.enqueueEvent(
      event,
      priority: _toLocalPriority(priority),
      createdAt: createdAt,
    );
  }

  @override
  Future<List<QueuedEvent>> due({DateTime? now, int limit = 50}) async {
    _ensureOpen();
    return store
        .dueEvents(now: now, limit: limit)
        .map(
          (pending) => QueuedEvent(
            envelope: MosaicEventEnvelope.fromJson(pending.event),
            priority: _fromLocalPriority(pending.priority),
            attemptCount: pending.attemptCount,
            createdAt: pending.createdAt,
            nextAttemptAt: pending.nextAttemptAt,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> markDelivered(String eventId) async {
    _ensureOpen();
    store.markEventSent(eventId);
  }

  @override
  Future<void> markRetryableFailure(String eventId, {DateTime? now}) async {
    _ensureOpen();
    store.markEventFailed(eventId, now: now);
  }

  @override
  Future<void> discard(String eventId) async {
    _ensureOpen();
    store.markEventSent(eventId);
  }

  @override
  Future<void> clear() async {
    _ensureOpen();
    final futureCeiling = DateTime.utc(9999, 12, 31, 23, 59, 59);
    while (true) {
      final batch = store.dueEvents(now: futureCeiling, limit: 100);
      if (batch.isEmpty) return;
      for (final event in batch) {
        store.markEventSent(event.eventId);
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (closeStoreOnClose) store.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('SQLite event outbox is closed.');
  }
}

/// Actor identity adapter sharing the same Mosaic SQLite connection as the
/// native event outbox and all other durable local state.
final class SqliteActorIdentityStore implements ActorIdentityStore {
  SqliteActorIdentityStore(this.store);

  final MosaicLocalStore store;

  @override
  Future<String> getOrCreateActorId() async => store.getOrCreateActorId();

  @override
  Future<void> bindActorToUser(String actorId, String userId) async {
    final currentActorId = store.getOrCreateActorId();
    if (currentActorId != actorId) {
      throw StateError('Cannot bind a different actor identity.');
    }
    // Server-side actor/user binding is authoritative. The native store only
    // persists the anonymous actor identity used by durable queued events.
  }
}

OutboxPriority _toLocalPriority(EventPriority priority) => switch (priority) {
  EventPriority.analytics => OutboxPriority.analytics,
  EventPriority.normal => OutboxPriority.normal,
  EventPriority.critical => OutboxPriority.critical,
};

EventPriority _fromLocalPriority(OutboxPriority priority) => switch (priority) {
  OutboxPriority.analytics => EventPriority.analytics,
  OutboxPriority.normal => EventPriority.normal,
  OutboxPriority.critical => EventPriority.critical,
};
