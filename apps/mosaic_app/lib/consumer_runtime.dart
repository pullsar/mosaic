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
  bool get hasUsableContent =>
      page != null || (recovered?.items.isNotEmpty ?? false);
}

/// Coordinates M2 consumer API and local recovery semantics without owning UI.
///
/// Storage remains local-first for explicit preference intent. Feed failures
/// preserve their exact API classification while optionally exposing a recent,
/// revalidated Play window so callers never need to hide identity failures or
/// manufacture a second retry loop.
final class ConsumerRuntime {
  ConsumerRuntime({
    this.api,
    required this.localState,
    required this.capabilities,
    ConsumerRuntimeClock? clock,
    this.onError,
  }) : _clock = clock ?? DateTime.now;

  static const int recentFeedMaxItems = ConsumerFeedCache.maxItems;
  static const int recentFeedMaxBytes = 256 * 1024;
  static const Duration recentFeedMaxAge = ConsumerFeedCache.maxAge;

  /// Null only when the app intentionally has no configured API endpoint.
  /// Local onboarding remains usable and all network operations fail retryably.
  final ConsumerApiClient? api;
  final ConsumerLocalState localState;
  final PlayCapabilityEnvelope capabilities;
  final ConsumerRuntimeErrorReporter? onError;
  final ConsumerRuntimeClock _clock;

  Future<ConsumerPreferences> readPreferences() => localState.readPreferences();

  Future<bool> readOnboardingCompleted() async {
    try {
      return await localState.readOnboardingCompleted();
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_onboarding_read');
      return false;
    }
  }

  Future<bool> writeOnboardingCompleted(bool completed) async {
    try {
      await localState.writeOnboardingCompleted(completed);
      return true;
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_onboarding_write');
      return false;
    }
  }

  Future<ConsumerApiResult<List<ConsumerTopic>>> searchTopics({
    String query = '',
    int limit = 100,
  }) {
    final client = api;
    if (client == null) {
      return Future.value(
        const ConsumerApiFailure<List<ConsumerTopic>>(
          ConsumerApiFailureKind.retryable,
        ),
      );
    }
    return client.searchTopics(query: query, limit: limit);
  }

  /// Persists a preference mutation without issuing a network request.
  ///
  /// Onboarding uses this per committed selection, then batches the remote
  /// replacement separately so rapid taps never become one HTTP request each.
  Future<bool> persistPreferencesLocally(
    ConsumerPreferences preferences,
  ) async {
    try {
      await localState.writePreferences(preferences);
      return true;
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_preferences_local_write');
      return false;
    }
  }

