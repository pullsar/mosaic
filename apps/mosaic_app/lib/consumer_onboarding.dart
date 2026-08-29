import 'dart:async';

import 'package:flutter/material.dart';
import 'package:play_flutter/play_flutter.dart';

import 'consumer_api_client.dart';
import 'consumer_runtime.dart';
import 'onboarding_localizations.dart';

final class ConsumerOnboardingGate extends StatefulWidget {
  const ConsumerOnboardingGate({
    required this.runtime,
    required this.child,
    super.key,
  });

  final ConsumerRuntime runtime;
  final Widget child;

  @override
  State<ConsumerOnboardingGate> createState() => _ConsumerOnboardingGateState();
}

final class _ConsumerOnboardingGateState extends State<ConsumerOnboardingGate>
    with WidgetsBindingObserver {
  bool? _completed;
  bool _reconcilePending = false;
  bool _reconciling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    final completed = await widget.runtime.readOnboardingCompleted();
    if (!mounted) return;
    setState(() {
      _completed = completed;
      _reconcilePending = completed;
    });
    if (completed) unawaited(_reconcile());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _completed == true &&
        _reconcilePending) {
      unawaited(_reconcile());
    }
  }

  Future<void> _reconcile() async {
    if (_reconciling || !_reconcilePending) return;
    _reconciling = true;
    final result = await widget.runtime.syncLocalPreferences();
    if (!mounted) return;
    _reconciling = false;
    _reconcilePending =
        !result.localPersisted ||
        result.remoteFailure == ConsumerApiFailureKind.retryable;
  }

  void _onFinished() {
    setState(() {
      _completed = true;
      _reconcilePending = true;
    });
    unawaited(_reconcile());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return switch (_completed) {
      null => const _OnboardingBootSurface(),
      false => ConsumerOnboarding(
        runtime: widget.runtime,
        onFinished: _onFinished,
      ),
      true => widget.child,
    };
  }
}

final class ConsumerOnboarding extends StatefulWidget {
  const ConsumerOnboarding({
    required this.runtime,
    required this.onFinished,
    this.preferenceSyncDebounce = const Duration(milliseconds: 420),
    this.topicSearchDebounce = const Duration(milliseconds: 220),
    super.key,
  });

  final ConsumerRuntime runtime;
  final VoidCallback onFinished;
  final Duration preferenceSyncDebounce;
  final Duration topicSearchDebounce;

  @override
  State<ConsumerOnboarding> createState() => _ConsumerOnboardingState();
}

enum _OnboardingStep { interests, learning }

