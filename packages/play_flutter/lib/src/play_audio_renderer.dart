import 'dart:async';

import 'package:flutter/material.dart';
import 'package:platform_contracts/platform_contracts.dart';

String _requireAudioText(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}

final class PlayAudioAsset {
  PlayAudioAsset({
    required String id,
    required Uri uri,
    String? semanticLabel,
  }) : id = _requireAudioText(id, 'id'),
       uri = _validateAudioUri(uri),
       semanticLabel = semanticLabel == null
           ? null
           : _requireAudioText(semanticLabel, 'semanticLabel');

  final String id;
  final Uri uri;
  final String? semanticLabel;
}

Uri _validateAudioUri(Uri uri) {
  if (!uri.isAbsolute || uri.scheme != 'https' || uri.host.isEmpty) {
    throw ArgumentError.value(
      uri,
      'uri',
      'Play audio requires an absolute HTTPS URI.',
    );
  }
  return uri;
}

abstract interface class PlayAudioAssetResolver {
  Future<PlayAudioAsset?> resolve(String assetId);
}

typedef PlayAudioLookup = FutureOr<PlayAudioAsset?> Function(String assetId);

final class CallbackPlayAudioAssetResolver implements PlayAudioAssetResolver {
  const CallbackPlayAudioAssetResolver(this.lookup);

  final PlayAudioLookup lookup;

  @override
  Future<PlayAudioAsset?> resolve(String assetId) =>
      Future<PlayAudioAsset?>.sync(() => lookup(assetId));
}

final class MapPlayAudioAssetResolver implements PlayAudioAssetResolver {
  MapPlayAudioAssetResolver(Map<String, PlayAudioAsset> assets)
    : _assets = Map<String, PlayAudioAsset>.unmodifiable(assets);

  final Map<String, PlayAudioAsset> _assets;

  @override
  Future<PlayAudioAsset?> resolve(String assetId) async => _assets[assetId];
}

typedef PlayAudioErrorCallback =
    void Function(PlayAudioAsset asset, Object error, StackTrace stackTrace);

final class ResolvedPlayAudio extends StatefulWidget {
  const ResolvedPlayAudio({
    required this.ownerId,
    required this.assetId,
    required this.resolver,
    required this.engine,
    required this.coordinator,
    this.active = true,
    this.onError,
    super.key,
  });

  final String ownerId;
  final String assetId;
  final PlayAudioAssetResolver resolver;
  final AudioEngine engine;
  final ActiveMediaCoordinator coordinator;
  final bool active;
  final PlayAudioErrorCallback? onError;

  @override
  State<ResolvedPlayAudio> createState() => _ResolvedPlayAudioState();
}

final class _ResolvedPlayAudioState extends State<ResolvedPlayAudio> {
  late Future<PlayAudioAsset?> _resolution;

  @override
  void initState() {
    super.initState();
    _resolution = _resolve();
  }

  @override
  void didUpdateWidget(covariant ResolvedPlayAudio oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId != widget.assetId ||
        oldWidget.resolver != widget.resolver) {
      _resolution = _resolve();
    }
  }

  Future<PlayAudioAsset?> _resolve() async {
    final id = widget.assetId.trim();
    if (id.isEmpty) return null;
    final asset = await widget.resolver.resolve(id);
    if (asset != null && asset.id != id) {
      throw StateError('Resolver returned ${asset.id} while resolving $id.');
    }
    return asset;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlayAudioAsset?>(
    future: _resolution,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const _AudioState(label: 'Loading audio');
      }
      final asset = snapshot.data;
      if (snapshot.hasError || asset == null) {
        return const PlayAudioUnavailable();
      }
      return OwnedPlayAudio(
        ownerId: widget.ownerId,
        asset: asset,
        engine: widget.engine,
        coordinator: widget.coordinator,
        active: widget.active,
        onError: widget.onError,
      );
    },
  );
}

/// User-initiated audio surface backed by the shared single-media coordinator.
///
/// Audio is deliberately loaded lazily on the first user gesture. Mounting a
/// feed item never allocates an audio resource or starts audible playback.
/// Foreground resume also never autoplays; the user must tap Hear/Replay again.
final class OwnedPlayAudio extends StatefulWidget {
  const OwnedPlayAudio({
    required this.ownerId,
    required this.asset,
    required this.engine,
    required this.coordinator,
    this.active = true,
    this.onError,
    super.key,
  });

  final String ownerId;
  final PlayAudioAsset asset;
  final AudioEngine engine;
  final ActiveMediaCoordinator coordinator;
  final bool active;
  final PlayAudioErrorCallback? onError;

  @override
  State<OwnedPlayAudio> createState() => _OwnedPlayAudioState();
}

