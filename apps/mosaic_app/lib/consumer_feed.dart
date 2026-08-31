import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:analytics_contract/analytics_contract.dart';
import 'package:flutter/material.dart';

import 'consumer_api_client.dart';
import 'consumer_local_state.dart';
import 'consumer_runtime.dart';

enum ConsumerFeedAdvanceReason {
  notInterested('not_interested'),
  topicMuted('topic_muted'),
  reported('reported');

  const ConsumerFeedAdvanceReason(this.wireName);
  final String wireName;
}

final class ConsumerFeedController {
  Future<bool> Function(ConsumerFeedAdvanceReason reason)? _advance;
  bool get attached => _advance != null;

  Future<bool> advance(ConsumerFeedAdvanceReason reason) async {
    final callback = _advance;
    return callback == null ? false : callback(reason);
  }

  void _attach(
    Future<bool> Function(ConsumerFeedAdvanceReason reason) callback,
  ) => _advance = callback;

  void _detach(
    Future<bool> Function(ConsumerFeedAdvanceReason reason) callback,
  ) {
    if (identical(_advance, callback)) _advance = null;
  }
}

typedef ConsumerFeedItemBuilder =
    Widget Function(
      BuildContext context,
      ConsumerFeedItem item, {
      required String feedRequestId,
      required bool active,
      required ValueChanged<bool> onDirectManipulationChanged,
    });

typedef ConsumerFeedEventSink =
    void Function(
      String event, {
      required String feedRequestId,
      required String playRevisionId,
      required Map<String, Object?> payload,
    });

typedef ConsumerFeedWarmWindowCallback =
    FutureOr<void> Function(BuildContext context, List<ConsumerFeedItem> items);

/// Full-screen, bounded consumer feed coordination above immutable Play state.
///
/// The coordinator owns only paging/window state. Play state machines, media
/// ownership, durable local state and transport remain in their existing
/// owners. Server pages are already schema/capability validated by
/// [ConsumerApiClient] before reaching this widget.
final class ConsumerFeed extends StatefulWidget {
  const ConsumerFeed({
    required this.runtime,
    required this.itemBuilder,
    this.controller,
    this.onEvent,
    this.onWarmWindow,
    this.onCancelWarmWindow,
    this.searchIntent,
    this.persistRecovery = true,
    this.pageSize = 6,
    this.maxRetainedItems = ConsumerFeedCache.maxItems,
    this.fetchAheadItems = 2,
    this.warmAheadItems = 3,
    super.key,
  }) : assert(pageSize > 0 && pageSize <= 20),
       assert(maxRetainedItems > 0),
       assert(maxRetainedItems <= ConsumerFeedCache.maxItems),
       assert(fetchAheadItems >= 0),
       assert(warmAheadItems >= 0),
       assert(fetchAheadItems < maxRetainedItems),
       assert(warmAheadItems < maxRetainedItems);

  final ConsumerRuntime runtime;
  final ConsumerFeedItemBuilder itemBuilder;
  final ConsumerFeedController? controller;
  final ConsumerFeedEventSink? onEvent;
  final ConsumerFeedWarmWindowCallback? onWarmWindow;
  final VoidCallback? onCancelWarmWindow;
  final ConsumerFeedSearchIntent? searchIntent;
  final bool persistRecovery;
  final int pageSize;
  final int maxRetainedItems;
  final int fetchAheadItems;
  final int warmAheadItems;

  @override
  State<ConsumerFeed> createState() => _ConsumerFeedState();
}

final class _FeedEntry {
  const _FeedEntry({required this.requestId, required this.item});

  final String requestId;
  final ConsumerFeedItem item;

  String get identity => '${item.playId}\u0000${item.revisionId}';
  String get analyticsIdentity => '$requestId\u0000$identity';
}

final class _FeedPersistenceSnapshot {
  const _FeedPersistenceSnapshot({
    required this.requestId,
    required this.cursor,
    required this.visibleRevisionId,
    required this.visiblePosition,
    required this.items,
  });

  final String requestId;
  final String? cursor;
  final String visibleRevisionId;
  final int visiblePosition;
  final List<ConsumerFeedItem> items;
}

