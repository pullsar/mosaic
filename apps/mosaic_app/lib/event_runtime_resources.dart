import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';

final class AppEventResources {
  const AppEventResources({
    required this.outbox,
    required this.actorId,
    required this.actorAccessToken,
    required this.close,
  });

  factory AppEventResources.disabled() {
    final actorAccess = ActorAccessIdentity(
      actorId: secureUuidV4(),
      accessToken: secureActorAccessToken(),
    );
    return AppEventResources(
      outbox: _DiscardingEventOutbox(),
      actorId: actorAccess.actorId,
      actorAccessToken: actorAccess.accessToken,
      close: _noopClose,
    );
  }

  final EventOutbox outbox;
  final String actorId;
  final String actorAccessToken;
  final Future<void> Function() close;

  ActorAccessIdentity get actorAccess =>
      ActorAccessIdentity(actorId: actorId, accessToken: actorAccessToken);
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
