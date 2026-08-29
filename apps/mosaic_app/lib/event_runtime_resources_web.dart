import 'package:event_delivery/event_delivery.dart';

import 'event_runtime_resources.dart';

Future<AppEventResources> openPlatformEventResources() async {
  final store = await IndexedDbEventStore.open();
  try {
    final actorId = await store.getOrCreateActorId();
    return AppEventResources(
      outbox: store,
      actorId: actorId,
      close: store.close,
    );
  } on Object {
    await store.close();
    rethrow;
  }
}
