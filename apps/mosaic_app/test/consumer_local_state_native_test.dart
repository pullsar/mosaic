import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_state/local_state.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/consumer_local_state_native.dart';

void main() {
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

  test('onboarding completion survives native database reopen', () async {
    final directory = await Directory.systemTemp.createTemp('mosaic_onboarding_');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final path = '${directory.path}/mosaic.sqlite3';

    var store = MosaicLocalStore.open(path);
    var state = SqliteConsumerLocalState(store);
    expect(await state.readOnboardingCompleted(), isFalse);

    await state.writeOnboardingCompleted(true);
    store.close();

    store = MosaicLocalStore.open(path);
    state = SqliteConsumerLocalState(store);
    expect(await state.readOnboardingCompleted(), isTrue);

    await state.writeOnboardingCompleted(false);
    store.close();

    store = MosaicLocalStore.open(path);
    state = SqliteConsumerLocalState(store);
    expect(await state.readOnboardingCompleted(), isFalse);
    store.close();
  });
}
