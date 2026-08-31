import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_state/local_state.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/consumer_local_state_native.dart';
import 'package:mosaic_app/guest_engagement.dart';

void main() {
  test(
    'guest engagement survives SQLite reopen and cleans corruption',
    () async {
      final directory = await Directory.systemTemp.createTemp('mosaic_guest_');
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final path = '${directory.path}/mosaic.sqlite3';
      final dismissedAt = DateTime.utc(2026, 8, 31, 12);

      var store = MosaicLocalStore.open(path);
      var state = SqliteConsumerLocalState(store);
      await state.writeGuestEngagement(
        GuestEngagementState(
          seenIdentities: List<String>.generate(
            5,
            (index) => 'request\u0000rev_$index',
          ),
          dismissedAt: dismissedAt,
        ),
      );
      store.close();

      store = MosaicLocalStore.open(path);
      state = SqliteConsumerLocalState(store);
      final restored = await state.readGuestEngagement();
      expect(restored?.seenIdentities, hasLength(5));
      expect(restored?.dismissedAt, dismissedAt);

      store.saveGuestEngagementJson('{broken');
      expect(await state.readGuestEngagement(), isNull);
      expect(store.loadGuestEngagementJson(), isNull);
      store.close();
    },
  );

  test(
    'native consumer adapter preserves distinct preferences and resume state',
    () async {
      final store = MosaicLocalStore.openInMemory();
      final state = SqliteConsumerLocalState(store);

      await state.writePreferences(
        ConsumerPreferences(
          interestTopicIds: const ['travel', 'food'],
          learningTopicIds: const ['piano'],
        ),
      );
      await state.writeFeedResume(
        ConsumerFeedResume(
          cursor: 'cursor_2',
          windowRevisionIds: const ['rev_a', 'rev_b'],
          updatedAt: DateTime.utc(2026, 8, 29, 15),
        ),
      );

      final preferences = await state.readPreferences();
      final resume = await state.readFeedResume();
      expect(preferences.interestTopicIds, const ['food', 'travel']);
      expect(preferences.learningTopicIds, const ['piano']);
      expect(resume?.cursor, 'cursor_2');
      expect(resume?.windowRevisionIds, const ['rev_a', 'rev_b']);

      await state.clearFeedResume();
      expect(await state.readFeedResume(), isNull);
      expect((await state.readPreferences()).interestTopicIds, const [
        'food',
        'travel',
      ]);

      store.close();
    },
  );

  test(
    'onboarding, actions and muted topics survive native database reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mosaic_onboarding_',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final path = '${directory.path}/mosaic.sqlite3';

      var store = MosaicLocalStore.open(path);
      var state = SqliteConsumerLocalState(store);
      expect(await state.readOnboardingCompleted(), isFalse);

      await state.writePreferences(
        ConsumerPreferences(
          interestTopicIds: const ['travel', 'science'],
          learningTopicIds: const ['history'],
        ),
      );
      await state.writeOnboardingCompleted(true);
      await state.writePlayActionState(
        ConsumerPlayActionState(
          playId: 'play_a',
          savedRevisionId: 'rev_a',
          saved: true,
          moreLikeThis: true,
          notInterested: false,
          updatedAt: DateTime.utc(2026, 8, 29, 20),
        ),
      );
      await state.writeMutedTopicIds(const ['science', 'history', 'science']);
      store.close();

      store = MosaicLocalStore.open(path);
      state = SqliteConsumerLocalState(store);
      final restored = await state.readPreferences();
      final action = await state.readPlayActionState('play_a');
      expect(await state.readOnboardingCompleted(), isTrue);
      expect(restored.interestTopicIds, const ['science', 'travel']);
      expect(restored.learningTopicIds, const ['history']);
      expect(action?.saved, isTrue);
      expect(action?.savedRevisionId, 'rev_a');
      expect(action?.moreLikeThis, isTrue);
      expect(action?.notInterested, isFalse);
      expect(await state.readMutedTopicIds(), const ['history', 'science']);

      await state.writePlayActionState(
        action!.copyWith(
          saved: false,
          clearSavedRevisionId: true,
          notInterested: true,
          updatedAt: DateTime.utc(2026, 8, 29, 21),
        ),
      );
      await state.writeMutedTopicIds(const ['science']);
      await state.writeOnboardingCompleted(false);
      store.close();

      store = MosaicLocalStore.open(path);
      state = SqliteConsumerLocalState(store);
      final reopened = await state.readPreferences();
      final reopenedAction = await state.readPlayActionState('play_a');
      expect(await state.readOnboardingCompleted(), isFalse);
      expect(reopened.interestTopicIds, const ['science', 'travel']);
      expect(reopened.learningTopicIds, const ['history']);
      expect(reopenedAction?.saved, isFalse);
      expect(reopenedAction?.savedRevisionId, isNull);
      expect(reopenedAction?.moreLikeThis, isTrue);
      expect(reopenedAction?.notInterested, isTrue);
      expect(await state.readMutedTopicIds(), const ['science']);
      store.close();
    },
  );
}
