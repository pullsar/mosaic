import 'dart:convert';

import 'package:local_state/local_state.dart';
import 'package:play_schema/play_schema.dart';

import 'consumer_api_client.dart';
import 'consumer_local_state.dart';
import 'guest_engagement.dart';

final class SqliteConsumerLocalState
    implements ConsumerLocalState, GuestEngagementStore {
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
  Future<bool> readOnboardingCompleted() async =>
      _store.consumerOnboardingCompleted;

  @override
  Future<void> writeOnboardingCompleted(bool completed) async =>
      _store.setConsumerOnboardingCompleted(completed);

  @override
  Future<ConsumerFeedResume?> readFeedResume() async {
    final state = _store.loadFeedResume();
    if (state == null) return null;
    final result = ConsumerFeedResume(
      requestId: state.requestId,
      cursor: state.cursor,
      visibleRevisionId: state.visibleRevisionId,
      visiblePosition: state.visiblePosition,
      windowRevisionIds: state.windowRevisionIds,
      updatedAt: state.updatedAt,
    );
    return result.isEmpty ? null : result;
  }

  @override
  Future<void> writeFeedResume(ConsumerFeedResume state) async {
    _store.saveFeedResume(
      requestId: state.requestId,
      cursor: state.cursor,
      visibleRevisionId: state.visibleRevisionId,
      visiblePosition: state.visiblePosition,
      windowRevisionIds: state.windowRevisionIds,
      updatedAt: state.updatedAt,
    );
  }

  @override
  Future<void> clearFeedResume() async {
    _store.saveFeedResume(
      requestId: null,
      cursor: null,
      visibleRevisionId: null,
      visiblePosition: null,
      windowRevisionIds: const [],
      updatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<ConsumerFeedCache?> readRecentFeed({
    required PlayCapabilityEnvelope capabilities,
  }) async {
    final state = _store.loadRecentFeedCache();
    if (state == null) return null;
    try {
      return ConsumerFeedCache.fromJson(<String, Object?>{
        'requestId': state.requestId,
        'items': state.items,
        'updatedAt': state.updatedAt.toUtc().toIso8601String(),
      }, capabilities: capabilities);
    } on Object {
      _store.clearRecentFeedCache();
      return null;
    }
  }

  @override
  Future<void> writeRecentFeed(ConsumerFeedCache state) async {
    final encoded = state.toJson();
    final rawItems = encoded['items'] as List<Object?>;
    final items = rawItems
        .map((value) => (value as Map).cast<String, Object?>())
        .toList(growable: false);
    _store.saveRecentFeedCache(
      requestId: state.requestId,
      items: items,
      updatedAt: state.updatedAt,
    );
  }

  @override
  Future<void> clearRecentFeed() async => _store.clearRecentFeedCache();

  @override
  Future<ConsumerPlayActionState?> readPlayActionState(String playId) async {
    final state = _store.loadConsumerPlayActionState(playId);
    if (state == null) return null;
    return ConsumerPlayActionState(
      playId: state.playId,
      savedRevisionId: state.savedRevisionId,
      saved: state.saved,
      moreLikeThis: state.moreLikeThis,
      notInterested: state.notInterested,
      updatedAt: state.updatedAt,
    );
  }

  @override
  Future<void> writePlayActionState(ConsumerPlayActionState state) async {
    _store.saveConsumerPlayActionState(
      LocalConsumerPlayActionState(
        playId: state.playId,
        savedRevisionId: state.savedRevisionId,
        saved: state.saved,
        moreLikeThis: state.moreLikeThis,
        notInterested: state.notInterested,
        updatedAt: state.updatedAt,
      ),
    );
  }

  @override
  Future<List<String>> readMutedTopicIds() async =>
      _store.consumerMutedTopics().toList()..sort();

  @override
  Future<void> writeMutedTopicIds(Iterable<String> topicIds) async =>
      _store.replaceConsumerMutedTopics(topicIds);

  @override
  Future<GuestEngagementState?> readGuestEngagement() async {
    final encoded = _store.loadGuestEngagementJson();
    if (encoded == null) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        throw const FormatException('guest engagement must be an object');
      }
      return GuestEngagementState.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } on Object {
      _store.clearGuestEngagementJson();
      return null;
    }
  }

  @override
  Future<void> writeGuestEngagement(GuestEngagementState state) async =>
      _store.saveGuestEngagementJson(jsonEncode(state.toJson()));
}
