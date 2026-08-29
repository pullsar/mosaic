import 'package:flutter_test/flutter_test.dart';
import 'package:local_state/local_state.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/consumer_local_state_native.dart';

void main() {
  test('native consumer adapter preserves distinct preferences and resume state', () async {
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
    expect((await state.readPreferences()).interestTopicIds, const ['food', 'travel']);

    store.close();
  });
}
