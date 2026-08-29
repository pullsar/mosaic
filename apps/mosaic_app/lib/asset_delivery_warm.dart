import 'dart:async';

import 'package:play_schema/play_schema.dart';

import 'asset_delivery_client.dart';

const defaultMaxWarmMetadataAssets = 12;
const defaultMaxWarmMetadataConcurrent = 3;

final class AssetWarmTarget {
  const AssetWarmTarget(this.assetId, {required this.canvas});

  final String assetId;
  final bool canvas;
}

final class AssetWarmPlan {
  const AssetWarmPlan({
    required this.visualAssetIds,
    required this.metadataTargets,
  });

  final List<String> visualAssetIds;
  final List<AssetWarmTarget> metadataTargets;
}

AssetWarmPlan buildAssetWarmPlan(
  Iterable<PlayDocument> plays, {
  int maxMetadataAssets = defaultMaxWarmMetadataAssets,
}) {
  if (maxMetadataAssets < 1 || maxMetadataAssets > 64) {
    throw RangeError.range(maxMetadataAssets, 1, 64, 'maxMetadataAssets');
  }
  final visualIds = <String>{};
  final metadataTargets = <AssetWarmTarget>[];
  final seenMetadata = <String>{};

  for (final play in plays) {
    for (final state in play.states.values) {
      for (final layer in state.presentation) {
        final assetId = layer.assetId?.trim();
        if (assetId == null || assetId.isEmpty) continue;
        switch (layer.type) {
          case 'image':
            visualIds.add(assetId);
            _addMetadataTarget(
              metadataTargets,
              seenMetadata,
              AssetWarmTarget(assetId, canvas: false),
              maxMetadataAssets,
            );
          case 'video_clip' || 'audio':
            _addMetadataTarget(
              metadataTargets,
              seenMetadata,
              AssetWarmTarget(assetId, canvas: false),
              maxMetadataAssets,
            );
          case 'canvas':
            _addMetadataTarget(
              metadataTargets,
              seenMetadata,
              AssetWarmTarget(assetId, canvas: true),
              maxMetadataAssets,
            );
        }
      }
    }
  }

  return AssetWarmPlan(
    visualAssetIds: List.unmodifiable(visualIds),
    metadataTargets: List.unmodifiable(metadataTargets),
  );
}

final class AssetMetadataWarmController {
  AssetMetadataWarmController({
    required this.client,
    this.maxConcurrent = defaultMaxWarmMetadataConcurrent,
    this.onError,
  }) {
    if (maxConcurrent < 1 || maxConcurrent > 8) {
      throw RangeError.range(maxConcurrent, 1, 8, 'maxConcurrent');
    }
  }

  final AssetDeliveryClient client;
  final int maxConcurrent;
  final void Function(String assetId, Object error, StackTrace stackTrace)?
  onError;
  int _generation = 0;

  Future<void> warm(AssetWarmPlan plan) async {
    final generation = ++_generation;
    final targets = plan.metadataTargets;
    if (targets.isEmpty) return;
    var nextIndex = 0;

    Future<void> worker() async {
      while (generation == _generation && nextIndex < targets.length) {
        final target = targets[nextIndex++];
        try {
          if (target.canvas) {
            await client.resolveCanvas(target.assetId);
          } else if (client.supportsBinaryNetworkAssets) {
            await client.describe(target.assetId);
          }
        } on Object catch (error, stackTrace) {
          if (generation != _generation) return;
          try {
            onError?.call(target.assetId, error, stackTrace);
          } on Object {
            // Observability must not turn warming into a feed failure mode.
          }
        }
      }
    }

    final workers = targets.length < maxConcurrent
        ? targets.length
        : maxConcurrent;
    await Future.wait<void>([
      for (var index = 0; index < workers; index += 1) worker(),
    ]);
  }

  void cancel() {
    _generation += 1;
  }
}

void _addMetadataTarget(
  List<AssetWarmTarget> targets,
  Set<String> seen,
  AssetWarmTarget target,
  int maximum,
) {
  if (targets.length >= maximum) return;
  final key = '${target.canvas ? 'canvas' : 'binary'}:${target.assetId}';
  if (seen.add(key)) targets.add(target);
}
