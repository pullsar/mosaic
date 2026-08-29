import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mosaic_app/asset_delivery_client.dart';
import 'package:mosaic_app/asset_delivery_warm.dart';
import 'package:play_schema/play_schema.dart';

PlayDocument _play(List<PresentationLayer> layers) => PlayDocument(
  schemaVersion: 1,
  id: 'warm_play',
  revisionId: 'rev_warm',
  format: PlayFormat.discover,
  classification: PlayClassification.preference,
  topics: const [],
  learningTopics: const [],
  estimatedDurationSec: 10,
  assets: [
    for (final layer in layers)
      if (layer.assetId != null) layer.assetId!,
  ],
  sources: const [],
  entryState: 'start',
  states: {
    'start': PlayStateDefinition(
      presentation: layers,
      input: PlayInputDefinition(type: PlayInputType.tap),
      validation: PlayValidationDefinition(type: PlayValidatorType.none),
      transitions: const {'default': r'$end'},
    ),
  },
);

Map<String, Object?> _descriptor(String assetId, String kind) => {
  'schemaVersion': 1,
  'assetId': assetId,
  'kind': kind,
  'primary': {
    'variant': 'primary',
    'url': '/v1/assets/$assetId/content/primary',
    'mimeType': switch (kind) {
      'image' => 'image/jpeg',
      'video' => 'video/mp4',
      'audio' => 'audio/mp4',
      _ => throw ArgumentError.value(kind),
    },
    'sizeBytes': 1000,
    'width': kind == 'audio' ? null : 1280,
    'height': kind == 'audio' ? null : 720,
    'durationMs': kind == 'image' ? null : 1000,
    'container': kind == 'image' ? null : 'mp4',
    'videoCodec': kind == 'video' ? 'h264' : null,
    'videoProfile': kind == 'video' ? 'main' : null,
    'audioCodec': kind == 'image' ? null : 'aac',
    'colorSpace': kind == 'video' ? 'bt709' : null,
    'dynamicRange': kind == 'image' || kind == 'video' ? 'sdr' : null,
  },
  'poster': null,
  'captions': null,
};

void main() {
  test('mixed feed warm plan deduplicates images and caps metadata work', () {
    final layers = <PresentationLayer>[
      PresentationLayer(type: 'image', assetId: 'image_0'),
      PresentationLayer(type: 'image', assetId: 'image_0'),
      PresentationLayer(type: 'video_clip', assetId: 'video_0'),
      PresentationLayer(type: 'audio', assetId: 'audio_0'),
      PresentationLayer(type: 'canvas', assetId: 'canvas_0'),
      for (var index = 1; index <= 20; index += 1)
        PresentationLayer(type: 'video_clip', assetId: 'video_$index'),
    ];

    final plan = buildAssetWarmPlan([_play(layers)]);
    expect(plan.visualAssetIds, ['image_0']);
    expect(plan.metadataTargets, hasLength(defaultMaxWarmMetadataAssets));
    expect(
      plan.metadataTargets
          .where((target) => target.assetId == 'image_0')
          .length,
      1,
    );
    expect(
      plan.metadataTargets.any(
        (target) => target.assetId == 'canvas_0' && target.canvas,
      ),
      isTrue,
    );
  });

  test(
    'mixed metadata warming is concurrency-bounded and never fetches media content',
    () async {
      final requestedPaths = <String>[];
      var active = 0;
      var maxActive = 0;
      final client = AssetDeliveryClient(
        baseUri: Uri.parse('https://api.example.test/'),
        client: MockClient((request) async {
          requestedPaths.add(request.url.path);
          active += 1;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          active -= 1;

          final segments = request.url.pathSegments;
          if (segments.length == 3 && segments[1] == 'canvas-assets') {
            final id = segments[2];
            return http.Response(
              jsonEncode({
                'schemaVersion': 1,
                'id': id,
                'elements': [
                  {'type': 'label', 'x': 0.5, 'y': 0.5, 'text': 'Ready'},
                ],
              }),
              200,
            );
          }
          final id = segments[2];
          final kind = id.startsWith('image')
              ? 'image'
              : id.startsWith('audio')
              ? 'audio'
              : 'video';
          return http.Response(jsonEncode(_descriptor(id, kind)), 200);
        }),
      );
      final plan = buildAssetWarmPlan([
        _play([
          PresentationLayer(type: 'image', assetId: 'image_0'),
          PresentationLayer(type: 'video_clip', assetId: 'video_0'),
          PresentationLayer(type: 'audio', assetId: 'audio_0'),
          PresentationLayer(type: 'canvas', assetId: 'canvas_0'),
          for (var index = 1; index <= 10; index += 1)
            PresentationLayer(type: 'video_clip', assetId: 'video_$index'),
        ]),
      ]);
      final warmer = AssetMetadataWarmController(
        client: client,
        maxConcurrent: 3,
      );

      await warmer.warm(plan);

      expect(requestedPaths, hasLength(defaultMaxWarmMetadataAssets));
      expect(maxActive, lessThanOrEqualTo(3));
      expect(requestedPaths.any((path) => path.contains('/content/')), isFalse);
      expect(
        requestedPaths.where((path) => path.startsWith('/v1/assets/')).length,
        11,
      );
      expect(requestedPaths, contains('/v1/canvas-assets/canvas_0'));
      expect(client.inFlightCount, 0);
    },
  );
}
