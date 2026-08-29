import 'package:event_delivery/event_delivery.dart';
import 'package:test/test.dart';

String _databaseName() => 'mosaic_actor_access_${secureUuidV4()}';

void main() {
  test(
    'actor access identity survives IndexedDB reopen as one stable pair',
    () async {
      final name = _databaseName();
      var store = await IndexedDbEventStore.open(databaseName: name);
      try {
        final first = await store.getOrCreateActorAccess();
        expect(first.actorId, isNotEmpty);
        expect(first.accessToken, hasLength(43));
        expect(
          RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(first.accessToken),
          isTrue,
        );
        await store.close();

        store = await IndexedDbEventStore.open(databaseName: name);
        final reopened = await store.getOrCreateActorAccess();
        expect(reopened.actorId, first.actorId);
        expect(reopened.accessToken, first.accessToken);
        expect(await store.getOrCreateActorId(), first.actorId);
      } finally {
        await store.close();
        await IndexedDbEventStore.deleteDatabase(name);
      }
    },
  );
}
