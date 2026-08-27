import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

sealed class PlayVisualSource {
  const PlayVisualSource();

  ImageProvider<Object> createImageProvider();
}

final class NetworkPlayVisualSource extends PlayVisualSource {
  NetworkPlayVisualSource(Uri uri, {Map<String, String>? headers})
    : uri = _validateHttpsUri(uri),
      headers = headers == null
          ? null
          : Map<String, String>.unmodifiable(headers);

  final Uri uri;
  final Map<String, String>? headers;

  @override
  ImageProvider<Object> createImageProvider() =>
      NetworkImage(uri.toString(), headers: headers);
}

final class MemoryPlayVisualSource extends PlayVisualSource {
  MemoryPlayVisualSource(Uint8List bytes) : _bytes = _copyNonEmptyBytes(bytes);

  final Uint8List _bytes;

  @override
  ImageProvider<Object> createImageProvider() => MemoryImage(_bytes);
}

final class BundlePlayVisualSource extends PlayVisualSource {
  BundlePlayVisualSource(String assetName)
    : assetName = _requireNonEmpty(assetName, 'assetName');

  final String assetName;

  @override
  ImageProvider<Object> createImageProvider() => AssetImage(assetName);
}

final class PlayVisualAsset {
  PlayVisualAsset({
    required String id,
    required this.source,
    String? semanticLabel,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
  }) : id = _requireNonEmpty(id, 'id'),
       semanticLabel = _normalizeOptional(semanticLabel);

  final String id;
  final PlayVisualSource source;
  final String? semanticLabel;
  final BoxFit fit;
  final Alignment alignment;
}

abstract interface class PlayVisualAssetResolver {
  Future<PlayVisualAsset?> resolve(String assetId);
}

typedef PlayVisualLookup =
    FutureOr<PlayVisualAsset?> Function(String assetId);

final class CallbackPlayVisualAssetResolver
    implements PlayVisualAssetResolver {
  const CallbackPlayVisualAssetResolver(this.lookup);

  final PlayVisualLookup lookup;

  @override
  Future<PlayVisualAsset?> resolve(String assetId) =>
      Future<PlayVisualAsset?>.sync(() => lookup(assetId));
}

final class MapPlayVisualAssetResolver implements PlayVisualAssetResolver {
  MapPlayVisualAssetResolver(Map<String, PlayVisualAsset> assets)
    : _assets = _validateAssets(assets);

  final Map<String, PlayVisualAsset> _assets;

  @override
  Future<PlayVisualAsset?> resolve(String assetId) async => _assets[assetId];

  static Map<String, PlayVisualAsset> _validateAssets(
    Map<String, PlayVisualAsset> assets,
  ) {
    final copy = <String, PlayVisualAsset>{};
    for (final entry in assets.entries) {
      final key = _requireNonEmpty(entry.key, 'asset key');
      if (key != entry.value.id) {
        throw ArgumentError.value(
          entry.value.id,
          key,
          'The resolver key must match the visual asset ID.',
        );
      }
      copy[key] = entry.value;
    }
    return Map<String, PlayVisualAsset>.unmodifiable(copy);
  }
}

typedef PlayVisualStateBuilder =
    Widget Function(BuildContext context, String assetId);

final class ResolvedPlayVisual extends StatefulWidget {
  const ResolvedPlayVisual({
    required this.assetId,
    required this.resolver,
    this.loadingBuilder,
    this.errorBuilder,
    this.loadingSemanticLabel = 'Loading visual',
    this.unavailableSemanticLabel = 'Visual unavailable',
    super.key,
  });

  final String assetId;
  final PlayVisualAssetResolver resolver;
  final PlayVisualStateBuilder? loadingBuilder;
  final PlayVisualStateBuilder? errorBuilder;
  final String loadingSemanticLabel;
  final String unavailableSemanticLabel;

  @override
  State<ResolvedPlayVisual> createState() => _ResolvedPlayVisualState();
}

final class _ResolvedPlayVisualState extends State<ResolvedPlayVisual> {
  late Future<PlayVisualAsset?> _resolution;

  @override
  void initState() {
    super.initState();
    _resolution = _resolve();
  }

  @override
  void didUpdateWidget(covariant ResolvedPlayVisual oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId != widget.assetId ||
        oldWidget.resolver != widget.resolver) {
      _resolution = _resolve();
    }
  }

  Future<PlayVisualAsset?> _resolve() async {
    final id = widget.assetId.trim();
    if (id.isEmpty) return null;

    final asset = await widget.resolver.resolve(id);
    if (asset != null && asset.id != id) {
      throw StateError(
        'Resolver returned ${asset.id} while resolving $id.',
      );
    }
    return asset;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlayVisualAsset?>(
    future: _resolution,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return widget.loadingBuilder?.call(context, widget.assetId) ??
            _DefaultVisualLoading(
              semanticLabel: widget.loadingSemanticLabel,
            );
      }

      final asset = snapshot.data;
      if (snapshot.hasError || asset == null) {
        return widget.errorBuilder?.call(context, widget.assetId) ??
            PlayVisualUnavailable(
              semanticLabel: widget.unavailableSemanticLabel,
            );
      }

      return PlayVisualImage(
        asset: asset,
        unavailableSemanticLabel: widget.unavailableSemanticLabel,
      );
    },
  );
}

final class PlayVisualImage extends StatelessWidget {
  const PlayVisualImage({
    required this.asset,
    this.unavailableSemanticLabel = 'Visual unavailable',
    super.key,
  });

  final PlayVisualAsset asset;
  final String unavailableSemanticLabel;

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Image(
      image: asset.source.createImageProvider(),
      width: double.infinity,
      height: double.infinity,
      fit: asset.fit,
      alignment: asset.alignment,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      excludeFromSemantics: asset.semanticLabel == null,
      semanticLabel: asset.semanticLabel,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (disableAnimations || wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 160),
          child: child,
        );
      },
      errorBuilder: (context, error, stackTrace) => PlayVisualUnavailable(
        semanticLabel: unavailableSemanticLabel,
      ),
    );
  }
}

final class PlayVisualUnavailable extends StatelessWidget {
  const PlayVisualUnavailable({
    this.semanticLabel = 'Visual unavailable',
    super.key,
  });

  final String semanticLabel;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Semantics(
      image: true,
      label: semanticLabel,
      child: const Center(
        child: ExcludeSemantics(
          child: Icon(Icons.image_not_supported_outlined),
        ),
      ),
    ),
  );
}

final class _DefaultVisualLoading extends StatelessWidget {
  const _DefaultVisualLoading({required this.semanticLabel});

  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Semantics(
        image: true,
        label: semanticLabel,
        child: Center(
          child: ExcludeSemantics(
            child: disableAnimations
                ? const Icon(Icons.image_outlined)
                : const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
          ),
        ),
      ),
    );
  }
}

Uri _validateHttpsUri(Uri uri) {
  if (!uri.isAbsolute || uri.scheme != 'https' || uri.host.isEmpty) {
    throw ArgumentError.value(
      uri,
      'uri',
      'Play visuals require an absolute HTTPS URI.',
    );
  }
  return uri;
}

Uint8List _copyNonEmptyBytes(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw ArgumentError.value(bytes, 'bytes', 'Image bytes are empty.');
  }
  return Uint8List.fromList(bytes);
}

String _requireNonEmpty(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, '$name is empty.');
  }
  return normalized;
}

String? _normalizeOptional(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
