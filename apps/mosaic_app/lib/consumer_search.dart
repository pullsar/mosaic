import 'dart:async';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:flutter/material.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_schema/play_schema.dart';

import 'consumer_api_client.dart';
import 'consumer_runtime.dart';

sealed class ConsumerSearchSelection {
  const ConsumerSearchSelection();
}

final class ConsumerTopicSearchSelection extends ConsumerSearchSelection {
  const ConsumerTopicSearchSelection({
    required this.intent,
    required this.topicId,
    required this.label,
  });

  final ConsumerSearchIntent intent;
  final String topicId;
  final String label;
}

final class ConsumerPlaySearchSelection extends ConsumerSearchSelection {
  const ConsumerPlaySearchSelection({required this.result});

  final ConsumerSearchPlayResult result;
}

final class ConsumerDiscoverySearch extends StatefulWidget {
  const ConsumerDiscoverySearch({
    required this.runtime,
    required this.telemetry,
    this.debounce = const Duration(milliseconds: 220),
    super.key,
  });

  final ConsumerRuntime runtime;
  final Telemetry telemetry;
  final Duration debounce;

  @override
  State<ConsumerDiscoverySearch> createState() =>
      _ConsumerDiscoverySearchState();
}

final class _ConsumerDiscoverySearchState
    extends State<ConsumerDiscoverySearch> {
  final TextEditingController _controller = TextEditingController();
  Timer? _timer;
  ConsumerSearchIntent _intent = ConsumerSearchIntent.interest;
  List<ConsumerTopic> _suggestions = const <ConsumerTopic>[];
  List<ConsumerSearchResult> _results = const <ConsumerSearchResult>[];
  String? _requestId;
  String? _queryHash;
  String? _nextCursor;
  int _resultCount = 0;
  int _queryLength = 0;
  int _epoch = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _failed = false;
  bool _selectionMade = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSuggestions());
  }

  Future<void> _loadSuggestions() async {
    final result = await widget.runtime.searchTopics(query: '', limit: 24);
    if (!mounted) return;
    if (result case ConsumerApiSuccess<List<ConsumerTopic>>(:final value)) {
      setState(() => _suggestions = value);
    }
  }

  void _onQueryChanged(String value) {
    if (mounted) setState(() {});
    _timer?.cancel();
    if (_normalizedInput(value).isEmpty) {
      _epoch += 1;
      setState(() {
        _results = const <ConsumerSearchResult>[];
        _requestId = null;
        _queryHash = null;
        _nextCursor = null;
        _resultCount = 0;
        _queryLength = 0;
        _loading = false;
        _loadingMore = false;
        _failed = false;
      });
      return;
    }
    _timer = Timer(widget.debounce, () => unawaited(_performSearch(value)));
  }

  void _setIntent(ConsumerSearchIntent value) {
    if (_intent == value) return;
    setState(() => _intent = value);
    _timer?.cancel();
    final query = _normalizedInput(_controller.text);
    if (query.isNotEmpty) unawaited(_performSearch(query));
  }

  Future<void> _performSearch(String rawQuery) async {
    final query = _normalizedInput(rawQuery);
    if (query.isEmpty) return;
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final result = await widget.runtime.search(
      query: query,
      intent: _intent,
      limit: 20,
    );
    if (!mounted || epoch != _epoch) return;
    switch (result) {
      case ConsumerApiSuccess<ConsumerSearchPage>(:final value):
        setState(() {
          _results = value.items;
          _requestId = value.requestId;
          _queryHash = value.queryHash;
          _nextCursor = value.nextCursor;
          _resultCount = value.resultCount;
          _queryLength = query.length;
          _loading = false;
          _failed = false;
        });
        widget.telemetry
            .event(MosaicEventName.searchSubmitted, <String, Object?>{
              'requestId': value.requestId,
              'intent': value.intent.wireName,
              'queryHash': value.queryHash,
              'queryLength': query.length,
              'resultCount': value.resultCount,
              'zeroResults': value.resultCount == 0,
            });
      case ConsumerApiFailure<ConsumerSearchPage>():
        setState(() {
          _loading = false;
          _failed = true;
        });
    }
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    final requestId = _requestId;
    if (cursor == null || requestId == null || _loadingMore) return;
    final epoch = _epoch;
    setState(() => _loadingMore = true);
    final result = await widget.runtime.search(cursor: cursor, limit: 20);
    if (!mounted || epoch != _epoch || requestId != _requestId) return;
    switch (result) {
      case ConsumerApiSuccess<ConsumerSearchPage>(:final value):
        if (value.requestId != requestId) {
          setState(() => _loadingMore = false);
          return;
        }
        final identities = _results.map(_resultIdentity).toSet();
        final appended = <ConsumerSearchResult>[..._results];
        for (final item in value.items) {
          if (identities.add(_resultIdentity(item))) appended.add(item);
        }
        setState(() {
          _results = List<ConsumerSearchResult>.unmodifiable(appended);
          _nextCursor = value.nextCursor;
          _loadingMore = false;
          _failed = false;
        });
      case ConsumerApiFailure<ConsumerSearchPage>():
        setState(() {
          _loadingMore = false;
          _failed = true;
        });
    }
  }

  void _selectTopic(String topicId, String label, {bool fromSearch = true}) {
    if (fromSearch) {
      final requestId = _requestId;
      final queryHash = _queryHash;
      if (requestId != null && queryHash != null) {
        widget.telemetry
            .event(MosaicEventName.searchResultSelected, <String, Object?>{
              'requestId': requestId,
              'intent': _intent.wireName,
              'queryHash': queryHash,
              'resultKind': 'topic',
              'topicId': topicId,
            });
      }
    }
    _selectionMade = true;
    Navigator.of(context).pop(
      ConsumerTopicSearchSelection(
        intent: _intent,
        topicId: topicId,
        label: label,
      ),
    );
  }

  void _selectPlay(ConsumerSearchPlayResult result) {
    final requestId = _requestId;
    final queryHash = _queryHash;
    if (requestId != null && queryHash != null) {
      widget.telemetry
          .event(MosaicEventName.searchResultSelected, <String, Object?>{
            'requestId': requestId,
            'intent': _intent.wireName,
            'queryHash': queryHash,
            'resultKind': 'play',
            'playId': result.playId,
            'revisionId': result.revisionId,
          });
    }
    _selectionMade = true;
    Navigator.of(context).pop(ConsumerPlaySearchSelection(result: result));
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (!_selectionMade) {
      final requestId = _requestId;
      final queryHash = _queryHash;
      if (requestId != null && queryHash != null && _queryLength > 0) {
        widget.telemetry
            .event(MosaicEventName.searchAbandoned, <String, Object?>{
              'requestId': requestId,
              'intent': _intent.wireName,
              'queryHash': queryHash,
              'resultCount': _resultCount,
            });
      }
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _SearchCopy.of(context);
    final hasQuery = _normalizedInput(_controller.text).isNotEmpty;
    final items = hasQuery ? _results : const <ConsumerSearchResult>[];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(10, 10, 14, 8),
              child: Row(
                children: <Widget>[
                  IconButton(
                    key: const ValueKey<String>('search-close'),
                    tooltip: copy.close,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      key: const ValueKey<String>('search-field'),
                      controller: _controller,
                      autofocus: true,
                      maxLength: 80,
                      buildCounter:
                          (
                            _, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) => null,
                      onChanged: _onQueryChanged,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: copy.search,
                        prefixIcon: const Icon(Icons.search_rounded),
                        filled: true,
                        fillColor: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.06),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(18, 4, 18, 10),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: SegmentedButton<ConsumerSearchIntent>(
                  key: const ValueKey<String>('search-intent'),
                  showSelectedIcon: false,
                  segments: <ButtonSegment<ConsumerSearchIntent>>[
                    ButtonSegment(
                      value: ConsumerSearchIntent.interest,
                      label: Text(copy.explore),
                      icon: const Icon(Icons.explore_outlined),
                    ),
                    ButtonSegment(
                      value: ConsumerSearchIntent.learning,
                      label: Text(copy.learn),
                      icon: const Icon(Icons.school_outlined),
                    ),
                  ],
                  selected: <ConsumerSearchIntent>{_intent},
                  onSelectionChanged: (selection) =>
                      _setIntent(selection.single),
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 140),
              child: _loading
                  ? const LinearProgressIndicator(
                      key: ValueKey<String>('search-loading'),
                      minHeight: 2,
                    )
                  : const SizedBox(
                      key: ValueKey<String>('search-idle'),
                      height: 2,
                    ),
            ),
            Expanded(
              child: hasQuery
                  ? _SearchResults(
                      items: items,
                      intent: _intent,
                      failed: _failed,
                      loading: _loading,
                      loadingMore: _loadingMore,
                      hasMore: _nextCursor != null,
                      onRetry: () =>
                          unawaited(_performSearch(_controller.text)),
                      onMore: () => unawaited(_loadMore()),
                      onTopic: (item) => _selectTopic(item.topicId, item.label),
                      onPlay: _selectPlay,
                    )
                  : _TopicSuggestions(
                      topics: _suggestions,
                      intent: _intent,
                      onSelected: (topic) => _selectTopic(
                        topic.id,
                        topic.label,
                        fromSearch: false,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _TopicSuggestions extends StatelessWidget {
  const _TopicSuggestions({
    required this.topics,
    required this.intent,
    required this.onSelected,
  });

  final List<ConsumerTopic> topics;
  final ConsumerSearchIntent intent;
  final ValueChanged<ConsumerTopic> onSelected;

  @override
  Widget build(BuildContext context) {
    final copy = _SearchCopy.of(context);
    if (topics.isEmpty) return const SizedBox.shrink();
    return ListView.separated(
      padding: const EdgeInsetsDirectional.fromSTEB(18, 12, 18, 24),
      itemCount: topics.length + 1,
      separatorBuilder: (_, index) =>
          index == 0 ? const SizedBox(height: 8) : const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Text(
            copy.topics,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
        }
        final topic = topics[index - 1];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.tag_rounded),
          title: Text(topic.label),
          subtitle: Text(
            intent == ConsumerSearchIntent.learning ? copy.learn : copy.explore,
          ),
          trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
          onTap: () => onSelected(topic),
        );
      },
    );
  }
}

final class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.items,
    required this.intent,
    required this.failed,
    required this.loading,
    required this.loadingMore,
    required this.hasMore,
    required this.onRetry,
    required this.onMore,
    required this.onTopic,
    required this.onPlay,
  });

  final List<ConsumerSearchResult> items;
  final ConsumerSearchIntent intent;
  final bool failed;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final VoidCallback onRetry;
  final VoidCallback onMore;
  final ValueChanged<ConsumerSearchTopicResult> onTopic;
  final ValueChanged<ConsumerSearchPlayResult> onPlay;

  @override
  Widget build(BuildContext context) {
    final copy = _SearchCopy.of(context);
    if (items.isEmpty && !loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                failed ? Icons.wifi_off_rounded : Icons.search_off_rounded,
                size: 34,
              ),
              const SizedBox(height: 10),
              Text(failed ? copy.tryAgain : copy.noMatches),
              if (failed)
                TextButton(onPressed: onRetry, child: Text(copy.retry)),
            ],
          ),
        ),
      );
    }

    final extra = (failed ? 1 : 0) + (hasMore ? 1 : 0);
    return ListView.separated(
      padding: const EdgeInsetsDirectional.fromSTEB(18, 6, 18, 24),
      itemCount: items.length + extra,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index < items.length) {
          final item = items[index];
          return switch (item) {
            ConsumerSearchTopicResult() => ListTile(
              key: ValueKey<String>('search-topic:${item.topicId}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tag_rounded),
              title: Text(item.label),
              subtitle: Text(
                intent == ConsumerSearchIntent.learning
                    ? copy.learn
                    : copy.explore,
              ),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
              onTap: () => onTopic(item),
            ),
            ConsumerSearchPlayResult() => ListTile(
              key: ValueKey<String>(
                'search-play:${item.playId}:${item.revisionId}',
              ),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.play_circle_outline_rounded),
              title: Text(_playLabel(item.play, intent)),
              subtitle: Text(copy.play),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
              onTap: () => onPlay(item),
            ),
          };
        }
        final tail = index - items.length;
        if (failed && tail == 0) {
          return TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(copy.retry),
          );
        }
        return TextButton(
          key: const ValueKey<String>('search-more'),
          onPressed: loadingMore ? null : onMore,
          child: loadingMore
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(copy.more),
        );
      },
    );
  }
}