final class _OwnedPlayAudioState extends State<OwnedPlayAudio> {
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  _AudioMediaHandle? _handle;
  ActiveMediaCoordinator? _handleCoordinator;
  String? _handleOwnerId;
  bool _loading = false;
  bool _played = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scheduleReconcile();
  }

  @override
  void didUpdateWidget(covariant OwnedPlayAudio oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ownerId != widget.ownerId ||
        !identical(oldWidget.asset, widget.asset) ||
        !identical(oldWidget.engine, widget.engine) ||
        !identical(oldWidget.coordinator, widget.coordinator) ||
        oldWidget.active != widget.active) {
      _scheduleReconcile();
    }
  }

  @override
  void dispose() {
    _generation += 1;
    final cleanup = _tail.then((_) => _releaseCurrent());
    _tail = cleanup.then<void>(
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
        _publishFailure(generation, error);
        _reportError(widget.asset, error, stackTrace);
      },
    );
  }

  void _schedulePlay() {
    final generation = _generation;
    final operation = _tail.then((_) => _play(generation));
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _publishFailure(generation, error);
        _reportError(widget.asset, error, stackTrace);
      },
    );
  }

  Future<void> _reconcile(int generation) async {
    await _releaseCurrent();
    if (!_isCurrent(generation) || !widget.active) {
      _publishIdle(generation);
      return;
    }
    _publishIdle(generation);
  }

  Future<_AudioMediaHandle?> _loadHandle(int generation) async {
    final asset = widget.asset;
    final engine = widget.engine;
    final coordinator = widget.coordinator;
    final ownerId = _requireAudioText(widget.ownerId, 'ownerId');

    try {
      await engine.load(asset.id, asset.uri);
    } on Object catch (error, stackTrace) {
      try {
        await engine.release(asset.id);
      } on Object catch (cleanupError, cleanupStackTrace) {
        _reportError(asset, cleanupError, cleanupStackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    final handle = _AudioMediaHandle(engine, asset.id);
    if (!_isCurrent(generation) || !widget.active) {
      await handle.release();
      return null;
    }

    _handle = handle;
    _handleCoordinator = coordinator;
    _handleOwnerId = ownerId;
    return handle;
  }

  Future<void> _play(int generation) async {
    if (!_isCurrent(generation) || !widget.active) return;
    _publishLoading(generation);

    try {
      var handle = _handle;
      if (handle == null || handle.released) {
        handle = await _loadHandle(generation);
        if (handle == null) return;
      }

      final coordinator = _handleCoordinator;
      final ownerId = _handleOwnerId;
      if (coordinator == null || ownerId == null) {
        throw StateError('Audio handle lost its media ownership context.');
      }

      await coordinator.activate(ownerId, handle);
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return;
      }

      await handle.engine.play(handle.assetId);
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return;
      }

      _publishPlayed(generation);
    } on Object catch (error, stackTrace) {
      try {
        await _releaseCurrent();
      } on Object catch (cleanupError, cleanupStackTrace) {
        _reportError(widget.asset, cleanupError, cleanupStackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _releaseCurrent() async {
    final handle = _handle;
    if (handle == null) return;
    final coordinator = _handleCoordinator;
    final ownerId = _handleOwnerId;

    if (coordinator != null &&
        ownerId != null &&
        coordinator.owns(ownerId, handle)) {
      await coordinator.release(ownerId, expectedHandle: handle);
      _clearHandle(handle);
      return;
    }

    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await handle.pause();
    } on Object catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await handle.release();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    if (handle.released) {
      _clearHandle(handle);
    }
    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStackTrace ?? StackTrace.current);
    }
  }

  void _clearHandle(_AudioMediaHandle handle) {
    if (!identical(_handle, handle)) return;
    _handle = null;
    _handleCoordinator = null;
    _handleOwnerId = null;
    _loading = false;
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  void _publishLoading(int generation) {
    if (!_isCurrent(generation)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
  }

  void _publishPlayed(int generation) {
    if (!_isCurrent(generation)) return;
    setState(() {
      _loading = false;
      _played = true;
      _error = null;
    });
  }

  void _publishIdle(int generation) {
    if (!_isCurrent(generation)) return;
    setState(() {
      _loading = false;
      _played = false;
      _error = null;
    });
  }

  void _publishFailure(int generation, Object error) {
    if (!_isCurrent(generation)) return;
    setState(() {
      _loading = false;
      _error = error;
    });
  }

  void _reportError(
    PlayAudioAsset asset,
    Object error,
    StackTrace stackTrace,
  ) {
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
    if (_error != null) return const PlayAudioUnavailable();
    if (_loading) return const _AudioState(label: 'Loading audio');

    final semanticLabel = widget.asset.semanticLabel ?? 'Hear audio';
    return Center(
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: FilledButton.tonalIcon(
          onPressed: _schedulePlay,
          icon: Icon(_played ? Icons.replay_rounded : Icons.volume_up_rounded),
          label: Text(_played ? 'Replay' : 'Hear'),
        ),
      ),
    );
  }
}

final class _AudioMediaHandle implements ManagedMediaHandle {
  _AudioMediaHandle(this.engine, this.assetId);

  final AudioEngine engine;
  final String assetId;
  bool released = false;

  @override
  Future<void> pause() async {
    if (released) return;
    await engine.stop(assetId);
  }

  @override
  Future<void> release() async {
    if (released) return;
    await engine.release(assetId);
    released = true;
  }
}

final class PlayAudioUnavailable extends StatelessWidget {
  const PlayAudioUnavailable({super.key});

  @override
  Widget build(BuildContext context) => const _AudioState(
    label: 'Audio unavailable',
    icon: Icons.volume_off_outlined,
  );
}

final class _AudioState extends StatelessWidget {
  const _AudioState({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Semantics(
      label: label,
      child: Center(
        child: ExcludeSemantics(
          child: icon == null
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon),
        ),
      ),
    ),
  );
}
