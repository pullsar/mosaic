@TestOn('browser')
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/consumer_local_state_web.dart';
import 'package:mosaic_app/guest_engagement.dart';

String _databaseName() => 'mosaic_consumer_actions_${secureUuidV4()}';

String _playActionMetadataKey(String playId) =>
    'play_action.v1.${sha256.convert(utf8.encode(playId.trim()))}';

void main() {
  test('guest engagement survives IndexedDB reopen and cleans corruption', () async {
    final name = _databaseName();
    var store = await IndexedDbEventStore.open(databaseName: name);
    try {
      var state = IndexedDbConsumerLocalState(store);
      final dismissedAt = DateTime.utc(2026, 8, 31, 12);
      await state.writeGuestEngagement(
        GuestEngagementState(
          seenIdentities: List<String>.generate(
            5,
            (index) => 'request\u0000rev_$index',
          ),
          dismissedAt: dismissedAt,
        ),
      );
      await store.close();

      store = await IndexedDbEventStore.open(databaseName: name);
      state = IndexedDbConsumerLocalState(store);
      final restored = await state.readGuestEngagement();
      expect(restored?.seenIdentities, hasLength(5));
      expect(restored?.dismissedAt, dismissedAt);

      await store.writeConsumerMetadata('guest_engagement.v1', '{broken');
      expect(await state.readGuestEngagement(), isNull);
      expect(
        await store.readConsumerMetadata('guest_engagement.v1'),
        isNull,
      );
    } finally {
      await store.close();
      await IndexedDbEventStore.deleteDatabase(name);
    }
  });

  test('web action state and muted topics survive IndexedDB reopen', () async {
    final name = _databaseName();
    var store = await IndexedDbEventStore.open(databaseName: name);
    try {
      var state = IndexedDbConsumerLocalState(store);
      final savedAt = DateTime.utc(2026, 8, 30, 18, 30);
      await state.writePlayActionState(
        ConsumerPlayActionState(
          playId: 'play_saved',
          savedRevisionId: 'revision_saved',
          saved: true,
          moreLikeThis: true,
          notInterested: false,
          updatedAt: savedAt,
        ),
      );
      await state.writeMutedTopicIds(const <String>[
        'history',
        'science',
        'history',
      ]);
      await store.close();

      store = await IndexedDbEventStore.open(databaseName: name);
      state = IndexedDbConsumerLocalState(store);
      final reopened = await state.readPlayActionState('play_saved');
      expect(reopened, isNotNull);
      expect(reopened!.playId, 'play_saved');
      expect(reopened.savedRevisionId, 'revision_saved');
      expect(reopened.saved, isTrue);
      expect(reopened.moreLikeThis, isTrue);
      expect(reopened.notInterested, isFalse);
      expect(reopened.updatedAt, savedAt);
      expect(await state.readMutedTopicIds(), <String>['history', 'science']);
    } finally {
      await store.close();
      await IndexedDbEventStore.deleteDatabase(name);
    }
  });

  test('corrupt web action metadata fails closed and is removed', () async {
    final name = _databaseName();
    final store = await IndexedDbEventStore.open(databaseName: name);
    try {
      final state = IndexedDbConsumerLocalState(store);
      final key = _playActionMetadataKey('play_corrupt');
      await store.writeConsumerMetadata(key, '{"playId":"wrong","saved":true}');
      expect(await state.readPlayActionState('play_corrupt'), isNull);
      expect(await store.readConsumerMetadata(key), isNull);
    } finally {
      await store.close();
      await IndexedDbEventStore.deleteDatabase(name);
    }
  });
}
