import 'dart:convert';

import 'package:event_delivery/event_delivery.dart';
import 'package:play_schema/play_schema.dart';

import 'consumer_api_client.dart';
import 'consumer_local_state.dart';

const _preferencesKey = 'preferences.v1';
const _feedResumeKey = 'feed_resume.v1';
const _recentFeedKey = 'recent_feed.v1';

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
}
