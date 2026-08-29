import 'dart:async';

import 'package:flutter/material.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_schema/play_schema.dart';

import 'play_audio_renderer.dart';
import 'play_canvas_renderer.dart';
import 'play_video_renderer.dart';
import 'play_visual_renderer.dart';

abstract interface class PlayVideoAssetResolver {
  Future<PlayVideoAsset?> resolve(String assetId);
}

typedef PlayVideoLookup = FutureOr<PlayVideoAsset?> Function(String assetId);

final class CallbackPlayVideoAssetResolver implements PlayVideoAssetResolver {
  const CallbackPlayVideoAssetResolver(this.lookup);

  final PlayVideoLookup lookup;

  @override
  Future<PlayVideoAsset?> resolve(String assetId) =>
      Future<PlayVideoAsset?>.sync(() => lookup(assetId));
}

final class MapPlayVideoAssetResolver implements PlayVideoAssetResolver {
  MapPlayVideoAssetResolver(Map<String, PlayVideoAsset> assets)
    : _assets = Map<String, PlayVideoAsset>.unmodifiable(assets);

  final Map<String, PlayVideoAsset> _assets;

  @override
  Future<PlayVideoAsset?> resolve(String assetId) async => _assets[assetId];
}

/// Resolves the managed poster selected for a video delivery.
///
/// The relation is keyed by the video asset ID because the server publication
/// gate already selects a poster derivative together with that asset. Keeping
/// the poster outside [PlayVideoAsset] avoids duplicating image loading/cache
/// semantics and lets delivery adapters resolve URLs independently.
abstract interface class PlayVideoPosterResolver {
  Future<PlayVisualAsset?> resolvePoster(String videoAssetId);
}

typedef PlayVideoPosterLookup =
    FutureOr<PlayVisualAsset?> Function(String videoAssetId);

final class CallbackPlayVideoPosterResolver implements PlayVideoPosterResolver {
  const CallbackPlayVideoPosterResolver(this.lookup);

  final PlayVideoPosterLookup lookup;

  @override
  Future<PlayVisualAsset?> resolvePoster(String videoAssetId) =>
      Future<PlayVisualAsset?>.sync(() => lookup(videoAssetId));
}

final class MapPlayVideoPosterResolver implements PlayVideoPosterResolver {
  MapPlayVideoPosterResolver(Map<String, PlayVisualAsset> postersByVideoAssetId)
    : _posters = Map<String, PlayVisualAsset>.unmodifiable(
        postersByVideoAssetId,
      );

  final Map<String, PlayVisualAsset> _posters;

  @override
  Future<PlayVisualAsset?> resolvePoster(String videoAssetId) async =>
      _posters[videoAssetId];
}

final class ResolvedPlayVideo extends StatefulWidget {
  const ResolvedPlayVideo({
    required this.ownerId,
    required this.assetId,
    required this.resolver,
    required this.coordinator,
    required this.controllerFactory,
    this.posterResolver,
    this.active = true,
    this.semanticResumeEpoch = 0,
    this.loadingBuilder,
    this.errorBuilder,
    this.onError,
    this.onPlaybackEvent,
    super.key,
  });

  final String ownerId;
  final String assetId;
  final PlayVideoAssetResolver resolver;
  final PlayVideoPosterResolver? posterResolver;
  final ActiveMediaCoordinator coordinator;
  final PlayVideoControllerFactory controllerFactory;
  final bool active;
  final int semanticResumeEpoch;
  final PlayVideoStateBuilder? loadingBuilder;
  final PlayVideoStateBuilder? errorBuilder;
  final PlayVideoErrorCallback? onError;
  final PlayVideoPlaybackObserver? onPlaybackEvent;

  @override
  State<ResolvedPlayVideo> createState() => _ResolvedPlayVideoState();
}

final class _ResolvedPlayVideoState extends State<ResolvedPlayVideo> {
  late Future<PlayVideoAsset?> _resolution;

  @override
  void initState() {
    super.initState();
    _resolution = _resolve();
  }

  @override
  void didUpdateWidget(covariant ResolvedPlayVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId != widget.assetId ||
        oldWidget.resolver != widget.resolver) {
      _resolution = _resolve();
    }
  }

  Future<PlayVideoAsset?> _resolve() async {
    final id = widget.assetId.trim();
    if (id.isEmpty) return null;
    final asset = await widget.resolver.resolve(id);
    if (asset != null && asset.id != id) {
      throw StateError('Resolver returned ${asset.id} while resolving $id.');
    }
    return asset;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlayVideoAsset?>(
    future: _resolution,
    builder: (context, snapshot) {
      final asset = snapshot.data;
      if (snapshot.connectionState != ConnectionState.done) {
        return const _VideoAssetLookupState(label: 'Loading video');
      }
      if (snapshot.hasError || asset == null) {
        return const PlayVideoUnavailable();
      }

      final posterResolver = widget.posterResolver;
      final loadingBuilder =
          widget.loadingBuilder ??
          (posterResolver == null
              ? null
              : (_, asset) => _ResolvedVideoPoster(
                  videoAssetId: asset.id,
                  resolver: posterResolver,
                  fallback: const _VideoAssetLookupState(
                    label: 'Loading video',
                  ),
                ));
      final errorBuilder =
          widget.errorBuilder ??
          (posterResolver == null
              ? null
              : (_, asset) => _ResolvedVideoPoster(
                  videoAssetId: asset.id,
                  resolver: posterResolver,
                  fallback: const PlayVideoUnavailable(),
                ));

      return OwnedPlayVideo(
        ownerId: widget.ownerId,
        asset: asset,
        coordinator: widget.coordinator,
        controllerFactory: widget.controllerFactory,
        active: widget.active,
        semanticResumeEpoch: widget.semanticResumeEpoch,
        loadingBuilder: loadingBuilder,
        errorBuilder: errorBuilder,
        onError: widget.onError,
        onPlaybackEvent: widget.onPlaybackEvent,
      );
    },
  );
}

