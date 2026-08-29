import 'dart:convert';

import 'package:play_schema/play_schema.dart';

import 'consumer_api_client.dart';
import 'consumer_local_state.dart';

typedef ConsumerRuntimeClock = DateTime Function();
typedef ConsumerRuntimeErrorReporter =
    void Function(Object error, StackTrace stackTrace, {String? operation});

final class ConsumerPreferenceSaveResult {
  const ConsumerPreferenceSaveResult({
    required this.localPersisted,
    this.remoteFailure,
    this.statusCode,
  });

  final bool localPersisted;
  final ConsumerApiFailureKind? remoteFailure;
  final int? statusCode;

  bool get synced => localPersisted && remoteFailure == null;
}

final class ConsumerFeedLoadResult {
  const ConsumerFeedLoadResult({
    this.page,
    this.recovered,
    this.failure,
    this.statusCode,
    this.cursorReset = false,
  });

  final ConsumerFeedPage? page;
  final ConsumerFeedCache? recovered;
  final ConsumerApiFailureKind? failure;
  final int? statusCode;
  final bool cursorReset;

  bool get loadedFromNetwork => page != null;
  bool get hasUsableContent => page != null || (recovered?.items.isNotEmpty ?? false);
}

/// Coordinates M2 consumer API and local recovery semantics without owning UI.
///
/// Storage remains local-first for explicit preference intent. Feed failures
/// preserve their exact API classification while optionally exposing a recent,
/// revalidated Play window so callers never need to hide identity failures or
/// manufacture a second retry loop.
final class ConsumerRuntime {
  ConsumerRuntime({
    required this.api,
    required this.localState,
    required this.capabilities,
    ConsumerRuntimeClock? clock,
    this.onError,
  }) : _clock = clock ?? DateTime.now;

  static const int recentFeedMaxItems = 12;
  static const int recentFeedMaxBytes = 256 * 1024;
  static const Duration recentFeedMaxAge = Duration(days: 2);

  final ConsumerApiClient api;
  final ConsumerLocalState localState;
  final PlayCapabilityEnvelope capabilities;
  final ConsumerRuntimeErrorReporter? onError;
  final ConsumerRuntimeClock _clock;

  Future<ConsumerPreferences> readPreferences() => localState.readPreferences();

  Future<ConsumerPreferenceSaveResult> savePreferences(
    ConsumerPreferences preferences,
  ) async {
    try {
      await localState.writePreferences(preferences);
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_preferences_local_write');
      return const ConsumerPreferenceSaveResult(localPersisted: false);
    }

    final remote = await api.replacePreferences(preferences);
    if (remote is ConsumerApiSuccess<ConsumerPreferences>) {
      return const ConsumerPreferenceSaveResult(localPersisted: true);
    }
    final failure = remote as ConsumerApiFailure<ConsumerPreferences>;
    return ConsumerPreferenceSaveResult(
      localPersisted: true,
      remoteFailure: failure.kind,
      statusCode: failure.statusCode,
    );
  }

  Future<ConsumerFeedLoadResult> fetchFeed({
    String? cursor,
    int limit = 8,
  }) async {
    final first = await api.fetchFeed(
      capabilities: capabilities,
      cursor: cursor,
      limit: limit,
    );
    if (first is ConsumerApiSuccess<ConsumerFeedPage>) {
      await _persistNetworkPage(first.value);
      return ConsumerFeedLoadResult(page: first.value);
    }

    final firstFailure = first as ConsumerApiFailure<ConsumerFeedPage>;
    if (cursor != null &&
        firstFailure.kind == ConsumerApiFailureKind.invalidCursor) {
      await _clearResumeSafely();
      final retry = await api.fetchFeed(
        capabilities: capabilities,
        cursor: null,
        limit: limit,
      );
      if (retry is ConsumerApiSuccess<ConsumerFeedPage>) {
        await _persistNetworkPage(retry.value);
        return ConsumerFeedLoadResult(page: retry.value, cursorReset: true);
      }
      final retryFailure = retry as ConsumerApiFailure<ConsumerFeedPage>;
      return ConsumerFeedLoadResult(
        recovered: await _recoverRecentFeed(),
        failure: retryFailure.kind,
        statusCode: retryFailure.statusCode,
        cursorReset: true,
      );
    }

    return ConsumerFeedLoadResult(
      recovered: await _recoverRecentFeed(),
      failure: firstFailure.kind,
      statusCode: firstFailure.statusCode,
    );
  }

  Future<ConsumerFeedCache?> recoverRecentFeed() => _recoverRecentFeed();

  void close() => api.close();

  Future<void> _persistNetworkPage(ConsumerFeedPage page) async {
    final now = _clock().toUtc();
    final boundedItems = _boundedRecentItems(page, now);
    try {
      await localState.writeFeedResume(
        ConsumerFeedResume(
          requestId: page.requestId,
          cursor: page.nextCursor,
          windowRevisionIds: page.items
              .map((item) => item.revisionId)
              .toList(growable: false),
          updatedAt: now,
        ),
      );
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_feed_resume_write');
    }

    try {
      if (boundedItems.isEmpty) {
        await localState.clearRecentFeed();
      } else {
        await localState.writeRecentFeed(
          ConsumerFeedCache(
            requestId: page.requestId,
            items: boundedItems,
            updatedAt: now,
          ),
        );
      }
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_recent_feed_write');
    }
  }

  List<ConsumerFeedItem> _boundedRecentItems(
    ConsumerFeedPage page,
    DateTime now,
  ) {
    final selected = <ConsumerFeedItem>[];
    for (final item in page.items) {
      if (selected.length >= recentFeedMaxItems) break;
      final candidate = <ConsumerFeedItem>[...selected, item];
      final encoded = jsonEncode(
        ConsumerFeedCache(
          requestId: page.requestId,
          items: candidate,
          updatedAt: now,
        ).toJson(),
      );
      if (utf8.encode(encoded).length > recentFeedMaxBytes) break;
      selected.add(item);
    }
    return selected;
  }

  Future<ConsumerFeedCache?> _recoverRecentFeed() async {
    try {
      final cached = await localState.readRecentFeed(capabilities: capabilities);
      if (cached == null) return null;
      final age = _clock().toUtc().difference(cached.updatedAt.toUtc());
      if (age > recentFeedMaxAge) {
        await localState.clearRecentFeed();
        return null;
      }
      return cached;
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_recent_feed_read');
      return null;
    }
  }

  Future<void> _clearResumeSafely() async {
    try {
      await localState.clearFeedResume();
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_feed_resume_clear');
    }
  }

  void _report(
    Object error,
    StackTrace stackTrace, {
    required String operation,
  }) {
    try {
      onError?.call(error, stackTrace, operation: operation);
    } on Object {
      // Recovery observability cannot become another consumer failure mode.
    }
  }
}