final class _ConsumerFeedState extends State<ConsumerFeed> {
  static const int _analyticsHistoryWindows = 4;

  PageController _pageController = PageController();
  final List<_FeedEntry> _entries = <_FeedEntry>[];
  final LinkedHashSet<String> _impressed = LinkedHashSet<String>();
  final LinkedHashSet<String> _started = LinkedHashSet<String>();
  _FeedPersistenceSnapshot? _pendingPersistence;
  bool _persisting = false;

  int _currentIndex = 0;
  int _loadEpoch = 0;
  String? _activeDecisionRequestId;
  String? _nextCursor;
  String? _automaticFetchBlockedCursor;
  ConsumerApiFailureKind? _failure;
  bool _booting = true;
  bool _fetching = false;
  bool _directManipulationActive = false;
  String? _pendingAdvanceIdentity;
  ConsumerFeedAdvanceReason? _pendingAdvanceReason;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(_requestAdvance);
    unawaited(_bootstrap());
  }

  @override
  void didUpdateWidget(covariant ConsumerFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(_requestAdvance);
      widget.controller?._attach(_requestAdvance);
    }
  }

  Future<void> _bootstrap() async {
    final epoch = ++_loadEpoch;
    final resume = widget.persistRecovery
        ? await widget.runtime.readFeedResume()
        : null;
    final recovered = widget.persistRecovery
        ? await widget.runtime.recoverRecentFeed()
        : null;
    if (!mounted || epoch != _loadEpoch) return;

    if (recovered != null && recovered.items.isNotEmpty) {
      final restoredIndex = _restoredIndex(recovered, resume);
      setState(() {
        _entries
          ..clear()
          ..addAll(
            recovered.items.map(
              (item) => _FeedEntry(requestId: recovered.requestId, item: item),
            ),
          );
        _currentIndex = restoredIndex;
        _activeDecisionRequestId = recovered.requestId;
        _nextCursor = resume?.requestId == recovered.requestId
            ? resume?.cursor
            : null;
        _booting = false;
        _replacePageController(restoredIndex);
      });
      _emitInitialVisibleAfterBuild();
      _scheduleWarmWindow();
    }

    final initialCursor = recovered != null && recovered.items.isNotEmpty
        ? _nextCursor
        : null;
    await _fetchPage(initialCursor, epoch: epoch);
  }

  int _restoredIndex(ConsumerFeedCache recovered, ConsumerFeedResume? resume) {
    if (resume == null || resume.requestId != recovered.requestId) return 0;
    final position = resume.visiblePosition;
    if (position != null &&
        position >= 0 &&
        position < recovered.items.length) {
      final item = recovered.items[position];
      if (resume.visibleRevisionId == null ||
          item.revisionId == resume.visibleRevisionId) {
        return position;
      }
    }
    final revisionId = resume.visibleRevisionId;
    if (revisionId == null) return 0;
    final match = recovered.items.indexWhere(
      (item) => item.revisionId == revisionId,
    );
    return match < 0 ? 0 : match;
  }

  Future<void> _fetchPage(String? cursor, {int? epoch}) async {
    if (_fetching) return;
    if (!_booting && _entries.isNotEmpty && cursor == null && epoch == null) {
      return;
    }

    final requestEpoch = epoch ?? _loadEpoch;
    setState(() {
      _fetching = true;
      _failure = null;
    });

    final result = await widget.runtime.fetchFeed(
      cursor: cursor,
      limit: widget.pageSize,
      persistPage: false,
      recoverOnFailure: widget.persistRecovery,
      searchIntent: cursor == null ? widget.searchIntent : null,
    );
    if (!mounted || requestEpoch != _loadEpoch) return;

    final page = result.page;
    var shouldEmitInitial = false;
    setState(() {
      _fetching = false;
      _failure = result.failure;
      if (result.cursorReset && page == null) {
        _nextCursor = null;
      }

      if (page != null) {
        _automaticFetchBlockedCursor = null;
        final nextCursor = page.nextCursor == cursor ? null : page.nextCursor;
        if (_entries.isEmpty) {
          _entries.addAll(
            page.items.map(
              (item) => _FeedEntry(requestId: page.requestId, item: item),
            ),
          );
          _currentIndex = 0;
          _activeDecisionRequestId = page.requestId;
          _nextCursor = nextCursor;
          shouldEmitInitial = _entries.isNotEmpty;
        } else if (_activeDecisionRequestId == page.requestId) {
          _appendUnique(page.requestId, page.items);
          _nextCursor = nextCursor;
        } else if (page.items.isNotEmpty) {
          final visible = _entries[_currentIndex];
          _entries
            ..clear()
            ..add(visible)
            ..addAll(
              page.items
                  .where((item) => !_sameItem(item, visible.item))
                  .map(
                    (item) => _FeedEntry(requestId: page.requestId, item: item),
                  ),
            );
          _currentIndex = 0;
          _activeDecisionRequestId = page.requestId;
          _nextCursor = nextCursor;
          _replacePageController(0);
        } else {
          _activeDecisionRequestId = page.requestId;
          _nextCursor = nextCursor;
        }
      } else {
        if (result.failure != null && cursor != null) {
          _automaticFetchBlockedCursor = cursor;
        }
        if (_entries.isEmpty && result.recovered != null) {
          final cache = result.recovered!;
          _entries.addAll(
            cache.items.map(
              (item) => _FeedEntry(requestId: cache.requestId, item: item),
            ),
          );
          _currentIndex = 0;
          _activeDecisionRequestId = cache.requestId;
          shouldEmitInitial = _entries.isNotEmpty;
        }
      }

      _booting = false;
      _trimRetainedWindow();
    });

    if (shouldEmitInitial) _emitInitialVisibleAfterBuild();
    _queuePersistence();
    _scheduleWarmWindow();
    _maybeFetchAhead();
  }

  void _appendUnique(String requestId, List<ConsumerFeedItem> items) {
    final identities = _entries.map((entry) => entry.identity).toSet();
    for (final item in items) {
      final identity = '${item.playId}\u0000${item.revisionId}';
      if (identities.add(identity)) {
        _entries.add(_FeedEntry(requestId: requestId, item: item));
      }
    }
  }

  Future<bool> _requestAdvance(ConsumerFeedAdvanceReason reason) async {
    if (!mounted || _entries.isEmpty || _directManipulationActive) {
      return false;
    }
    final currentIdentity = _entries[_currentIndex].analyticsIdentity;
    Future<bool> advanceLoaded() async {
      if (!mounted ||
          _entries.isEmpty ||
          _currentIndex >= _entries.length ||
          _entries[_currentIndex].analyticsIdentity != currentIdentity ||
          _currentIndex + 1 >= _entries.length) {
        return false;
      }
      _pendingAdvanceIdentity = currentIdentity;
      _pendingAdvanceReason = reason;
      try {
        await _pageController.nextPage(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      } finally {
        if (_pendingAdvanceIdentity == currentIdentity) {
          _pendingAdvanceIdentity = null;
          _pendingAdvanceReason = null;
        }
      }
      return true;
    }

    if (await advanceLoaded()) return true;
    final cursor = _nextCursor;
    if (cursor == null || _fetching) return false;
    await _fetchPage(cursor, epoch: _loadEpoch);
    return advanceLoaded();
  }

  void _onPageChanged(int index) {
    if (index < 0 || index >= _entries.length) return;
    final previous = _entries[_currentIndex];
    final next = _entries[index];
    if (previous.analyticsIdentity == next.analyticsIdentity) return;

    final programmaticReason =
        _pendingAdvanceIdentity == previous.analyticsIdentity
        ? _pendingAdvanceReason
        : null;
    _pendingAdvanceIdentity = null;
    _pendingAdvanceReason = null;

    setState(() {
      _currentIndex = index;
      _directManipulationActive = false;
      _trimRetainedWindow();
    });

    _emitDismissed(previous, reason: programmaticReason?.wireName ?? 'swipe');
    _emitVisible(next, _currentIndex);
    _queuePersistence();
    _scheduleWarmWindow();
    _maybeFetchAhead();
  }

  void _trimRetainedWindow() {
    final excess = _entries.length - widget.maxRetainedItems;
    if (excess <= 0) return;

    final removableBefore = math.max(0, _currentIndex - 1);
    final dropBefore = math.min(excess, removableBefore);
    if (dropBefore > 0) {
      _entries.removeRange(0, dropBefore);
      _currentIndex -= dropBefore;
      _replacePageController(_currentIndex);
    }

    final remainingExcess = _entries.length - widget.maxRetainedItems;
    if (remainingExcess > 0) {
      _entries.removeRange(_entries.length - remainingExcess, _entries.length);
    }
  }

  void _replacePageController(int page) {
    final bounded = math.max(0, math.min(page, _entries.length - 1));
    final previous = _pageController;
    _pageController = PageController(initialPage: bounded);
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  void _maybeFetchAhead() {
    final cursor = _nextCursor;
    if (_fetching ||
        _entries.isEmpty ||
        cursor == null ||
        cursor == _automaticFetchBlockedCursor) {
      return;
    }
    final remaining = _entries.length - _currentIndex - 1;
    if (remaining <= widget.fetchAheadItems) {
      unawaited(_fetchPage(cursor));
    }
  }

  void _scheduleWarmWindow() {
    final callback = widget.onWarmWindow;
    if (callback == null || widget.warmAheadItems == 0 || _entries.isEmpty) {
      widget.onCancelWarmWindow?.call();
      return;
    }
    final start = _currentIndex + 1;
    if (start >= _entries.length) {
      widget.onCancelWarmWindow?.call();
      return;
    }
    final end = math.min(_entries.length, start + widget.warmAheadItems);
    final items = List<ConsumerFeedItem>.unmodifiable(
      _entries.sublist(start, end).map((entry) => entry.item),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        unawaited(
          Future<void>.sync(() async {
            await callback(context, items);
          }).catchError((Object _, StackTrace _) {}),
        );
      } on Object {
        // Prefetch is best-effort and cannot destabilize paging.
      }
    });
  }

  void _onDirectManipulationChanged(_FeedEntry entry, bool active) {
    if (_entries.isEmpty ||
        _entries[_currentIndex].analyticsIdentity != entry.analyticsIdentity ||
        _directManipulationActive == active) {
      return;
    }
    setState(() => _directManipulationActive = active);
  }

  void _queuePersistence() {
    if (!widget.persistRecovery) return;
    if (_entries.isEmpty || _currentIndex >= _entries.length) return;
    final visible = _entries[_currentIndex];
    final decisionEntries = _entries
        .where((entry) => entry.requestId == visible.requestId)
        .toList(growable: false);
    final visiblePosition = decisionEntries.indexWhere(
      (entry) => entry.identity == visible.identity,
    );
    if (visiblePosition < 0) return;

    final cursor = visible.requestId == _activeDecisionRequestId
        ? _nextCursor
        : null;
    _pendingPersistence = _FeedPersistenceSnapshot(
      requestId: visible.requestId,
      cursor: cursor,
      visibleRevisionId: visible.item.revisionId,
      visiblePosition: visiblePosition,
      items: List<ConsumerFeedItem>.unmodifiable(
        decisionEntries.map((entry) => entry.item),
      ),
    );
    if (!_persisting) unawaited(_drainPersistence());
  }

  Future<void> _drainPersistence() async {
    if (_persisting) return;
    _persisting = true;
    try {
      while (true) {
        final snapshot = _pendingPersistence;
        if (snapshot == null) return;
        _pendingPersistence = null;
        await widget.runtime.persistFeedWindow(
          requestId: snapshot.requestId,
          cursor: snapshot.cursor,
          visibleRevisionId: snapshot.visibleRevisionId,
          visiblePosition: snapshot.visiblePosition,
          items: snapshot.items,
        );
      }
    } finally {
      _persisting = false;
      if (_pendingPersistence != null) {
        unawaited(_drainPersistence());
      }
    }
  }

  void _emitInitialVisibleAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entries.isEmpty) return;
      _emitVisible(_entries[_currentIndex], _currentIndex);
    });
  }

  void _emitVisible(_FeedEntry entry, int position) {
    final sink = widget.onEvent;
    if (sink == null) return;
    final payload = <String, Object?>{
      'playId': entry.item.playId,
      'position': position,
      'sourceBucket': entry.item.sourceBucket.wireName,
    };
    if (_rememberAnalyticsIdentity(_impressed, entry.analyticsIdentity)) {
      sink(
        MosaicEventName.playImpression,
        feedRequestId: entry.requestId,
        playRevisionId: entry.item.revisionId,
        payload: payload,
      );
    }
    sink(
      MosaicEventName.playVisible,
      feedRequestId: entry.requestId,
      playRevisionId: entry.item.revisionId,
      payload: payload,
    );
    if (_rememberAnalyticsIdentity(_started, entry.analyticsIdentity)) {
      sink(
        MosaicEventName.playStarted,
        feedRequestId: entry.requestId,
        playRevisionId: entry.item.revisionId,
        payload: payload,
      );
    }
  }

  bool _rememberAnalyticsIdentity(
    LinkedHashSet<String> identities,
    String identity,
  ) {
    if (!identities.add(identity)) return false;
    final limit = widget.maxRetainedItems * _analyticsHistoryWindows;
    while (identities.length > limit) {
      identities.remove(identities.first);
    }
    return true;
  }

  void _emitDismissed(_FeedEntry entry, {required String reason}) {
    widget.onEvent?.call(
      MosaicEventName.playDismissed,
      feedRequestId: entry.requestId,
      playRevisionId: entry.item.revisionId,
      payload: <String, Object?>{'playId': entry.item.playId, 'reason': reason},
    );
  }

  Future<void> _retry() async {
    if (_fetching) return;
    final cursor = _entries.isEmpty ? null : _nextCursor;
    if (_automaticFetchBlockedCursor == cursor) {
      _automaticFetchBlockedCursor = null;
    }
    await _fetchPage(cursor, epoch: _loadEpoch);
  }

  @override
  void dispose() {
    _loadEpoch += 1;
    widget.controller?._detach(_requestAdvance);
    widget.onCancelWarmWindow?.call();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_booting && _entries.isEmpty) {
      return const ColoredBox(
        color: Color(0xFF050505),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return _FeedEmptyState(failed: _failure != null, onRetry: _retry);
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PageView.builder(
          key: const ValueKey<String>('consumer-feed-pager'),
          controller: _pageController,
          scrollDirection: Axis.vertical,
          physics: _directManipulationActive
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          itemCount: _entries.length,
          onPageChanged: _onPageChanged,
          itemBuilder: (context, index) {
            final entry = _entries[index];
            final active = index == _currentIndex;
            return KeyedSubtree(
              key: ValueKey<String>(
                'feed:${entry.requestId}:${entry.item.playId}:${entry.item.revisionId}',
              ),
              child: widget.itemBuilder(
                context,
                entry.item,
                feedRequestId: entry.requestId,
                active: active,
                onDirectManipulationChanged: (value) =>
                    _onDirectManipulationChanged(entry, value),
              ),
            );
          },
        ),
        if (_failure != null && !_fetching)
          SafeArea(
            child: Align(
              alignment: AlignmentDirectional.topEnd,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
                child: IconButton.filledTonal(
                  key: const ValueKey<String>('feed-retry'),
                  tooltip: 'Retry feed',
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

final class _FeedEmptyState extends StatelessWidget {
  const _FeedEmptyState({required this.failed, required this.onRetry});

  final bool failed;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: SafeArea(
      child: Center(
        child: Semantics(
          label: failed ? 'Feed unavailable' : 'No playable items available',
          child: IconButton.filledTonal(
            key: const ValueKey<String>('feed-empty-retry'),
            tooltip: failed ? 'Retry feed' : 'Refresh feed',
            onPressed: onRetry,
            icon: Icon(
              failed ? Icons.refresh_rounded : Icons.explore_outlined,
              size: 30,
            ),
          ),
        ),
      ),
    ),
  );
}

bool _sameItem(ConsumerFeedItem left, ConsumerFeedItem right) =>
    left.playId == right.playId && left.revisionId == right.revisionId;
