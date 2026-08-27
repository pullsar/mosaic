from __future__ import annotations

import re
import sys
from pathlib import Path


ASSET_CLASS = '''final class PlayVisualAsset {
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
}'''

PREFETCH = r'''typedef PlayVisualWarmCallback =
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
/// cancel an image decode already inside an image provider, so an active
/// predecessor is allowed to finish while retaining its operation permit; the
/// successor waits instead of exceeding [maxConcurrent]. Stale generations
/// cannot start additional work or affect current-window accounting.
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
            if (isCurrent()) cancel();
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
          warmed += 1;
        } finally {
          _releaseOperationPermit();
        }
      }
    }

    final workerCount = queue.length < maxConcurrent
        ? queue.length
        : maxConcurrent;
    await Future.wait(List<Future<void>>.generate(workerCount, (_) => worker()));

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

  void _reportError(
    String assetId,
    Object error,
    StackTrace stackTrace,
  ) {
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
      Error.throwWithStackTrace(
        error,
        failureStackTrace ?? StackTrace.current,
      );
    }
  }
}

'''


def replace_exact(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected one {label}, found {count}")
    return text.replace(old, new, 1)


def patch(root: Path) -> None:
    source_path = root / "packages/play_flutter/lib/src/play_visual_renderer.dart"
    text = source_path.read_text(encoding="utf-8")
    if "final class CachingPlayVisualAssetResolver" not in text:
        raise SystemExit("The bounded resolver cache tranche is missing")
    if "final class PlayVisualMediaBuilder<" not in text:
        raise SystemExit("The reusable layer-binding tranche is missing")

    if "int? cacheWidth" not in text:
        pattern = re.compile(r"final class PlayVisualAsset \{.*?\n\}", re.DOTALL)
        match = pattern.search(text)
        if match is None:
            raise SystemExit("PlayVisualAsset class was not found")
        text = text[: match.start()] + ASSET_CLASS + text[match.end() :]

    if "final class PlayVisualPrefetchController" not in text:
        marker = "typedef PlayVisualStateBuilder ="
        text = replace_exact(text, marker, PREFETCH + marker, "prefetch insertion marker")

    text = text.replace(
        "image: asset.source.createImageProvider(),",
        "image: asset.createImageProvider(),",
    )
    if "image: asset.source.createImageProvider()," in text:
        raise SystemExit("PlayVisualImage still bypasses decode hints")

    if "this.repaintBoundaryKey," not in text:
        text = replace_exact(
            text,
            "    this.useRepaintBoundary = true,\n",
            "    this.useRepaintBoundary = true,\n    this.repaintBoundaryKey,\n",
            "media-builder constructor boundary option",
        )
        text = replace_exact(
            text,
            "  final bool useRepaintBoundary;\n",
            "  final bool useRepaintBoundary;\n  final Key? repaintBoundaryKey;\n",
            "media-builder boundary field",
        )
        text = replace_exact(
            text,
            "? RepaintBoundary(child: visual)\n",
            "? RepaintBoundary(key: repaintBoundaryKey, child: visual)\n",
            "media-builder boundary construction",
        )

    if "int? _validateOptionalDimension" not in text:
        marker = "String? _normalizeOptional(String? value) {"
        helper = '''int? _validateOptionalDimension(int? value, String name) {
  if (value != null && value < 1) {
    throw RangeError.range(value, 1, null, name);
  }
  return value;
}

'''
        text = replace_exact(text, marker, helper + marker, "dimension helper marker")

    source_path.write_text(text, encoding="utf-8")

    binding_test = root / "packages/play_flutter/test/play_visual_media_builder_test.dart"
    if binding_test.exists():
        test = binding_test.read_text(encoding="utf-8")
        if "visual-boundary" not in test:
            test = replace_exact(
                test,
                """                assetIdOf: (layer) => layer.assetId,
              );""",
                """                assetIdOf: (layer) => layer.assetId,
                repaintBoundaryKey: const ValueKey('visual-boundary'),
              );""",
                "first media-builder test setup",
            )
            test = replace_exact(
                test,
                """              expect(
                find.ancestor(
                  of: find.byType(ResolvedPlayVisual),
                  matching: find.byType(RepaintBoundary),
                ),
                findsWidgets,
              );""",
                "              expect(find.byKey(const ValueKey('visual-boundary')), findsOneWidget);",
                "explicit repaint-boundary assertion",
            )
        if "disabled-boundary" not in test:
            test = replace_exact(
                test,
                """                assetIdOf: (layer) => layer.assetId,
                useRepaintBoundary: false,
              );""",
                """                assetIdOf: (layer) => layer.assetId,
                useRepaintBoundary: false,
                repaintBoundaryKey: const ValueKey('disabled-boundary'),
              );""",
                "disabled boundary test setup",
            )
            test = replace_exact(
                test,
                """              expect(
                find.ancestor(
                  of: unavailable,
                  matching: find.byType(RepaintBoundary),
                ),
                findsNothing,
              );""",
                "              expect(find.byKey(const ValueKey('disabled-boundary')), findsNothing);",
                "disabled repaint-boundary assertion",
            )
        binding_test.write_text(test, encoding="utf-8")

    progress = root / "docs/progress/2026-08-27-m06-play-renderer-progress.md"
    progress_text = progress.read_text(encoding="utf-8")
    if "## Decode and prefetch budget" not in progress_text:
        progress_text += '''

## Decode and prefetch budget

Visual assets can now carry positive decode-size hints, applied consistently to display and prefetch providers. A globally bounded prefetch controller deduplicates and caps each feed window, limits concurrent resolution/decode operations even across superseding windows, reports missing/failing assets, and prevents stale generations from starting successor work or changing current-window accounting.
'''
    progress.write_text(progress_text, encoding="utf-8")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: renderer_prefetch_patch_v2.py <repository-root>")
    patch(Path(sys.argv[1]).resolve())
