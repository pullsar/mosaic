import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:play_schema/play_schema.dart';

import 'game_attempt_controller.dart';

typedef NextGameRound = Future<PlayDocument?> Function(PlayDocument current);
typedef ContinuousGameBuilder =
    Widget Function(
      BuildContext context,
      GameAttemptController attempt,
      Widget? feedback,
    );

/// One active round, one prepared successor, and one cancellable result beat.
/// Published documents and the deterministic engine remain unchanged.
final class ContinuousGameHost extends StatefulWidget {
  const ContinuousGameHost({
    required this.play,
    required this.active,
    required this.builder,
    this.prepareNext,
    this.effectsEnabled = false,
    super.key,
  });

  final PlayDocument play;
  final bool active;
  final bool effectsEnabled;
  final NextGameRound? prepareNext;
  final ContinuousGameBuilder builder;

  @override
  State<ContinuousGameHost> createState() => _ContinuousGameHostState();
}

final class _ContinuousGameHostState extends State<ContinuousGameHost>
    with WidgetsBindingObserver {
  late GameAttemptController _attempt;
  final _seen = <String>{};
  PlayDocument? _next;
  Timer? _beat;
  int _epoch = 0;
  bool _loading = false;
  bool _requested = false;
  bool _foreground = true;
  bool _routeActive = true;
  bool _beatElapsed = false;
  bool _paused = false;
  bool _resolved = false;
  bool _accessible = false;
  bool _continueRequested = false;

  bool get _active => widget.active && _foreground && _routeActive;
  bool get _continuous =>
      _attempt.session.play.gameFamily != null && widget.prepareNext != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _createAttempt();
  }

  void _createAttempt() {
    _attempt = GameAttemptController(play: widget.play)..addListener(_changed);
    _seen.add(widget.play.id);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeActive =
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        TickerMode.valuesOf(context).enabled;
    _accessible = MediaQuery.maybeOf(context)?.accessibleNavigation ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(ContinuousGameHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.play.id != widget.play.id ||
        oldWidget.play.revisionId != widget.play.revisionId) {
      _cancel();
      _attempt.dispose();
      _seen.clear();
      _resolved = false;
      _paused = false;
      _beatElapsed = false;
      _createAttempt();
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
    if (mounted) setState(() {});
  }

  void _cancel() {
    _epoch++;
    _beat?.cancel();
    _beat = null;
    _next = null;
    _loading = false;
    _requested = false;
    _continueRequested = false;
  }

  void _sync() {
    if (!_active) {
      _cancel();
      // Returning to a result never unexpectedly starts the next task.
      if (_resolved) _paused = true;
      return;
    }
    if (_continuous && !_requested) unawaited(_prepare());
    if (_resolved &&
        !_paused &&
        !_accessible &&
        _beat == null &&
        !_beatElapsed) {
      _beat = Timer(
        Duration(
          milliseconds: _attempt.lastResolution?.wasCorrect == false
              ? 1600
              : 1000,
        ),
        () {
          _beat = null;
          if (!mounted || !_active) return;
          setState(() => _beatElapsed = true);
          _advanceIfReady();
        },
      );
    }
  }

  Future<void> _prepare() async {
    _requested = true;
    _loading = true;
    final epoch = _epoch;
    final current = _attempt.session.play;
    PlayDocument? next;
    try {
      next = await widget.prepareNext?.call(current);
    } on Object {
      next = null;
    }
    if (!mounted || epoch != _epoch || !_active) return;
    // Fence malformed providers as well as responses from an obsolete round.
    if (next?.id == current.id ||
        next?.gameFamily?.id != current.gameFamily?.id ||
        next?.gameFamily?.revisionId != current.gameFamily?.revisionId)
      next = null;
    setState(() {
      _next = next;
      _loading = false;
    });
    _advanceIfReady();
  }

  void _changed() {
    final resolved = _attempt.roundResolved;
    if (resolved && !_resolved) {
      _resolved = true;
      if (_active && _attempt.lastResolution?.wasCorrect != null) {
        unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
        if (widget.effectsEnabled) {
          unawaited(
            SystemSound.play(SystemSoundType.click).catchError((Object _) {}),
          );
        }
      }
    }
    if (mounted) setState(() {});
    _sync();
  }

  void _advanceIfReady() {
    if (_resolved &&
        _active &&
        _next != null &&
        (_continueRequested || (_beatElapsed && !_paused && !_accessible))) {
      _advance();
    }
  }

  void _advance() {
    final next = _next;
    if (next == null || !_active) return;
    _cancel();
    _resolved = false;
    _beatElapsed = false;
    final familiar = _seen.contains(next.id);
    // Session history is bounded; it is not a persisted ability score.
    if (!familiar && _seen.length == 64) _seen.remove(_seen.first);
    _seen.add(next.id);
    _attempt.advanceTo(next, familiar: familiar);
  }

  void _continue() {
    _paused = false;
    _continueRequested = true;
    if (_next != null) {
      _advance();
      return;
    }
    _beatElapsed = true;
    if (!_loading) unawaited(_prepare());
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel();
    _attempt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feedback = !_resolved || !_continuous
        ? null
        : _RoundFeedback(
            correct: _attempt.lastResolution?.wasCorrect,
            score: _attempt.correctRounds,
            rounds: _attempt.roundsCompleted,
            showNext: _paused || _accessible || (_beatElapsed && _next == null),
            loading: _loading,
            onNext: _continue,
            onPause: () => setState(() {
              _paused = true;
              _beat?.cancel();
              _beat = null;
            }),
          );
    return widget.builder(context, _attempt, feedback);
  }
}

final class _RoundFeedback extends StatelessWidget {
  const _RoundFeedback({
    required this.correct,
    required this.score,
    required this.rounds,
    required this.showNext,
    required this.loading,
    required this.onNext,
    required this.onPause,
  });
  final bool? correct;
  final int score;
  final int rounds;
  final bool showNext;
  final bool loading;
  final VoidCallback onNext;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Semantics(
      liveRegion: true,
      label: correct == null ? 'Round complete' : '$score of $rounds solved',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: reduced ? 1 : .85, end: 1),
              duration: Duration(milliseconds: reduced ? 0 : 300),
              curve: Curves.easeOutBack,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      correct == true
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        correct == null ? 'Complete' : '$score / $rounds',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 20),
          if (showNext)
            Flexible(
              child: TextButton(
                onPressed: loading ? null : onNext,
                child: Text(loading ? 'Preparing…' : 'Next round'),
              ),
            )
          else
            IconButton(
              tooltip: 'Pause',
              onPressed: onPause,
              icon: const Icon(Icons.pause_rounded),
            ),
        ],
      ),
    );
  }
}