final class _ConsumerOnboardingState extends State<ConsumerOnboarding>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  Future<void> _localWriteTail = Future<void>.value();
  ConsumerPreferences _preferences = ConsumerPreferences();
  ConsumerPreferences _lastPersisted = ConsumerPreferences();
  ConsumerPreferences? _remotePending;
  List<ConsumerTopic> _topics = const [];
  _OnboardingStep _step = _OnboardingStep.interests;
  Timer? _searchTimer;
  Timer? _syncTimer;
  var _searchEpoch = 0;
  var _initialized = false;
  var _topicsLoading = false;
  var _topicsFailed = false;
  var _saveFailed = false;
  var _navigationBusy = false;
  var _remoteSyncInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    ConsumerPreferences preferences;
    try {
      preferences = await widget.runtime.readPreferences();
    } on Object {
      preferences = ConsumerPreferences();
    }
    if (!mounted) return;
    setState(() {
      _preferences = preferences;
      _lastPersisted = preferences;
      _remotePending = preferences;
      _initialized = true;
    });
    unawaited(_performTopicSearch(''));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _remotePending != null) {
      unawaited(_flushRemoteSync());
    }
  }

  void _onSearchChanged(String value) {
    _searchTimer?.cancel();
    _searchTimer = Timer(
      widget.topicSearchDebounce,
      () => unawaited(_performTopicSearch(value)),
    );
  }

  Future<void> _performTopicSearch(String query) async {
    final epoch = ++_searchEpoch;
    if (mounted) {
      setState(() {
        _topicsLoading = true;
        _topicsFailed = false;
      });
    }
    final result = await widget.runtime.searchTopics(query: query, limit: 100);
    if (!mounted || epoch != _searchEpoch) return;
    switch (result) {
      case ConsumerApiSuccess<List<ConsumerTopic>>():
        setState(() {
          _topics = result.value;
          _topicsLoading = false;
          _topicsFailed = false;
        });
      case ConsumerApiFailure<List<ConsumerTopic>>():
        setState(() {
          _topicsLoading = false;
          _topicsFailed = true;
        });
    }
  }

  void _toggleTopic(ConsumerTopic topic) {
    final current = _step == _OnboardingStep.interests
        ? _preferences.interestTopicIds
        : _preferences.learningTopicIds;
    final selected = current.toSet();
    if (!selected.add(topic.id)) selected.remove(topic.id);
    final next = _step == _OnboardingStep.interests
        ? ConsumerPreferences(
            interestTopicIds: selected.toList(growable: false),
            learningTopicIds: _preferences.learningTopicIds,
          )
        : ConsumerPreferences(
            interestTopicIds: _preferences.interestTopicIds,
            learningTopicIds: selected.toList(growable: false),
          );
    setState(() {
      _preferences = next;
      _saveFailed = false;
    });
    unawaited(_queueLocalPersistence(next));
  }

  Future<bool> _queueLocalPersistence(ConsumerPreferences snapshot) {
    final completer = Completer<bool>();
    _localWriteTail = _localWriteTail.then((_) async {
      final persisted = await widget.runtime.persistPreferencesLocally(
        snapshot,
      );
      if (persisted) {
        _lastPersisted = snapshot;
        _scheduleRemoteSync(snapshot);
      } else if (mounted && _samePreferences(_preferences, snapshot)) {
        setState(() => _saveFailed = true);
      }
      completer.complete(persisted);
    });
    return completer.future;
  }

  Future<bool> _ensureCurrentPersisted() async {
    await _localWriteTail;
    if (_samePreferences(_lastPersisted, _preferences)) return true;
    return _queueLocalPersistence(_preferences);
  }

  void _scheduleRemoteSync(ConsumerPreferences snapshot) {
    _remotePending = snapshot;
    _syncTimer?.cancel();
    _syncTimer = Timer(
      widget.preferenceSyncDebounce,
      () => unawaited(_flushRemoteSync()),
    );
  }

  Future<void> _flushRemoteSync() async {
    if (_remoteSyncInFlight) return;
    final snapshot = _remotePending;
    if (snapshot == null) return;
    _remotePending = null;
    _remoteSyncInFlight = true;
    final result = await widget.runtime.syncPreferences(snapshot);
    _remoteSyncInFlight = false;
    if (!result.synced &&
        result.remoteFailure == ConsumerApiFailureKind.retryable &&
        _remotePending == null) {
      _remotePending = snapshot;
    }
    if (_remotePending != null && result.synced) {
      _syncTimer?.cancel();
      _syncTimer = Timer(
        widget.preferenceSyncDebounce,
        () => unawaited(_flushRemoteSync()),
      );
    }
  }

  Future<void> _continueFromInterests({required bool surprise}) async {
    if (_navigationBusy) return;
    _navigationBusy = true;
    if (surprise) {
      final cleared = ConsumerPreferences(
        interestTopicIds: const [],
        learningTopicIds: _preferences.learningTopicIds,
      );
      setState(() => _preferences = cleared);
    }
    final persisted = await _ensureCurrentPersisted();
    if (!mounted) return;
    _navigationBusy = false;
    if (!persisted) {
      setState(() => _saveFailed = true);
      return;
    }
    _moveToStep(_OnboardingStep.learning);
  }

  Future<void> _finish({required bool skipLearning}) async {
    if (_navigationBusy) return;
    _navigationBusy = true;
    if (skipLearning) {
      final cleared = ConsumerPreferences(
        interestTopicIds: _preferences.interestTopicIds,
        learningTopicIds: const [],
      );
      setState(() => _preferences = cleared);
    }
    final persisted = await _ensureCurrentPersisted();
    if (!persisted) {
      if (mounted) {
        _navigationBusy = false;
        setState(() => _saveFailed = true);
      }
      return;
    }
    final completionPersisted = await widget.runtime.writeOnboardingCompleted(
      true,
    );
    if (!mounted) return;
    _navigationBusy = false;
    if (!completionPersisted) {
      setState(() => _saveFailed = true);
      return;
    }
    unawaited(_flushRemoteSync());
    widget.onFinished();
  }

  void _moveToStep(_OnboardingStep step) {
    _searchTimer?.cancel();
    _searchController.clear();
    setState(() {
      _step = step;
      _topicsFailed = false;
    });
    unawaited(_performTopicSearch(''));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchTimer?.cancel();
    _syncTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) return const _OnboardingBootSurface();
    final strings = MosaicOnboardingStrings.of(context);
    final selectedIds =
        (_step == _OnboardingStep.interests
                ? _preferences.interestTopicIds
                : _preferences.learningTopicIds)
            .toSet();
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _OnboardingHeader(
              step: _step,
              searchController: _searchController,
              onSearchChanged: _onSearchChanged,
            ),
            Expanded(
              child: _TopicBody(
                topics: _topics,
                selectedIds: selectedIds,
                loading: _topicsLoading,
                failed: _topicsFailed,
                hasQuery: _searchController.text.trim().isNotEmpty,
                onRetry: () =>
                    unawaited(_performTopicSearch(_searchController.text)),
                onToggle: _toggleTopic,
              ),
            ),
            if (_saveFailed)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(20, 6, 20, 0),
                  child: Text(
                    strings.saveFailed,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            _OnboardingFooter(
              step: _step,
              busy: _navigationBusy,
              onBack: () => _moveToStep(_OnboardingStep.interests),
              onSurprise: () =>
                  unawaited(_continueFromInterests(surprise: true)),
              onContinueInterests: () =>
                  unawaited(_continueFromInterests(surprise: false)),
              onSkipLearning: () => unawaited(_finish(skipLearning: true)),
              onFinish: () => unawaited(_finish(skipLearning: false)),
            ),
          ],
        ),
      ),
    );
  }
}

