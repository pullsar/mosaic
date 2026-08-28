import 'dart:async';

import 'package:flutter/material.dart';
import 'package:platform_contracts/platform_contracts.dart';

String _requireVideoText(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}

String? _normalizeVideoText(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

sealed class PlayVideoSource {
  const PlayVideoSource();
}

final class NetworkPlayVideoSource extends PlayVideoSource {
  NetworkPlayVideoSource(Uri uri, {Map<String, String>? headers})
    : uri = _validateUri(uri),
      headers = headers == null
          ? null
          : Map<String, String>.unmodifiable(headers);

  final Uri uri;
  final Map<String, String>? headers;

  static Uri _validateUri(Uri uri) {
    if (!uri.isAbsolute || uri.scheme != 'https' || uri.host.isEmpty) {
      throw ArgumentError.value(
        uri,
        'uri',
        'Play videos require an absolute HTTPS URI.',
      );
    }
    return uri;
  }
}

final class BundlePlayVideoSource extends PlayVideoSource {
  BundlePlayVideoSource(String assetName)
    : assetName = _requireVideoText(assetName, 'assetName');

  final String assetName;
}

/// Optional delivery metadata used to correlate playback outcomes with the
/// derivative that was selected for the current client.
final class PlayVideoFormatMetadata {
  PlayVideoFormatMetadata({
    String? container,
    String? videoCodec,
    String? videoProfile,
    String? audioCodec,
  }) : container = _normalizeVideoText(container),
       videoCodec = _normalizeVideoText(videoCodec),
       videoProfile = _normalizeVideoText(videoProfile),
       audioCodec = _normalizeVideoText(audioCodec) {
    if (this.container == null &&
        this.videoCodec == null &&
        this.videoProfile == null &&
        this.audioCodec == null) {
      throw ArgumentError('Video format metadata must contain at least one value.');
    }
  }

  final String? container;
  final String? videoCodec;
  final String? videoProfile;
  final String? audioCodec;
}

final class PlayVideoAsset {
  PlayVideoAsset({
    required String id,
    required this.source,
    String? semanticLabel,
    this.autoplay = true,
    this.muted = true,
    this.format,
  }) : id = _requireVideoText(id, 'id'),
       semanticLabel = _normalizeVideoText(semanticLabel);

  final String id;
  final PlayVideoSource source;
  final String? semanticLabel;
  final bool autoplay;

  /// Autoplay is permitted only through an explicitly muted controller state.
  final bool muted;
  final PlayVideoFormatMetadata? format;
}

/// Typed adapter signal for a web/media stack that rejected a playback call.
///
/// During autoplay this is recoverable: Mosaic keeps the initialized controller
/// and exposes a direct user play action instead of converting a browser policy
/// decision into a broken Play. User-initiated failures remain retryable.
final class PlayVideoPlaybackRejected implements Exception {
  const PlayVideoPlaybackRejected(this.cause);

  final Object cause;

  @override
  String toString() => 'PlayVideoPlaybackRejected: $cause';
}

enum PlayVideoPlaybackPhase {
  initialized,
  autoplayStarted,
  autoplayBlocked,
  userPlaybackStarted,
  firstFramePainted,
  playbackError,
}

final class PlayVideoPlaybackEvent {
  const PlayVideoPlaybackEvent({
    required this.assetId,
    required this.phase,
    required this.sourceType,
    this.elapsed,
    this.format,
    this.error,
  });

  final String assetId;
  final PlayVideoPlaybackPhase phase;
  final String sourceType;
  final Duration? elapsed;
  final PlayVideoFormatMetadata? format;
  final Object? error;
}

typedef PlayVideoPlaybackObserver = void Function(PlayVideoPlaybackEvent event);

/// Provider-neutral native video controller owned by one visible Play.
///
/// Implementations adapt the selected native/player plugin. Controllers are
/// intentionally ephemeral and must never be serialized into local state.
abstract interface class PlayVideoController implements ManagedMediaHandle {
  Future<void> initialize();
  Future<void> setMuted(bool muted);
  Future<void> play();
  Widget buildView(BuildContext context);
}

typedef PlayVideoControllerFactory =
    PlayVideoController Function(PlayVideoAsset asset);
typedef PlayVideoStateBuilder =
    Widget Function(BuildContext context, PlayVideoAsset asset);
typedef PlayVideoErrorCallback =
    void Function(PlayVideoAsset asset, Object error, StackTrace stackTrace);

/// Owns an ephemeral native video controller only while this Play is active.
///
/// Reconfiguration is serialized. An older initialization must finish cleanup
/// before a successor can acquire native media ownership, and every release is
/// fenced by the exact controller handle so a stale widget cannot dispose a
/// replacement that reused the same semantic owner ID.
final class OwnedPlayVideo extends StatefulWidget {
  const OwnedPlayVideo({
    required this.ownerId,
    required this.asset,
    required this.coordinator,
    required this.controllerFactory,
    this.active = true,
    this.semanticResumeEpoch = 0,
    this.loadingBuilder,
    this.errorBuilder,
    this.onError,
    this.onPlaybackEvent,
    this.useRepaintBoundary = true,
    super.key,
  });

  final String ownerId;
  final PlayVideoAsset asset;
  final ActiveMediaCoordinator coordinator;
  final PlayVideoControllerFactory controllerFactory;
  final bool active;

  /// Increment when semantic Play state is restored after foreground resume.
  /// A controller is resumed only when it still owns the exact native handle
  /// and had already entered playback before suspension.
  final int semanticResumeEpoch;
  final PlayVideoStateBuilder? loadingBuilder;
  final PlayVideoStateBuilder? errorBuilder;
  final PlayVideoErrorCallback? onError;
  final PlayVideoPlaybackObserver? onPlaybackEvent;
  final bool useRepaintBoundary;

  @override
  State<OwnedPlayVideo> createState() => _OwnedPlayVideoState();
}

final class _OwnedPlayVideoState extends State<OwnedPlayVideo> {
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  PlayVideoController? _controller;
  ActiveMediaCoordinator? _controllerCoordinator;
  String? _controllerOwnerId;
  bool _ready = false;
  bool _resumeEligible = false;
  bool _awaitingUserPlay = false;
  bool _userPlayInFlight = false;
  bool _retryUserPlay = false;
  int? _firstFrameGeneration;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scheduleReconcile();
  }

  @override
  void didUpdateWidget(covariant OwnedPlayVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    final configurationChanged =
        oldWidget.ownerId != widget.ownerId ||
        !identical(oldWidget.asset, widget.asset) ||
        !identical(oldWidget.coordinator, widget.coordinator) ||
        oldWidget.active != widget.active;
    if (configurationChanged) {
      _scheduleReconcile();
    } else if (oldWidget.semanticResumeEpoch != widget.semanticResumeEpoch) {
      _scheduleSemanticResume();
    }
  }

  @override
  void dispose() {
    _generation += 1;
    final release = _tail.then((_) => _releaseCurrent());
    _tail = release.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _reportError(widget.asset, error, stackTrace);
      },
    );
    super.dispose();
  }

  void _scheduleReconcile() {
    final generation = ++_generation;
    final operation = _tail.then((_) => _reconcile(generation));
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _reportError(widget.asset, error, stackTrace);
      },
    );
  }

  void _scheduleSemanticResume() {
    final generation = _generation;
    final operation = _tail.then((_) => _resume(generation));
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _publishFailure(generation, error);
        _reportPlaybackError(widget.asset, error, stackTrace);
      },
    );
  }

  void _scheduleUserPlay() {
    if (_userPlayInFlight) return;
    final generation = _generation;
    final operation = _tail.then((_) => _playFromUser(generation));
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _reportPlaybackError(widget.asset, error, stackTrace);
      },
    );
  }

  Future<void> _reconcile(int generation) async {
    try {
      await _releaseCurrent();
    } on Object catch (error, stackTrace) {
      _publishFailure(generation, error);
      _reportError(widget.asset, error, stackTrace);
      return;
    }

    if (!_isCurrent(generation) || !widget.active) {
      _publishIdle(generation);
      return;
    }

    final ownerId = _requireVideoText(widget.ownerId, 'ownerId');
    final asset = widget.asset;
    final coordinator = widget.coordinator;
    final startup = Stopwatch()..start();
    PlayVideoController? controller;

    _publishLoading(generation);
    try {
      controller = widget.controllerFactory(asset);
      _controller = controller;
      _controllerCoordinator = coordinator;
      _controllerOwnerId = ownerId;
      _resumeEligible = false;
      _awaitingUserPlay = false;
      _retryUserPlay = false;
      _firstFrameGeneration = null;

      await controller.initialize();
      _emitPlaybackEvent(
        asset,
        PlayVideoPlaybackPhase.initialized,
        elapsed: startup.elapsed,
      );
      await controller.setMuted(asset.muted);
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return;
      }

      await coordinator.activate(ownerId, controller);
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return;
      }

      if (asset.autoplay) {
        if (!asset.muted) {
          throw StateError('Audible video autoplay is not permitted.');
        }
        try {
          await controller.play();
          _resumeEligible = true;
          _emitPlaybackEvent(
            asset,
            PlayVideoPlaybackPhase.autoplayStarted,
            elapsed: startup.elapsed,
          );
        } on PlayVideoPlaybackRejected catch (error) {
          _resumeEligible = false;
          _awaitingUserPlay = true;
          _retryUserPlay = false;
          _emitPlaybackEvent(
            asset,
            PlayVideoPlaybackPhase.autoplayBlocked,
            elapsed: startup.elapsed,
            error: error.cause,
          );
        }
      } else {
        _awaitingUserPlay = true;
      }
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return;
      }

      _publishReady(generation);
      _scheduleFirstFrame(generation, startup);
    } on Object catch (error, stackTrace) {
      try {
        await _releaseCurrent();
      } on Object catch (cleanupError, cleanupStackTrace) {
        _reportError(asset, cleanupError, cleanupStackTrace);
      }
      _publishFailure(generation, error);
      _reportPlaybackError(asset, error, stackTrace);
    }
  }

  Future<void> _playFromUser(int generation) async {
    if (!_isCurrent(generation) || !widget.active || !_ready) return;
    final controller = _controller;
    final coordinator = _controllerCoordinator;
    final ownerId = _controllerOwnerId;
    if (controller == null || coordinator == null || ownerId == null) return;
    if (!coordinator.owns(ownerId, controller)) return;

    _publishUserPlayInFlight(generation, true);
    try {
      await controller.play();
      if (!_isCurrent(generation) ||
          !widget.active ||
          !coordinator.owns(ownerId, controller)) {
        return;
      }
      _resumeEligible = true;
      _awaitingUserPlay = false;
      _retryUserPlay = false;
      _emitPlaybackEvent(
        widget.asset,
        PlayVideoPlaybackPhase.userPlaybackStarted,
      );
    } on Object catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _resumeEligible = false;
        _awaitingUserPlay = true;
        _retryUserPlay = true;
      }
      _reportPlaybackError(widget.asset, error, stackTrace);
    } finally {
      _publishUserPlayInFlight(generation, false);
    }
  }

  Future<void> _resume(int generation) async {
    if (!_isCurrent(generation) ||
        !widget.active ||
        !_ready ||
        !_resumeEligible) {
      return;
    }
    final controller = _controller;
    final coordinator = _controllerCoordinator;
    final ownerId = _controllerOwnerId;
    if (controller == null || coordinator == null || ownerId == null) return;
    if (!coordinator.owns(ownerId, controller)) return;
    try {
      await controller.play();
    } on Object catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        _resumeEligible = false;
        _awaitingUserPlay = true;
        _retryUserPlay = true;
        _publishReady(generation);
      }
      _reportPlaybackError(widget.asset, error, stackTrace);
    }
  }

  Future<void> _releaseCurrent() async {
    final controller = _controller;
    if (controller == null) return;
    final coordinator = _controllerCoordinator;
    final ownerId = _controllerOwnerId;

    if (coordinator != null &&
        ownerId != null &&
        coordinator.owns(ownerId, controller)) {
      await coordinator.release(ownerId, expectedHandle: controller);
    } else {
      await controller.release();
    }

    if (identical(_controller, controller)) {
      _controller = null;
      _controllerCoordinator = null;
      _controllerOwnerId = null;
      _ready = false;
      _resumeEligible = false;
      _awaitingUserPlay = false;
      _userPlayInFlight = false;
      _retryUserPlay = false;
      _firstFrameGeneration = null;
    }
  }

  void _scheduleFirstFrame(int generation, Stopwatch startup) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrent(generation) ||
          !_ready ||
          _controller == null ||
          _firstFrameGeneration == generation) {
        return;
      }
      _firstFrameGeneration = generation;
      _emitPlaybackEvent(
        widget.asset,
        PlayVideoPlaybackPhase.firstFramePainted,
        elapsed: startup.elapsed,
      );
    });
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  void _publishLoading(int generation) {
    if (!_isCurrent(generation)) return;
    setState(() {
      _ready = false;
      _error = null;
    });
  }

  void _publishReady(int generation) {
    if (!_isCurrent(generation)) return;
    setState(() {
      _ready = true;
      _error = null;
    });
  }

  void _publishIdle(int generation) {
    if (!_isCurrent(generation)) return;
    setState(() {
      _ready = false;
      _error = null;
    });
  }

  void _publishFailure(int generation, Object error) {
    if (!_isCurrent(generation)) return;
    setState(() {
      _ready = false;
      _error = error;
    });
  }

  void _publishUserPlayInFlight(int generation, bool value) {
    if (!_isCurrent(generation) || _userPlayInFlight == value) return;
    setState(() => _userPlayInFlight = value);
  }

  void _reportPlaybackError(
    PlayVideoAsset asset,
    Object error,
    StackTrace stackTrace,
  ) {
    _emitPlaybackEvent(
      asset,
      PlayVideoPlaybackPhase.playbackError,
      error: error is PlayVideoPlaybackRejected ? error.cause : error,
    );
    _reportError(asset, error, stackTrace);
  }

  void _emitPlaybackEvent(
    PlayVideoAsset asset,
    PlayVideoPlaybackPhase phase, {
    Duration? elapsed,
    Object? error,
  }) {
    final observer = widget.onPlaybackEvent;
    if (observer == null) return;
    final sourceType = switch (asset.source) {
      NetworkPlayVideoSource() => 'network',
      BundlePlayVideoSource() => 'bundle',
    };
    try {
      observer(
        PlayVideoPlaybackEvent(
          assetId: asset.id,
          phase: phase,
          sourceType: sourceType,
          elapsed: elapsed,
          format: asset.format,
          error: error,
        ),
      );
    } on Object {
      // Telemetry observers cannot destabilize playback or media ownership.
    }
  }

  void _reportError(PlayVideoAsset asset, Object error, StackTrace stackTrace) {
    final callback = widget.onError;
    if (callback == null) return;
    try {
      callback(asset, error, stackTrace);
    } on Object {
      // Error observers cannot destabilize media ownership or rendering.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();

    final Widget content;
    final controller = _controller;
    if (_error != null) {
      content =
          widget.errorBuilder?.call(context, widget.asset) ??
          const PlayVideoUnavailable();
    } else if (!_ready || controller == null) {
      content =
          widget.loadingBuilder?.call(context, widget.asset) ??
          const _DefaultVideoLoading();
    } else {
      Widget view = controller.buildView(context);
      final semanticLabel = widget.asset.semanticLabel;
      if (semanticLabel != null) {
        view = Semantics(
          container: true,
          label: semanticLabel,
          excludeSemantics: true,
          child: view,
        );
      }
      content = _awaitingUserPlay
          ? Stack(
              fit: StackFit.expand,
              children: [
                view,
                Center(
                  child: _VideoPlayAction(
                    retry: _retryUserPlay,
                    busy: _userPlayInFlight,
                    onPressed: _scheduleUserPlay,
                  ),
                ),
              ],
            )
          : view;
    }

    return widget.useRepaintBoundary
        ? RepaintBoundary(child: content)
        : content;
  }
}

final class _VideoPlayAction extends StatelessWidget {
  const _VideoPlayAction({
    required this.retry,
    required this.busy,
    required this.onPressed,
  });

  final bool retry;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = retry ? 'Retry video' : 'Play video';
    return Semantics(
      button: true,
      label: label,
      enabled: !busy,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: 56,
          child: IconButton.filled(
            tooltip: label,
            onPressed: busy ? null : onPressed,
            icon: busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(retry ? Icons.replay_rounded : Icons.play_arrow_rounded),
          ),
        ),
      ),
    );
  }
}

final class PlayVideoUnavailable extends StatelessWidget {
  const PlayVideoUnavailable({super.key});

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Semantics(
      label: 'Video unavailable',
      child: const Center(
        child: ExcludeSemantics(child: Icon(Icons.videocam_off_outlined)),
      ),
    ),
  );
}

final class _DefaultVideoLoading extends StatelessWidget {
  const _DefaultVideoLoading();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Semantics(
      label: 'Loading video',
      child: const Center(
        child: ExcludeSemantics(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    ),
  );
}
