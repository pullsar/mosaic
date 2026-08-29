import 'package:local_state/local_state.dart';

import 'consumer_api_client.dart';
import 'consumer_local_state.dart';

final class SqliteConsumerLocalState implements ConsumerLocalState {
  const SqliteConsumerLocalState(this._store);

  final MosaicLocalStore _store;

  @override
  Future<ConsumerPreferences> readPreferences() async => ConsumerPreferences(
    interestTopicIds: _store.interests(InterestKind.interest).toList()..sort(),
    learningTopicIds: _store.interests(InterestKind.learning).toList()..sort(),
  );

  @override
  Future<void> writePreferences(ConsumerPreferences preferences) async {
    _store.replaceInterests(
      InterestKind.interest,
      preferences.interestTopicIds,
    );
    _store.replaceInterests(
      InterestKind.learning,
      preferences.learningTopicIds,
    );
  }

  @override
  Future<ConsumerFeedResume?> readFeedResume() async {
    final state = _store.loadFeedResume();
    if (state == null) return null;
    final result = ConsumerFeedResume(
      cursor: state.cursor,
      windowRevisionIds: state.windowRevisionIds,
      updatedAt: state.updatedAt,
    );
    return result.isEmpty ? null : result;
  }

  @override
  Future<void> writeFeedResume(ConsumerFeedResume state) async {
    _store.saveFeedResume(
      cursor: state.cursor,
      windowRevisionIds: state.windowRevisionIds,
      updatedAt: state.updatedAt,
    );
  }

  @override
  Future<void> clearFeedResume() async {
    _store.saveFeedResume(
      cursor: null,
      windowRevisionIds: const [],
      updatedAt: DateTime.now().toUtc(),
    );
  }
}
