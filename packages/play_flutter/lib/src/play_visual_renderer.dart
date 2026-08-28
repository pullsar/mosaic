import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';

String _requireNonEmpty(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}

String? _normalizeOptional(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

int? _validateOptionalDimension(int? value, String name) {
  if (value != null && value < 1) {
    throw RangeError.range(value, 1, null, name);
  }
  return value;
}

sealed class PlayVisualSource {
  const PlayVisualSource();

  ImageProvider<Object> createImageProvider();
}

final class NetworkPlayVisualSource extends PlayVisualSource {
  NetworkPlayVisualSource(Uri uri, {Map<String, String>? headers})
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
        'Play visuals require an absolute HTTPS URI.',
      );
    }
    return uri;
  }

  @override
  ImageProvider<Object> createImageProvider() =>
      NetworkImage(uri.toString(), headers: headers);
}

final class MemoryPlayVisualSource extends PlayVisualSource {
  MemoryPlayVisualSource(Uint8List bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'Image bytes are empty.');
    }
  }

  final Uint8List bytes;

  @override
  ImageProvider<Object> createImageProvider() => MemoryImage(bytes);
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
    int? cacheWidth,
    int? cacheHeight,
  }) : id = _requireNonEmpty(id, 'id'),
       semanticLabel = _normalizeOptional(semanticLabel),
       cacheWidth = _validateOptionalDimension(cacheWidth, 'cacheWidth'),
       cacheHeight = _validateOptionalDimension(cacheHeight, 'cacheHeight');

  final String id;
  final PlayVisualSource source;
  final String? semanticLabel;
  final BoxFit fit;
  final Alignment alignment;
  final int? cacheWidth;
  final int? cacheHeight;

  ImageProvider<Object> createImageProvider() => ResizeImage.resizeIfNeeded(
    cacheWidth,
    cacheHeight,
    source.createImageProvider(),
  );
}

abstract interface class PlayVisualAssetResolver {
  Future<PlayVisualAsset?> resolve(String assetId);
}

typedef PlayVisualLookup = FutureOr<PlayVisualAsset?> Function(String assetId);

final class CallbackPlayVisualAssetResolver implements PlayVisualAssetResolver {
  const CallbackPlayVisualAssetResolver(this.lookup);

  final PlayVisualLookup lookup;

  @override
  Future<PlayVisualAsset?> resolve(String assetId) =>
      Future<PlayVisualAsset?>.sync(() => lookup(assetId));
}

final class MapPlayVisualAssetResolver implements PlayVisualAssetResolver {
  MapPlayVisualAssetResolver(Map<String, PlayVisualAsset> assets)
    : _assets = Map<String, PlayVisualAsset>.unmodifiable(assets);

  final Map<String, PlayVisualAsset> _assets;

  @override
  Future<PlayVisualAsset?> resolve(String assetId) async => _assets[assetId];
}

/// A bounded least-recently-used resolver that coalesces duplicate loads.
///
/// Missing assets are cached just like present assets, while failures are
/// never cached. Invalidation detaches an in-flight request so its eventual
/// completion cannot repopulate stale state.
final class CachingPlayVisualAssetResolver implements PlayVisualAssetResolver {
  CachingPlayVisualAssetResolver(this.delegate, {this.capacity = 32}) {
    if (capacity < 1) {
      throw RangeError.range(capacity, 1, null, 'capacity');
    }
  }

  final PlayVisualAssetResolver delegate;
  final int capacity;
  final LinkedHashMap<String, PlayVisualAsset?> _cache =
      LinkedHashMap<String, PlayVisualAsset?>();
  final Map<String, Future<PlayVisualAsset?>> _inFlight =
      <String, Future<PlayVisualAsset?>>{};
  final Map<String, int> _versions = <String, int>{};
  int _epoch = 0;

  int get cacheSize => _cache.length;
  int get inFlightCount => _inFlight.length;

  @override
  Future<PlayVisualAsset?> resolve(String assetId) {
    final id = _requireNonEmpty(assetId, 'assetId');
    if (_cache.containsKey(id)) {
      final cached = _cache.remove(id);
      _cache[id] = cached;
      return Future<PlayVisualAsset?>.value(cached);
    }

    final existing = _inFlight[id];
    if (existing != null) return existing;

    final epoch = _epoch;
    final version = _versions[id] ?? 0;
    late final Future<PlayVisualAsset?> request;
    request = Future<PlayVisualAsset?>.sync(() => delegate.resolve(id))
        .then((asset) {
          if (asset != null && asset.id != id) {
            throw StateError(
              'Resolver returned ${asset.id} while resolving $id.',
            );
          }
          if (_epoch == epoch && (_versions[id] ?? 0) == version) {
            _remember(id, asset);
          }
          return asset;
        })
        .whenComplete(() {
          if (identical(_inFlight[id], request)) {
            _detachInFlight(id);
          }
        });
    _inFlight[id] = request;
    return request;
  }

