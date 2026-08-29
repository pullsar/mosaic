import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';

final class AppEventResources {
  const AppEventResources({
    required this.outbox,
    required this.actorId,
    required this.close,
  });

  factory AppEventResources.disabled() => AppEventResources(
    outbox: _DiscardingEventOutbox(),
    actorId: secureUuidV4(),
    close: _noopClose,
  );

  final EventOutbox outbox;
  final String actorId;
  final Future<void> Function() close;
}

Future<void> _noopClose() async {}

final class _DiscardingEventOutbox implements EventOutbox {
  @override
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  }) async {}

  @override
  Future<List<QueuedEvent>> due({DateTime? now, int limit = 50}) async =>
      const [];

  @override
  Future<void> markDelivered(String eventId) async {}

  @override
  Future<void> markRetryableFailure(String eventId, {DateTime? now}) async {}

  @override
  Future<void> discard(String eventId) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<void> close() async {}
}