final class _ResolvedVideoPoster extends StatefulWidget {
  const _ResolvedVideoPoster({
    required this.videoAssetId,
    required this.resolver,
    required this.fallback,
  });

  final String videoAssetId;
  final PlayVideoPosterResolver resolver;
  final Widget fallback;

  @override
  State<_ResolvedVideoPoster> createState() => _ResolvedVideoPosterState();
}

final class _ResolvedVideoPosterState extends State<_ResolvedVideoPoster> {
  late Future<PlayVisualAsset?> _resolution;

  @override
  void initState() {
    super.initState();
    _resolution = widget.resolver.resolvePoster(widget.videoAssetId);
  }

  @override
  void didUpdateWidget(covariant _ResolvedVideoPoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoAssetId != widget.videoAssetId ||
        oldWidget.resolver != widget.resolver) {
      _resolution = widget.resolver.resolvePoster(widget.videoAssetId);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlayVisualAsset?>(
    future: _resolution,
    builder: (context, snapshot) {
      final poster = snapshot.data;
      if (snapshot.connectionState != ConnectionState.done ||
          snapshot.hasError ||
          poster == null) {
        return widget.fallback;
      }
      return PlayVisualImage(
        asset: poster,
        unavailableSemanticLabel: 'Video poster unavailable',
      );
    },
  );
}

typedef UnsupportedPlayMediaBuilder =
    Widget Function(BuildContext context, PresentationLayer layer);

/// Turns a declarative media [PresentationLayer] into its explicit renderer.
///
/// Only media types with implemented adapters are routed. Missing adapter
/// dependencies and future primitives remain visible as unsupported instead of
/// being guessed into an unrelated renderer.
final class PlayMediaLayerBuilder {
  const PlayMediaLayerBuilder({
    required this.ownerId,
    required this.visualResolver,
    required this.videoResolver,
    required this.mediaCoordinator,
    required this.videoControllerFactory,
    this.videoPosterResolver,
    this.audioResolver,
    this.audioEngine,
    this.canvasResolver,
    this.active = true,
    this.semanticResumeEpoch = 0,
    this.onVideoPlaybackEvent,
    this.unsupportedBuilder,
  });

  final String ownerId;
  final PlayVisualAssetResolver visualResolver;
  final PlayVideoAssetResolver videoResolver;
  final PlayVideoPosterResolver? videoPosterResolver;
  final PlayAudioAssetResolver? audioResolver;
  final AudioEngine? audioEngine;
  final PlayCanvasAssetResolver? canvasResolver;
  final ActiveMediaCoordinator mediaCoordinator;
  final PlayVideoControllerFactory videoControllerFactory;
  final bool active;
  final int semanticResumeEpoch;
  final PlayVideoPlaybackObserver? onVideoPlaybackEvent;
  final UnsupportedPlayMediaBuilder? unsupportedBuilder;

  Widget call(BuildContext context, PresentationLayer layer) {
    final assetId = layer.assetId?.trim();
    if (assetId == null || assetId.isEmpty) {
      return _unsupported(context, layer);
    }

    return switch (layer.type) {
      'image' => ResolvedPlayVisual(assetId: assetId, resolver: visualResolver),
      'video_clip' => ResolvedPlayVideo(
        ownerId: ownerId,
        assetId: assetId,
        resolver: videoResolver,
        posterResolver: videoPosterResolver,
        coordinator: mediaCoordinator,
        controllerFactory: videoControllerFactory,
        active: active,
        semanticResumeEpoch: semanticResumeEpoch,
        onPlaybackEvent: onVideoPlaybackEvent,
      ),
      'audio' => _audio(context, layer, assetId),
      'canvas' => _canvas(context, layer, assetId),
      _ => _unsupported(context, layer),
    };
  }

  Widget _audio(BuildContext context, PresentationLayer layer, String assetId) {
    final resolver = audioResolver;
    final engine = audioEngine;
    return resolver == null || engine == null
        ? _unsupported(context, layer)
        : ResolvedPlayAudio(
            ownerId: ownerId,
            assetId: assetId,
            resolver: resolver,
            engine: engine,
            coordinator: mediaCoordinator,
            active: active,
          );
  }

  Widget _canvas(
    BuildContext context,
    PresentationLayer layer,
    String assetId,
  ) {
    final resolver = canvasResolver;
    return resolver == null
        ? _unsupported(context, layer)
        : ResolvedPlayCanvas(assetId: assetId, resolver: resolver);
  }

  Widget _unsupported(BuildContext context, PresentationLayer layer) =>
      unsupportedBuilder?.call(context, layer) ??
      PlayMediaUnavailable(type: layer.type);
}

final class PlayMediaUnavailable extends StatelessWidget {
  const PlayMediaUnavailable({required this.type, super.key});

  final String type;

  @override
  Widget build(BuildContext context) {
    final normalizedType = type.trim().isEmpty ? 'unknown' : type.trim();
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Semantics(
        image: true,
        label: 'Unsupported media: $normalizedType',
        child: const Center(
          child: ExcludeSemantics(child: Icon(Icons.hide_image_outlined)),
        ),
      ),
    );
  }
}

final class _VideoAssetLookupState extends StatelessWidget {
  const _VideoAssetLookupState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Semantics(
      image: true,
      label: label,
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