final class _OnboardingHeader extends StatelessWidget {
  const _OnboardingHeader({
    required this.step,
    required this.searchController,
    required this.onSearchChanged,
  });

  final _OnboardingStep step;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    final strings = MosaicOnboardingStrings.of(context);
    final prompt = step == _OnboardingStep.interests
        ? strings.interestsPrompt
        : strings.learningPrompt;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _StepDot(active: step == _OnboardingStep.interests),
              const SizedBox(width: 6),
              _StepDot(active: step == _OnboardingStep.learning),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            prompt,
            key: ValueKey<String>('onboarding-prompt-${step.name}'),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.06,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: searchController,
            onChanged: onSearchChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: strings.searchHint,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: strings.clearSearch,
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged('');
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.onSurface.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark
                    ? 0.07
                    : 0.05,
              ),
              contentPadding: const EdgeInsetsDirectional.symmetric(
                horizontal: 16,
                vertical: 15,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _StepDot extends StatelessWidget {
  const _StepDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : MosaicVisualTokens.fastFeedback,
    width: active ? 24 : 7,
    height: 7,
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.onSurface.withValues(alpha: active ? 0.9 : 0.25),
      borderRadius: BorderRadius.circular(99),
    ),
  );
}

final class _TopicBody extends StatelessWidget {
  const _TopicBody({
    required this.topics,
    required this.selectedIds,
    required this.loading,
    required this.failed,
    required this.hasQuery,
    required this.onRetry,
    required this.onToggle,
  });