  /// Replaces server preferences for a snapshot that is already durable locally.
  Future<ConsumerPreferenceSaveResult> syncPreferences(
    ConsumerPreferences preferences,
  ) async {
    final client = api;
    if (client == null) {
      return const ConsumerPreferenceSaveResult(
        localPersisted: true,
        remoteFailure: ConsumerApiFailureKind.retryable,
      );
    }

    final remote = await client.replacePreferences(preferences);
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

  Future<ConsumerPreferenceSaveResult> syncLocalPreferences() async {
    try {
      return syncPreferences(await localState.readPreferences());
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_preferences_local_read');
      return const ConsumerPreferenceSaveResult(localPersisted: false);
    }
  }

  Future<ConsumerPreferenceSaveResult> savePreferences(
    ConsumerPreferences preferences,
  ) async {
    if (!await persistPreferencesLocally(preferences)) {
      return const ConsumerPreferenceSaveResult(localPersisted: false);
    }
    return syncPreferences(preferences);
  }

  Future<ConsumerFeedResume?> readFeedResume() async {
    try {
      return await localState.readFeedResume();
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_feed_resume_read');
      return null;
    }
  }

  /// Persists the coordinator's bounded recoverable feed window and position.
  ///
  /// This is intentionally separate from [fetchFeed]. A feed pager can fetch
  /// ahead without replacing the currently recoverable visible window with a
  /// page that has not been shown yet.
  Future<bool> persistFeedWindow({
    required String requestId,
    required String? cursor,
    required String? visibleRevisionId,
    required int? visiblePosition,
    required List<ConsumerFeedItem> items,
  }) async {
    final now = _clock().toUtc();
    ConsumerFeedItem? visibleItem;
    if (visiblePosition != null &&
        visiblePosition >= 0 &&
        visiblePosition < items.length) {
      final candidate = items[visiblePosition];
      if (visibleRevisionId == null ||
          candidate.revisionId == visibleRevisionId) {
        visibleItem = candidate;
      }
    }
    if (visibleItem == null && visibleRevisionId != null) {
      for (final item in items) {
        if (item.revisionId == visibleRevisionId) {
          visibleItem = item;
          break;
        }
      }
    }

    var boundedItems = _boundedRecentItems(requestId, items, now);
    if (visibleItem != null &&
        boundedItems.every((item) => !_sameFeedItem(item, visibleItem!))) {
      final visibleOnly = _boundedRecentItems(requestId, [visibleItem], now);
      if (visibleOnly.isNotEmpty) boundedItems = visibleOnly;
    }

    final persistedVisiblePosition = visibleItem == null
        ? -1
        : boundedItems.indexWhere((item) => _sameFeedItem(item, visibleItem!));
    final normalizedVisiblePosition = persistedVisiblePosition < 0
        ? null
        : persistedVisiblePosition;
    final normalizedVisibleRevisionId = normalizedVisiblePosition == null
        ? null
        : visibleItem!.revisionId;

    var persisted = true;
    try {
      await localState.writeFeedResume(
        ConsumerFeedResume(
          requestId: requestId,
          cursor: cursor,
          visibleRevisionId: normalizedVisibleRevisionId,
          visiblePosition: normalizedVisiblePosition,
          windowRevisionIds: boundedItems
              .map((item) => item.revisionId)
              .toList(growable: false),
          updatedAt: now,
        ),
      );
    } on Object catch (error, stackTrace) {
      persisted = false;
      _report(error, stackTrace, operation: 'consumer_feed_resume_write');
    }

    try {
      if (boundedItems.isEmpty) {
        await localState.clearRecentFeed();
      } else {
        await localState.writeRecentFeed(
          ConsumerFeedCache(
            requestId: requestId,
            items: boundedItems,
            updatedAt: now,
          ),
        );
      }
    } on Object catch (error, stackTrace) {
      persisted = false;
      _report(error, stackTrace, operation: 'consumer_recent_feed_write');
    }
    return persisted;
  }

  Future<ConsumerFeedLoadResult> fetchFeed({
    String? cursor,
    int limit = 8,
    bool persistPage = true,
  }) async {
    final client = api;
    if (client == null) {
      return ConsumerFeedLoadResult(
        recovered: await _recoverRecentFeed(),
        failure: ConsumerApiFailureKind.retryable,
      );
    }

    final first = await client.fetchFeed(
      capabilities: capabilities,
      cursor: cursor,
      limit: limit,
    );
    if (first is ConsumerApiSuccess<ConsumerFeedPage>) {
      if (persistPage) await _persistNetworkPage(first.value);
      return ConsumerFeedLoadResult(page: first.value);
    }

    final firstFailure = first as ConsumerApiFailure<ConsumerFeedPage>;
    if (cursor != null &&
        firstFailure.kind == ConsumerApiFailureKind.invalidCursor) {
      await _clearStaleCursorSafely();
      final retry = await client.fetchFeed(
        capabilities: capabilities,
        cursor: null,
        limit: limit,
      );
      if (retry is ConsumerApiSuccess<ConsumerFeedPage>) {
        if (persistPage) await _persistNetworkPage(retry.value);
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

  void close() => api?.close();

  Future<void> _persistNetworkPage(ConsumerFeedPage page) async {
    await persistFeedWindow(
      requestId: page.requestId,
      cursor: page.nextCursor,
      visibleRevisionId: null,
      visiblePosition: null,
      items: page.items,
    );
  }

  List<ConsumerFeedItem> _boundedRecentItems(
    String requestId,
    Iterable<ConsumerFeedItem> items,
    DateTime now,
  ) {
    final selected = <ConsumerFeedItem>[];
    for (final item in items) {
      if (selected.length >= recentFeedMaxItems) break;
      final candidate = <ConsumerFeedItem>[...selected, item];
      final encoded = jsonEncode(
        ConsumerFeedCache(
          requestId: requestId,
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
      final cached = await localState.readRecentFeed(
        capabilities: capabilities,
      );
      if (cached == null) return null;
      if (cached.isExpiredAt(_clock())) {
        await localState.clearRecentFeed();
        return null;
      }
      return cached;
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_recent_feed_read');
      return null;
    }
  }

  Future<void> _clearStaleCursorSafely() async {
    try {
      final current = await localState.readFeedResume();
      if (current == null) {
        await localState.clearFeedResume();
        return;
      }
      await localState.writeFeedResume(
        ConsumerFeedResume(
          requestId: current.requestId,
          cursor: null,
          visibleRevisionId: current.visibleRevisionId,
          visiblePosition: current.visiblePosition,
          windowRevisionIds: current.windowRevisionIds,
          updatedAt: _clock().toUtc(),
        ),
      );
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

bool _sameFeedItem(ConsumerFeedItem left, ConsumerFeedItem right) =>
    left.playId == right.playId && left.revisionId == right.revisionId;
