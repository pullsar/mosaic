import 'package:event_delivery/event_delivery.dart';

final class AppEventResources {
  const AppEventResources({
    required this.outbox,
    required this.actorId,
    required this.close,
  });

  final EventOutbox outbox;
  final String actorId;
  final Future<void> Function() close;
}
