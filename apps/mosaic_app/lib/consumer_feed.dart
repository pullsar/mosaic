import 'dart:async';
import 'dart:math' as math;

import 'package:analytics_contract/analytics_contract.dart';
import 'package:flutter/material.dart';

import 'consumer_api_client.dart';
import 'consumer_local_state.dart';
import 'consumer_runtime.dart';

typedef ConsumerFeedItemBuilder = Widget Function(
  BuildContext context,
  ConsumerFeedItem item, {
  required String feedRequestId,
  required bool active,
  required ValueChanged<bool> onDirectManipulationChanged,
});

typedef ConsumerFeedEventSink = void Function(
  String event, {
  required String feedRequestId,
  required String playRevisionId,
  required Map<String, Object?> payload,
});

typedef ConsumerFeedWarmWindowCallback =
    FutureOr<void> Function(
      BuildContext context,
      List<ConsumerFeedItem> items,
    );

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
    this.onEvent,
    this.onWarmWindow,
    this.onCancelWarmWindow,
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
  final ConsumerFeedEventSink? onEvent;
  final ConsumerFeedWarmWindowCallback? onWarmWindow;
  final VoidCallback? onCancelWarmWindow;
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

final class _ConsumerFeedState extends State<ConsumerFeed> {
  late final PageController _pageController;
  final List<_FeedEntry> _entries = <_FeedEntry>[];
  final Set<String> _impressed = <String>{};
  final Set<String> _started = <String>{};
  Future<void> _persistTail = Future<void>.value();

  int _currentIndex = 0;
  int _loadEpoch = 0;
  String? _activeDecisionRequestId;
  String? _nextCursor;
  ConsumerApiFailureKind? _failure;
  bool _booting = true;
  bool _fetching = false;
  bool _directManipulationActive = false;
  bool _suppressPageCallback = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    final epoch = ++_loadEpoch;
    final resume = await widget.runtime.readFeedResume();
    final recovered = await widget.runtime.recoverRecentFeed();
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
      });
      _jumpAfterBuild(restoredIndex);
      _emitInitialVisibleAfterBuild();
      _scheduleWarmWindow();
    }

    final initialCursor = recovered != null && recovered.items.isNotEmpty
        ? _nextCursor
        : null;
    await _fetchPage(initialCursor, epoch: epoch);
  }

  int _restoredIndex(
    ConsumerFeedCache recovered,
    ConsumerFeedResume? resume,
  ) {
    if (resume == null || resume.requestId != recovered.requestId) return 0;
    final position = resume.visiblePosition;
    if (position != null && position >= 0 && position < recovered.items.length) {
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
    );
    if (!mounted || requestEpoch != _loadEpoch) return;

    final page = result.page;
    var shouldJumpToZero = false;
    var shouldEmitInitial = false;
    setState(() {
      _fetching = false;
      _failure = result.failure;

      if (page != null) {
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
          shouldJumpToZero = true;
        } else {
          _activeDecisionRequestId = page.requestId;
          _nextCursor = nextCursor;
        }
      } else if (_entries.isEmpty && result.recovered != null) {
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

      _booting = false;
      _trimRetainedWindow();
    });

    if (shouldJumpToZero) _jumpAfterBuild(0);
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

  void _onPageChanged(int index) {
    if (_suppressPageCallback || index < 0 || index >= _entries.length) return;
    final previous = _entries[_currentIndex];
    final next = _entries[index];
    if (previous.analyticsIdentity == next.analyticsIdentity) return;

    setState(() {
      _currentIndex = index;
      _directManipulationActive = false;
      _trimRetainedWindow();
    });

    _emitDismissed(previous);
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
      _jumpAfterBuild(_currentIndex);
    }

    final remainingExcess = _entries.length - widget.maxRetainedItems;
    if (remainingExcess > 0) {
      _entries.removeRange(
        _entries.length - remainingExcess,
        _entries.length,
      );
    }
  }

  void _jumpAfterBuild(int page) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      final bounded = math.max(0, math.min(page, _entries.length - 1));
      if ((_pageController.page?.round() ?? 0) == bounded) return;
      _suppressPageCallback = true;
      _pageController.jumpToPage(bounded);
      _suppressPageCallback = false;
    });
  }

  void _maybeFetchAhead() {
    if (_fetching || _entries.isEmpty || _nextCursor == null) return;
    final remaining = _entries.length - _currentIndex - 1;
    if (remaining <= widget.fetchAheadItems) {
      unawaited(_fetchPage(_nextCursor));
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
        final result = callback(context, items);
        if (result is Future<void>) {
          unawaited(result.catchError((Object _, StackTrace _) {}));
        }
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
    final items = decisionEntries.map((entry) => entry.item).toList(
      growable: false,
    );
    _persistTail = _persistTail.then((_) async {
      await widget.runtime.persistFeedWindow(
        requestId: visible.requestId,
        cursor: cursor,
        visibleRevisionId: visible.item.revisionId,
        visiblePosition: visiblePosition,
        items: items,
      );
    });
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
    if (_impressed.add(entry.analyticsIdentity)) {
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
    if (_started.add(entry.analyticsIdentity)) {
      sink(
        MosaicEventName.playStarted,
        feedRequestId: entry.requestId,
        playRevisionId: entry.item.revisionId,
        payload: payload,
      );
    }
  }

  void _emitDismissed(_FeedEntry entry) {
    widget.onEvent?.call(
      MosaicEventName.playDismissed,
      feedRequestId: entry.requestId,
      playRevisionId: entry.item.revisionId,
      payload: <String, Object?>{
        'playId': entry.item.playId,
        'reason': 'swipe',
      },
    );
  }

  Future<void> _retry() async {
    if (_fetching) return;
    final cursor = _entries.isEmpty ? null : _nextCursor;
    await _fetchPage(cursor, epoch: _entries.isEmpty ? _loadEpoch : null);
  }

  @override
  void dispose() {
    _loadEpoch += 1;
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