  void invalidate(String assetId) {
    final id = _requireNonEmpty(assetId, 'assetId');
    _cache.remove(id);
    _detachInFlight(id);
    _versions.update(id, (value) => value + 1, ifAbsent: () => 1);
  }

  void clear() {
    _cache.clear();
    _inFlight.clear();
    _versions.clear();
    _epoch += 1;
  }

  void _detachInFlight(String id) {
    final detached = _inFlight.remove(id);
    if (detached == null) return;
  }

  void _remember(String id, PlayVisualAsset? asset) {
    _cache.remove(id);
    _cache[id] = asset;
    while (_cache.length > capacity) {
      _cache.remove(_cache.keys.first);
    }
  }
}

typedef PlayVisualWarmCallback =
    Future<void> Function(BuildContext context, PlayVisualAsset asset);
typedef PlayVisualPrefetchErrorCallback =
    void Function(String assetId, Object error, StackTrace stackTrace);

final class PlayVisualPrefetchReport {
  const PlayVisualPrefetchReport({
    required this.requested,
    required this.warmed,
    required this.missing,
    required this.failed,
    required this.superseded,
  });

  final int requested;
  final int warmed;
  final int missing;
  final int failed;
  final bool superseded;

  int get completed => warmed + missing + failed;
}

/// Resolves and warms only a bounded, current feed window.
///
/// Starting a new window supersedes queued predecessor work. Flutter cannot
/// cancel a decode already inside an image provider, so an active predecessor
/// retains its operation permit until it completes. A successor waits rather
/// than exceeding [maxConcurrent].
final class PlayVisualPrefetchController {
  PlayVisualPrefetchController({
    required this.resolver,
    this.maxAssets = 4,
    this.maxConcurrent = 2,
    PlayVisualWarmCallback? warmer,
    this.onError,
  }) : _warmer = warmer ?? _precache {
    if (maxAssets < 1) {
      throw RangeError.range(maxAssets, 1, null, 'maxAssets');
    }
    if (maxConcurrent < 1) {
      throw RangeError.range(maxConcurrent, 1, null, 'maxConcurrent');
    }
  }

  final PlayVisualAssetResolver resolver;
  final int maxAssets;
  final int maxConcurrent;
  final PlayVisualWarmCallback _warmer;
  final PlayVisualPrefetchErrorCallback? onError;
  final Queue<Completer<void>> _permitWaiters = Queue<Completer<void>>();
  int _activeOperations = 0;
  int _generation = 0;

  int get activeOperations => _activeOperations;
  int get generation => _generation;

  void cancel() {
    _generation += 1;
    _wakePermitWaiters();
  }

  Future<PlayVisualPrefetchReport> prefetch(
    BuildContext context,
    Iterable<String> assetIds,
  ) async {
    final generation = ++_generation;
    _wakePermitWaiters();

    final unique = LinkedHashSet<String>();
    for (final rawId in assetIds) {
      final id = rawId.trim();
      if (id.isEmpty) continue;
      unique.add(id);
      if (unique.length == maxAssets) break;
    }

    final queue = unique.toList(growable: false);
    if (queue.isEmpty) {
      return const PlayVisualPrefetchReport(
        requested: 0,
        warmed: 0,
        missing: 0,
        failed: 0,
        superseded: false,
      );
    }

    var cursor = 0;
    var warmed = 0;
    var missing = 0;
    var failed = 0;

    bool isCurrent() => generation == _generation;

    Future<void> worker() async {
      while (isCurrent()) {
        if (!context.mounted) {
          cancel();
          return;
        }
        final index = cursor;
        if (index >= queue.length) return;
        cursor = index + 1;
        final id = queue[index];

        final acquired = await _acquireOperationPermit(generation);
        if (!acquired) return;
        try {
          PlayVisualAsset? asset;
          try {
            asset = await resolver.resolve(id);
          } on Object catch (error, stackTrace) {
            if (!isCurrent()) return;
            failed += 1;
            _reportError(id, error, stackTrace);
            continue;
          }

          if (!isCurrent()) return;
          if (asset == null) {
            missing += 1;
            continue;
          }
          if (!context.mounted) {
            cancel();
            return;
          }

          try {
            await _warmer(context, asset);
          } on Object catch (error, stackTrace) {
            if (!isCurrent()) return;
            failed += 1;
            _reportError(id, error, stackTrace);
            continue;
          }

          if (!isCurrent()) return;
          if (!context.mounted) {
            cancel();
            return;
          }
          warmed += 1;
        } finally {
          _releaseOperationPermit();
        }
      }
    }

    final workerCount = queue.length < maxConcurrent
        ? queue.length
        : maxConcurrent;
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );

