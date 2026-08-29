import 'dart:io';

import 'package:event_delivery/event_delivery.dart';
import 'package:local_state/local_state.dart';
import 'package:path_provider/path_provider.dart';

import 'event_runtime_resources.dart';

Future<AppEventResources> openPlatformEventResources() async {
  final directory = await getApplicationSupportDirectory();
  final databasePath =
      '${directory.path}${Platform.pathSeparator}mosaic_local_state.sqlite3';
  final store = MosaicLocalStore.open(databasePath);
  final outbox = SqliteEventOutbox(store);

  try {
    final actorId = store.getOrCreateActorId();
    var closed = false;
    return AppEventResources(
      outbox: outbox,
      actorId: actorId,
      close: () async {
        if (closed) return;
        closed = true;
        await outbox.close();
        store.close();
      },
    );
  } on Object {
    await outbox.close();
    store.close();
    rethrow;
  }
}
