import 'package:event_delivery/event_delivery.dart';

import 'event_runtime_resources.dart';

Future<AppEventResources> openPlatformEventResources() async {
  final store = await IndexedDbEventStore.open();
  try {
    final actorAccess = await store.getOrCreateActorAccess();
    return AppEventResources(
      outbox: store,
      actorId: actorAccess.actorId,
      actorAccessToken: actorAccess.accessToken,
      close: store.close,
    );
  } on Object {
    await store.close();
    rethrow;
  }
}
