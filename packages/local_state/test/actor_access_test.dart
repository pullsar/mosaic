import 'dart:io';

import 'package:local_state/local_state.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('actor access identity survives SQLite reopen as one stable pair', () {
    final temp = Directory.systemTemp.createTempSync('mosaic-actor-access-');
    final path = '${temp.path}/mosaic.db';
    try {
      var store = MosaicLocalStore.open(
        path,
        actorIdFactory: () => 'actor_fixed',
        actorAccessTokenFactory: () => 'A' * 43,
      );
      final first = store.getOrCreateActorAccess();
      expect(first.actorId, 'actor_fixed');
      expect(first.accessToken, 'A' * 43);
      store.close();

      store = MosaicLocalStore.open(
        path,
        actorIdFactory: () => 'actor_should_not_replace',
        actorAccessTokenFactory: () => 'B' * 43,
      );
      final reopened = store.getOrCreateActorAccess();
      expect(reopened.actorId, first.actorId);
      expect(reopened.accessToken, first.accessToken);
      expect(store.getOrCreateActorId(), first.actorId);
      store.close();
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test(
    'pre-credential actor rotates actor and secret together instead of being claimed',
    () {
      final temp = Directory.systemTemp.createTempSync('mosaic-legacy-actor-');
      final path = '${temp.path}/mosaic.db';
      try {
        var store = MosaicLocalStore.open(
          path,
          actorIdFactory: () => 'legacy_actor',
          actorAccessTokenFactory: () => 'A' * 43,
        );
        expect(store.getOrCreateActorAccess().actorId, 'legacy_actor');
        store.close();

        final database = sqlite3.open(path);
        database.execute(
          "delete from metadata where key = 'actor_access_token'",
        );
        database.close();

        store = MosaicLocalStore.open(
          path,
          actorIdFactory: () => 'rotated_actor',
          actorAccessTokenFactory: () => 'B' * 43,
        );
        final rotated = store.getOrCreateActorAccess();
        expect(rotated.actorId, 'rotated_actor');
        expect(rotated.accessToken, 'B' * 43);
        expect(rotated.actorId, isNot('legacy_actor'));
        store.close();
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
  );

  test(
    'invalid actor access token factory fails without persisting a partial identity',
    () {
      final store = MosaicLocalStore.openInMemory(
        actorIdFactory: () => 'actor_partial',
        actorAccessTokenFactory: () => 'weak',
      );
      expect(store.getOrCreateActorAccess, throwsStateError);
      expect(store.getOrCreateActorAccess, throwsStateError);
      store.close();
    },
  );
}
