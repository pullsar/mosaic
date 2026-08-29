import 'dart:convert';

import 'package:event_delivery/event_delivery.dart';

import 'consumer_api_client.dart';
import 'consumer_local_state.dart';

const _preferencesKey = 'preferences.v1';
const _feedResumeKey = 'feed_resume.v1';

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
  Future<void> writePreferences(ConsumerPreferences preferences) =>
      _store.writeConsumerMetadata(
        _preferencesKey,
        jsonEncode(preferences.toJson()),
      );

  @override
  Future<ConsumerFeedResume?> readFeedResume() async {
    final encoded = await _store.readConsumerMetadata(_feedResumeKey);
    if (encoded == null) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map) return null;
      final cursor = value['cursor'];
      final revisions = value['windowRevisionIds'];
      final updatedAtRaw = value['updatedAt'];
      if (cursor != null && (cursor is! String || cursor.length > 512)) {
        return null;
      }
      if (revisions is! List || revisions.length > 64 || updatedAtRaw is! String) {
        return null;
      }
      final revisionIds = <String>[];
      final seen = <String>{};
      for (final value in revisions) {
        if (value is! String) return null;
        final normalized = value.trim();
        if (normalized.isEmpty || normalized.length > 200) return null;
        if (seen.add(normalized)) revisionIds.add(normalized);
      }
      final updatedAt = DateTime.tryParse(updatedAtRaw)?.toUtc();
      if (updatedAt == null) return null;
      final result = ConsumerFeedResume(
        cursor: cursor as String?,
        windowRevisionIds: revisionIds,
        updatedAt: updatedAt,
      );
      return result.isEmpty ? null : result;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> writeFeedResume(ConsumerFeedResume state) =>
      _store.writeConsumerMetadata(
        _feedResumeKey,
        jsonEncode(<String, Object?>{
          'cursor': state.cursor,
          'windowRevisionIds': state.windowRevisionIds,
          'updatedAt': state.updatedAt.toUtc().toIso8601String(),
        }),
      );

  @override
  Future<void> clearFeedResume() => _store.deleteConsumerMetadata(_feedResumeKey);
}