  final List<ConsumerTopic> topics;
  final Set<String> selectedIds;
  final bool loading;
  final bool failed;
  final bool hasQuery;
  final VoidCallback onRetry;
  final ValueChanged<ConsumerTopic> onToggle;

  @override
  Widget build(BuildContext context) {
    final strings = MosaicOnboardingStrings.of(context);
    if (failed && topics.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.cloud_off_rounded,
                size: 30,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 10),
              Text(strings.noTopics),
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: Text(strings.retry)),
            ],
          ),
        ),
      );
    }
    if (!loading && topics.isEmpty && hasQuery) {
      return Center(child: Text(strings.noMatches));
    }
    if (loading && topics.isEmpty) {
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final columns = constraints.maxWidth >= 720
            ? 4
            : constraints.maxWidth >= 520
            ? 3
            : 2;
        final available = constraints.maxWidth - 40 - (gap * (columns - 1));
        final tileWidth = available / columns;
        return Scrollbar(
          child: SingleChildScrollView(
            key: const ValueKey<String>('onboarding-topic-scroll'),
            padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 18),
            child: Align(
              alignment: AlignmentDirectional.topStart,
              child: Wrap(
                spacing: gap,
                runSpacing: gap,
                children: <Widget>[
                  for (final topic in topics)
                    SizedBox(
                      width: tileWidth,
                      child: _TopicTile(
                        topic: topic,
                        selected: selectedIds.contains(topic.id),
                        onTap: () => onToggle(topic),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

final class _TopicTile extends StatelessWidget {
  const _TopicTile({
    required this.topic,
    required this.selected,
    required this.onTap,
  });

  final ConsumerTopic topic;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final strings = MosaicOnboardingStrings.of(context);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final selectedFill = colors.onSurface.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.12 : 0.07,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: selected
          ? strings.selectedTopic(topic.label)
          : strings.unselectedTopic(topic.label),
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('topic-${topic.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: reducedMotion
                ? Duration.zero
                : MosaicVisualTokens.fastFeedback,
            constraints: const BoxConstraints(minHeight: 104),
            padding: const EdgeInsetsDirectional.fromSTEB(16, 15, 12, 14),
            decoration: BoxDecoration(
              color: selected ? selectedFill : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                width: selected ? 1.5 : 1,
                color: colors.onSurface.withValues(
                  alpha: selected ? 0.78 : 0.16,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Icon(
                      _topicIcon(topic.label),
                      size: 28,
                      color: colors.onSurface.withValues(alpha: 0.9),
                    ),
                    AnimatedSwitcher(
                      duration: reducedMotion
                          ? Duration.zero
                          : MosaicVisualTokens.fastFeedback,
                      child: selected
                          ? Icon(
                              Icons.check_circle_rounded,
                              key: const ValueKey<String>('selected'),
                              size: 20,
                              color: colors.onSurface,
                            )
                          : const SizedBox.square(
                              key: ValueKey<String>('unselected'),
                              dimension: 20,
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  topic.label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    height: 1.12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _OnboardingFooter extends StatelessWidget {
  const _OnboardingFooter({
    required this.step,
    required this.busy,
    required this.onBack,
    required this.onSurprise,
    required this.onContinueInterests,
    required this.onSkipLearning,
    required this.onFinish,
  });

  final _OnboardingStep step;
  final bool busy;
  final VoidCallback onBack;
  final VoidCallback onSurprise;
  final VoidCallback onContinueInterests;
  final VoidCallback onSkipLearning;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final strings = MosaicOnboardingStrings.of(context);
    final border = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.1);
    final primaryStyle = FilledButton.styleFrom(
      minimumSize: const Size(122, 52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: border)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 20, 14),
        child: step == _OnboardingStep.interests
            ? Row(
                children: <Widget>[
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        onPressed: busy ? null : onSurprise,
                        child: Text(strings.surpriseMe),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    key: const ValueKey<String>('interests-continue'),
                    onPressed: busy ? null : onContinueInterests,
                    style: primaryStyle,
                    child: Text(strings.continueLabel),
                  ),
                ],
              )
            : Row(
                children: <Widget>[
                  IconButton(
                    key: const ValueKey<String>('learning-back'),
                    tooltip: strings.back,
                    onPressed: busy ? null : onBack,
                    icon: const BackButtonIcon(),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: busy ? null : onSkipLearning,
                    child: Text(strings.skip),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey<String>('learning-continue'),
                    onPressed: busy ? null : onFinish,
                    style: primaryStyle,
                    child: Text(strings.continueLabel),
                  ),
                ],
              ),
      ),
    );
  }
}

final class _OnboardingBootSurface extends StatelessWidget {
  const _OnboardingBootSurface();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).brightness == Brightness.dark
        ? MosaicVisualTokens.surface
        : Theme.of(context).colorScheme.surface,
    child: const Center(
      child: SizedBox.square(
        dimension: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

bool _samePreferences(ConsumerPreferences a, ConsumerPreferences b) =>
    _sameStringSet(a.interestTopicIds, b.interestTopicIds) &&
    _sameStringSet(a.learningTopicIds, b.learningTopicIds);

bool _sameStringSet(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  final values = a.toSet();
  return b.every(values.contains);
}

IconData _topicIcon(String label) {
  final normalized = label.toLowerCase();
  if (normalized.contains('history') || normalized.contains('heritage')) {
    return Icons.account_balance_rounded;
  }
  if (normalized.contains('science') || normalized.contains('nature')) {
    return Icons.science_rounded;
  }
  if (normalized.contains('tech') || normalized.contains('comput')) {
    return Icons.memory_rounded;
  }
  if (normalized.contains('health') || normalized.contains('wellness')) {
    return Icons.monitor_heart_rounded;
  }
  if (normalized.contains('money') ||
      normalized.contains('finance') ||
      normalized.contains('economic')) {
    return Icons.show_chart_rounded;
  }
  if (normalized.contains('psych') || normalized.contains('philos')) {
    return Icons.psychology_rounded;
  }
  if (normalized.contains('art') || normalized.contains('design')) {
    return Icons.palette_rounded;
  }
  if (normalized.contains('music') || normalized.contains('audio')) {
    return Icons.music_note_rounded;
  }
  if (normalized.contains('travel') ||
      normalized.contains('world') ||
      normalized.contains('geo')) {
    return Icons.public_rounded;
  }
  if (normalized.contains('food') || normalized.contains('cuisine')) {
    return Icons.restaurant_rounded;
  }
  if (normalized.contains('sport') || normalized.contains('fitness')) {
    return Icons.directions_run_rounded;
  }
  if (normalized.contains('politic') || normalized.contains('policy')) {
    return Icons.how_to_vote_rounded;
  }
  if (normalized.contains('law') || normalized.contains('justice')) {
    return Icons.balance_rounded;
  }
  if (normalized.contains('engineer') || normalized.contains('build')) {
    return Icons.engineering_rounded;
  }
  if (normalized.contains('data') || normalized.contains(' ai')) {
    return Icons.hub_rounded;
  }
  if (normalized.contains('climate') || normalized.contains('environment')) {
    return Icons.eco_rounded;
  }
  if (normalized.contains('language') || normalized.contains('literature')) {
    return Icons.translate_rounded;
  }
  if (normalized.contains('religion') || normalized.contains('faith')) {
    return Icons.auto_awesome_rounded;
  }
  if (normalized.contains('game')) return Icons.sports_esports_rounded;
  return Icons.grid_view_rounded;
}