String _playLabel(PlayDocument play, ConsumerSearchIntent intent) {
  final preferred = intent == ConsumerSearchIntent.learning
      ? play.learningTopics
      : play.topics;
  final fallback = intent == ConsumerSearchIntent.learning
      ? play.topics
      : play.learningTopics;
  final topic = preferred.isNotEmpty
      ? preferred.first
      : fallback.isNotEmpty
      ? fallback.first
      : null;
  final format = _titleCase(play.format.name.replaceAll('_', ' '));
  return topic == null ? format : '$format · ${_topicLabel(topic)}';
}

String _topicLabel(String value) =>
    _titleCase(value.replaceAll(RegExp(r'[_-]+'), ' '));

String _titleCase(String value) => value
    .split(RegExp(r'\s+'))
    .where((part) => part.isNotEmpty)
    .map((part) => '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}')
    .join(' ');

String _normalizedInput(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

String _resultIdentity(ConsumerSearchResult result) => switch (result) {
  ConsumerSearchTopicResult() => 'topic:${result.topicId}',
  ConsumerSearchPlayResult() => 'play:${result.playId}:${result.revisionId}',
};

final class _SearchCopy {
  const _SearchCopy({required this.spanish});

  final bool spanish;

  static _SearchCopy of(BuildContext context) => _SearchCopy(
    spanish: Localizations.localeOf(context).languageCode == 'es',
  );

  String get search => spanish ? 'Buscar' : 'Search';
  String get explore => spanish ? 'Explorar' : 'Explore';
  String get learn => spanish ? 'Aprender' : 'Learn';
  String get topics => spanish ? 'Temas' : 'Topics';
  String get play => 'Play';
  String get close => spanish ? 'Cerrar' : 'Close';
  String get retry => spanish ? 'Reintentar' : 'Retry';
  String get tryAgain => spanish ? 'Inténtalo de nuevo' : 'Try again';
  String get noMatches => spanish ? 'Sin resultados' : 'No matches';
  String get more => spanish ? 'Más' : 'More';
}
