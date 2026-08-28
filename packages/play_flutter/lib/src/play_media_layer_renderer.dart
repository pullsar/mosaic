import 'dart:async';

import 'package:flutter/material.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_schema/play_schema.dart';

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

final class ResolvedPlayVideo extends StatefulWidget {
  const ResolvedPlayVideo({
    required this.ownerId,
    required this.assetId,
    required this.resolver,
    required this.coordinator,
    required this.controllerFactory,
    this.active = true,
    this.semanticResumeEpoch = 0,
    this.loadingBuilder,
    this.errorBuilder,
    this.onError,
    super.key,
  });

  final String ownerId;
  final String assetId;
  final PlayVideoAssetResolver resolver;
  final ActiveMediaCoordinator coordinator;
  final PlayVideoControllerFactory controllerFactory;
  final bool active;
  final int semanticResumeEpoch;
  final PlayVideoStateBuilder? loadingBuilder;
  final PlayVideoStateBuilder? errorBuilder;
  final PlayVideoErrorCallback? onError;

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
      return OwnedPlayVideo(
        ownerId: widget.ownerId,
        asset: asset,
        coordinator: widget.coordinator,
        controllerFactory: widget.controllerFactory,
        active: widget.active,
        semanticResumeEpoch: widget.semanticResumeEpoch,
        loadingBuilder: widget.loadingBuilder,
        errorBuilder: widget.errorBuilder,
        onError: widget.onError,
      );
    },
  );
}

typedef UnsupportedPlayMediaBuilder =
    Widget Function(BuildContext context, PresentationLayer layer);

/// Turns a declarative media [PresentationLayer] into its explicit renderer.
///
/// Only media types with production adapters are routed. Audio, canvas and
/// future media primitives remain visible as unsupported instead of being
/// guessed into an unrelated renderer.
final class PlayMediaLayerBuilder {
  const PlayMediaLayerBuilder({
    required this.ownerId,
    required this.visualResolver,
    required this.videoResolver,
    required this.mediaCoordinator,
    required this.videoControllerFactory,
    this.active = true,
    this.semanticResumeEpoch = 0,
    this.unsupportedBuilder,
  });

  final String ownerId;
  final PlayVisualAssetResolver visualResolver;
  final PlayVideoAssetResolver videoResolver;
  final ActiveMediaCoordinator mediaCoordinator;
  final PlayVideoControllerFactory videoControllerFactory;
  final bool active;
  final int semanticResumeEpoch;
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
        coordinator: mediaCoordinator,
        controllerFactory: videoControllerFactory,
        active: active,
        semanticResumeEpoch: semanticResumeEpoch,
      ),
      _ => _unsupported(context, layer),
    };
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
          child: ExcludeSemantics(
            child: Icon(Icons.hide_image_outlined),
          ),
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
