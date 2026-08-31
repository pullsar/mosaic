import 'dart:async';
import 'dart:js_interop';

import 'package:event_delivery/event_delivery.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

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

  test(
    'legacy rotation atomically drops stale local account binding',
    () async {
      final name = _databaseName();
      var store = await IndexedDbEventStore.open(databaseName: name);
      try {
        final first = await store.getOrCreateActorAccess();
        await store.bindActorToUser(first.actorId, 'user_old');
        expect(await store.boundUserId(), 'user_old');
        await store.close();

        await _deleteMetadata(name, 'actor_access_token');

        store = await IndexedDbEventStore.open(databaseName: name);
        final rotated = await store.getOrCreateActorAccess();
        expect(rotated.actorId, isNot(first.actorId));
        expect(rotated.accessToken, hasLength(43));
        expect(await store.boundUserId(), isNull);
      } finally {
        await store.close();
        await IndexedDbEventStore.deleteDatabase(name);
      }
    },
  );
}

Future<void> _deleteMetadata(String databaseName, String key) async {
  final open = web.window.indexedDB.open(databaseName, 1);
  final opened = Completer<web.IDBDatabase>();
  open.onsuccess = ((web.Event _) {
    if (!opened.isCompleted) {
      opened.complete(open.result as web.IDBDatabase);
    }
  }).toJS;
  open.onerror = ((web.Event _) {
    if (!opened.isCompleted) {
      opened.completeError(StateError('Could not open test IndexedDB.'));
    }
  }).toJS;

  final database = await opened.future;
  try {
    final transaction = database.transaction('metadata'.toJS, 'readwrite');
    final completed = Completer<void>();
    transaction.oncomplete = ((web.Event _) {
      if (!completed.isCompleted) completed.complete();
    }).toJS;
    transaction.onerror = ((web.Event _) {
      if (!completed.isCompleted) {
        completed.completeError(StateError('Test metadata mutation failed.'));
      }
    }).toJS;
    transaction.onabort = ((web.Event _) {
      if (!completed.isCompleted) {
        completed.completeError(StateError('Test metadata mutation aborted.'));
      }
    }).toJS;
    transaction.objectStore('metadata').delete(key.toJS);
    await completed.future;
  } finally {
    database.close();
  }
}
