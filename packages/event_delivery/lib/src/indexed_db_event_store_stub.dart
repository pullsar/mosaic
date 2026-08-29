import 'package:analytics_contract/analytics_contract.dart';
import 'package:platform_contracts/platform_contracts.dart';

import 'event_delivery_core.dart';

/// Non-web type mirror for [IndexedDbEventStore].
///
/// Keeping the complete public surface here lets whole-workspace analysis type
/// check web-only consumers without making native builds import browser APIs.
/// Every operation still fails explicitly if invoked on a non-web runtime.
final class IndexedDbEventStore implements EventOutbox, ActorIdentityStore {
  IndexedDbEventStore._({required this.databaseName, required this.policy});

  final String databaseName;
  final EventOutboxPolicy policy;

  static Future<IndexedDbEventStore> open({
    String databaseName = 'mosaic_event_runtime',
    EventOutboxPolicy policy = const EventOutboxPolicy(),
  }) => _unsupported();

  static Future<void> deleteDatabase(String databaseName) => _unsupported();

  @override
  Future<String> getOrCreateActorId() => _unsupported();

  Future<ActorAccessIdentity> getOrCreateActorAccess() => _unsupported();

  @override
  Future<void> bindActorToUser(String actorId, String userId) => _unsupported();

  Future<String?> boundUserId() => _unsupported();

  Future<String?> readConsumerMetadata(String key) => _unsupported();

  Future<void> writeConsumerMetadata(String key, String value) => _unsupported();

  Future<void> deleteConsumerMetadata(String key) => _unsupported();

  @override
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  }) => _unsupported();

  @override
  Future<List<QueuedEvent>> due({DateTime? now, int limit = 50}) =>
      _unsupported();

  @override
  Future<void> markDelivered(String eventId) => _unsupported();

  @override
  Future<void> markRetryableFailure(String eventId, {DateTime? now}) =>
      _unsupported();

  @override
  Future<void> discard(String eventId) => _unsupported();

  @override
  Future<void> clear() => _unsupported();

  @override
  Future<void> close() => _unsupported();
}

Future<T> _unsupported<T>() => Future<T>.error(
  UnsupportedError('IndexedDB event storage is available only on web.'),
);