    return PlayVisualPrefetchReport(
      requested: queue.length,
      warmed: warmed,
      missing: missing,
      failed: failed,
      superseded: !isCurrent(),
    );
  }

  Future<bool> _acquireOperationPermit(int generation) async {
    while (generation == _generation) {
      if (_activeOperations < maxConcurrent) {
        _activeOperations += 1;
        return true;
      }
      final waiter = Completer<void>();
      _permitWaiters.add(waiter);
      await waiter.future;
    }
    return false;
  }

  void _releaseOperationPermit() {
    if (_activeOperations < 1) {
      throw StateError('A visual prefetch permit was released twice.');
    }
    _activeOperations -= 1;
    _wakePermitWaiters();
  }

  void _wakePermitWaiters() {
    while (_permitWaiters.isNotEmpty) {
      final waiter = _permitWaiters.removeFirst();
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  void _reportError(String assetId, Object error, StackTrace stackTrace) {
    final callback = onError;
    if (callback == null) return;
    try {
      callback(assetId, error, stackTrace);
    } on Object {
      // Prefetch is best-effort; an observer cannot destabilize feed rendering.
    }
  }

  static Future<void> _precache(
    BuildContext context,
    PlayVisualAsset asset,
  ) async {
    Object? failure;
    StackTrace? failureStackTrace;
    await precacheImage(
      asset.createImageProvider(),
      context,
      onError: (error, stackTrace) {
        failure = error;
        failureStackTrace = stackTrace;
      },
    );
    final error = failure;
    if (error != null) {
      Error.throwWithStackTrace(error, failureStackTrace ?? StackTrace.current);
    }
  }
}

typedef PlayVisualStateBuilder =
    Widget Function(BuildContext context, String assetId);
typedef PlayVisualAssetIdSelector<T> = String? Function(T layer);
typedef PlayVisualLayerFallbackBuilder<T> =
    Widget Function(BuildContext context, T layer);

/// Adapts an arbitrary Play layer model to the resolved visual renderer.
final class PlayVisualMediaBuilder<T> {
  const PlayVisualMediaBuilder({
    required this.resolver,
    required this.assetIdOf,
    this.fallbackBuilder,
    this.loadingBuilder,
    this.errorBuilder,
    this.loadingSemanticLabel = 'Loading visual',
    this.unavailableSemanticLabel = 'Visual unavailable',
    this.useRepaintBoundary = true,
    this.repaintBoundaryKey,
  });

  final PlayVisualAssetResolver resolver;
  final PlayVisualAssetIdSelector<T> assetIdOf;
  final PlayVisualLayerFallbackBuilder<T>? fallbackBuilder;
  final PlayVisualStateBuilder? loadingBuilder;
  final PlayVisualStateBuilder? errorBuilder;
  final String loadingSemanticLabel;
  final String unavailableSemanticLabel;
  final bool useRepaintBoundary;
  final Key? repaintBoundaryKey;

  Widget call(BuildContext context, T layer) {
    final assetId = assetIdOf(layer)?.trim();
    final Widget visual;
    if (assetId == null || assetId.isEmpty) {
      visual =
          fallbackBuilder?.call(context, layer) ??
          PlayVisualUnavailable(semanticLabel: unavailableSemanticLabel);
    } else {
      visual = ResolvedPlayVisual(
        assetId: assetId,
        resolver: resolver,
        loadingBuilder: loadingBuilder,
        errorBuilder: errorBuilder,
        loadingSemanticLabel: loadingSemanticLabel,
        unavailableSemanticLabel: unavailableSemanticLabel,
      );
    }
    return useRepaintBoundary
        ? RepaintBoundary(key: repaintBoundaryKey, child: visual)
        : visual;
  }
}

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
      throw StateError('Resolver returned ${asset.id} while resolving $id.');
    }
    return asset;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlayVisualAsset?>(
    future: _resolution,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return widget.loadingBuilder?.call(context, widget.assetId) ??
            _DefaultVisualLoading(semanticLabel: widget.loadingSemanticLabel);
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
      image: asset.createImageProvider(),
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
      errorBuilder: (context, error, stackTrace) =>
          PlayVisualUnavailable(semanticLabel: unavailableSemanticLabel),
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
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Semantics(
      image: true,
      label: semanticLabel,
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
