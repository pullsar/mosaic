import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:play_schema/play_schema.dart';

import 'consumer_api_client.dart';
import 'consumer_local_state.dart';

const _preferencesKey = 'preferences.v1';
const _onboardingCompletedKey = 'onboarding_completed.v1';
const _feedResumeKey = 'feed_resume.v1';
const _recentFeedKey = 'recent_feed.v1';
const _mutedTopicsKey = 'muted_topics.v1';
const _playActionPrefix = 'play_action.v1.';
const _maxMutedTopics = 512;

final class IndexedDbConsumerLocalState implements ConsumerLocalState {
  const IndexedDbConsumerLocalState(this._store);

  final IndexedDbEventStore _store;

  @override
  Future<ConsumerPreferences> readPreferences() async {
    final encoded = await _store.readConsumerMetadata(_preferencesKey);
    if (encoded == null) return ConsumerPreferences();
    try {
      final value = jsonDecode(encoded);
      if (value is! Map) return ConsumerPreferences();
      return ConsumerPreferences.fromJson(
        value.map((key, nested) => MapEntry(key.toString(), nested)),
      );
    } on Object {
      return ConsumerPreferences();
    }
  }

  @override
  Future<void> writePreferences(ConsumerPreferences preferences) => _store
      .writeConsumerMetadata(_preferencesKey, jsonEncode(preferences.toJson()));

  @override
  Future<bool> readOnboardingCompleted() async =>
      await _store.readConsumerMetadata(_onboardingCompletedKey) == '1';

  @override
  Future<void> writeOnboardingCompleted(bool completed) => completed
      ? _store.writeConsumerMetadata(_onboardingCompletedKey, '1')
      : _store.deleteConsumerMetadata(_onboardingCompletedKey);

  @override
  Future<ConsumerFeedResume?> readFeedResume() async {
    final encoded = await _store.readConsumerMetadata(_feedResumeKey);
    if (encoded == null) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map) return null;
      final state = ConsumerFeedResume.fromJson(
        value.map((key, nested) => MapEntry(key.toString(), nested)),
      );
      return state.isEmpty ? null : state;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> writeFeedResume(ConsumerFeedResume state) =>
      _store.writeConsumerMetadata(_feedResumeKey, jsonEncode(state.toJson()));

  @override
  Future<void> clearFeedResume() =>
      _store.deleteConsumerMetadata(_feedResumeKey);

  @override
  Future<ConsumerFeedCache?> readRecentFeed({
    required PlayCapabilityEnvelope capabilities,
  }) async {
    final encoded = await _store.readConsumerMetadata(_recentFeedKey);
    if (encoded == null) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map) return null;
      final cache = ConsumerFeedCache.fromJson(
        value.map((key, nested) => MapEntry(key.toString(), nested)),
        capabilities: capabilities,
      );
      if (cache.isExpiredAt(DateTime.now())) {
        await clearRecentFeed();
        return null;
      }
      return cache;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> writeRecentFeed(ConsumerFeedCache state) =>
      _store.writeConsumerMetadata(_recentFeedKey, jsonEncode(state.toJson()));

  @override
  Future<void> clearRecentFeed() =>
      _store.deleteConsumerMetadata(_recentFeedKey);

  @override
  Future<ConsumerPlayActionState?> readPlayActionState(String playId) async {
    final key = _playActionKey(playId);
    final encoded = await _store.readConsumerMetadata(key);
    if (encoded == null) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map) throw const FormatException('action state is invalid');
      final state = ConsumerPlayActionState.fromJson(
        value.map((key, nested) => MapEntry(key.toString(), nested)),
      );
      if (state.playId != playId.trim()) {
        throw const FormatException('action state identity mismatch');
      }
      return state;
    } on Object {
      await _store.deleteConsumerMetadata(key);
      return null;
    }
  }

  @override
  Future<void> writePlayActionState(ConsumerPlayActionState state) =>
      _store.writeConsumerMetadata(
        _playActionKey(state.playId),
        jsonEncode(state.toJson()),
      );

  @override
  Future<List<String>> readMutedTopicIds() async {
    final encoded = await _store.readConsumerMetadata(_mutedTopicsKey);
    if (encoded == null) return const [];
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List || decoded.length > _maxMutedTopics) {
        throw const FormatException('muted topics are invalid');
      }
      return _normalizeTopicIds(decoded.cast<Object?>());
    } on Object {
      await _store.deleteConsumerMetadata(_mutedTopicsKey);
      return const [];
    }
  }

  @override
  Future<void> writeMutedTopicIds(Iterable<String> topicIds) =>
      _store.writeConsumerMetadata(
        _mutedTopicsKey,
        jsonEncode(_normalizeTopicIds(topicIds)),
      );
}

String _playActionKey(String playId) {
  final normalized = playId.trim();
  if (normalized.isEmpty || normalized.length > 200) {
    throw ArgumentError.value(playId, 'playId', 'must be 1 to 200 characters');
  }
  return '$_playActionPrefix${sha256.convert(utf8.encode(normalized))}';
}

List<String> _normalizeTopicIds(Iterable<Object?> values) {
  final result = <String>{};
  for (final value in values) {
    if (value is! String) {
      throw const FormatException('muted topic IDs must be strings');
    }
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 200) {
      throw const FormatException('muted topic ID is invalid');
    }
    result.add(normalized);
    if (result.length > _maxMutedTopics) {
      throw const FormatException('too many muted topics');
    }
  }
  return result.toList(growable: false)..sort();
}
