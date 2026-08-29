import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mosaic_app/asset_delivery_client.dart';
import 'package:play_flutter/play_flutter.dart';

Map<String, Object?> _object({
  required String variant,
  required String url,
  required String mimeType,
  int? width,
  int? height,
  int? durationMs,
  String? container,
  String? videoCodec,
  String? videoProfile,
  String? audioCodec,
}) => <String, Object?>{
  'variant': variant,
  'url': url,
  'mimeType': mimeType,
  'sizeBytes': 1000,
  'width': width,
  'height': height,
  'durationMs': durationMs,
  'container': container,
  'videoCodec': videoCodec,
  'videoProfile': videoProfile,
  'audioCodec': audioCodec,
  'colorSpace': videoCodec == null ? null : 'bt709',
  'dynamicRange': mimeType.startsWith('image/') || videoCodec != null
      ? 'sdr'
      : null,
};

Map<String, Object?> _descriptor(
  String assetId,
  String kind, {
  String? primaryUrl,
}) {
  final primary = switch (kind) {
    'image' => _object(
      variant: 'primary',
      url: primaryUrl ?? '/v1/assets/$assetId/content/primary',
      mimeType: 'image/jpeg',
      width: 1280,
      height: 720,
    ),
    'video' => _object(
      variant: 'primary',
      url: primaryUrl ?? '/v1/assets/$assetId/content/primary',
      mimeType: 'video/mp4',
      width: 1280,
      height: 720,
      durationMs: 5000,
      container: 'mp4',
      videoCodec: 'h264',
      videoProfile: 'main',
      audioCodec: 'aac',
    ),
    'audio' => _object(
      variant: 'primary',
      url: primaryUrl ?? '/v1/assets/$assetId/content/primary',
      mimeType: 'audio/mp4',
      durationMs: 2000,
      container: 'mp4',
      audioCodec: 'aac',
    ),
    _ => throw ArgumentError.value(kind),
  };
  return <String, Object?>{
    'schemaVersion': 1,
    'assetId': assetId,
    'kind': kind,
    'primary': primary,
    'poster': kind == 'video'
        ? _object(
            variant: 'poster',
            url: '/v1/assets/$assetId/content/poster',
            mimeType: 'image/jpeg',
            width: 1280,
            height: 720,
          )
        : null,
    'captions': null,
  };
}

void main() {
  test('descriptor requests coalesce and remain bounded by TTL', () async {
    var now = DateTime.utc(2026, 8, 29, 20);
    var requests = 0;
    final client = AssetDeliveryClient(
      baseUri: Uri.parse('https://api.example.test/'),
      client: MockClient((request) async {
        requests += 1;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return http.Response(
          jsonEncode(_descriptor('image_a', 'image')),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
      successTtl: const Duration(seconds: 30),
      now: () => now,
    );

    final values = await Future.wait(<Future<ManagedAssetDescriptor?>>[
      client.describe('image_a'),
      client.describe('image_a'),
      client.describe('image_a'),
    ]);
    expect(requests, 1);
    expect(values.every((value) => value?.assetId == 'image_a'), isTrue);
    expect(client.descriptorCacheSize, 1);

    await client.describe('image_a');
    expect(requests, 1);
    now = now.add(const Duration(seconds: 31));
    await client.describe('image_a');
    expect(requests, 2);
  });

  test(
    '404 is briefly negative-cached while transient failures are not',
    () async {
      var requests = 0;
      final client = AssetDeliveryClient(
        baseUri: Uri.parse('https://api.example.test/'),
        client: MockClient((request) async {
          requests += 1;
          if (request.url.path.endsWith('missing')) {
            return http.Response('{}', 404);
          }
          return http.Response('{}', 503);
        }),
      );

      expect(await client.describe('missing'), isNull);
      expect(await client.describe('missing'), isNull);
      expect(requests, 1);
      await expectLater(
        client.describe('retry'),
        throwsA(isA<AssetDeliveryUnavailableException>()),
      );
      await expectLater(
        client.describe('retry'),
        throwsA(isA<AssetDeliveryUnavailableException>()),
      );
      expect(requests, 3);
    },
  );

  test('invalidation fences stale in-flight cache writes and permits a fresh request', () async {
    final first = Completer<http.Response>();
    var requests = 0;
    final client = AssetDeliveryClient(
      baseUri: Uri.parse('https://api.example.test/'),
      client: MockClient((request) async {
        requests += 1;
        if (requests == 1) return first.future;
        return http.Response(
          jsonEncode(_descriptor('image_a', 'image')),
          200,
        );
      }),
    );

    final stale = client.describe('image_a');
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    client.invalidate('image_a');

    final fresh = client.describe('image_a');
    expect(await fresh, isNotNull);
    expect(requests, 2);
    first.complete(
      http.Response(jsonEncode(_descriptor('image_a', 'image')), 200),
    );
    expect(await stale, isNotNull);
    expect(client.descriptorCacheSize, 1);

    await client.describe('image_a');
    expect(requests, 2);
  });

  test(
    'managed adapters validate identity, kind and same-origin HTTPS URLs',
    () async {
      final responses = <String, Map<String, Object?>>{
        '/v1/assets/image_a': _descriptor('image_a', 'image'),
        '/v1/assets/video_a': _descriptor('video_a', 'video'),
        '/v1/assets/audio_a': _descriptor('audio_a', 'audio'),
        '/v1/assets/bad_origin': _descriptor(
          'bad_origin',
          'image',
          primaryUrl: 'https://evil.example/x.jpg',
        ),
      };
      final client = AssetDeliveryClient(
        baseUri: Uri.parse('https://api.example.test/'),
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(responses[request.url.path]),
            responses.containsKey(request.url.path) ? 200 : 404,
          ),
        ),
      );

      final visual = await ManagedVisualAssetResolver(
        client,
      ).resolve('image_a');
      expect(visual, isNotNull);
      final visualSource = visual!.source as NetworkPlayVisualSource;
      expect(
        visualSource.uri.toString(),
        'https://api.example.test/v1/assets/image_a/content/primary',
      );

      final video = await ManagedVideoAssetResolver(client).resolve('video_a');
      expect(video?.format?.videoCodec, 'h264');
      expect(video?.muted, isTrue);
      expect(video?.autoplay, isTrue);
      final videoSource = video!.source as NetworkPlayVideoSource;
      expect(videoSource.uri.host, 'api.example.test');

      final poster = await ManagedVideoPosterResolver(
        client,
      ).resolvePoster('video_a');
      expect(poster?.id, 'video_a:poster');

      final audio = await ManagedAudioAssetResolver(client).resolve('audio_a');
      expect(
        audio?.uri.toString(),
        'https://api.example.test/v1/assets/audio_a/content/primary',
      );

      await expectLater(
        ManagedAudioAssetResolver(client).resolve('image_a'),
        throwsA(isA<AssetDeliveryFormatException>()),
      );
      await expectLater(
        ManagedVisualAssetResolver(client).resolve('bad_origin'),
        throwsA(isA<AssetDeliveryFormatException>()),
      );
    },
  );

  test(
    'canvas resolution is bounded, identity-checked and works on explicit localhost',
    () async {
      var requests = 0;
      final client = AssetDeliveryClient(
        baseUri: Uri.parse('http://localhost:8080/'),
        allowInsecureLocalhost: true,
        client: MockClient((request) async {
          requests += 1;
          return http.Response(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'id': 'canvas_a',
              'semanticLabel': 'Simple diagram',
              'elements': <Object?>[
                <String, Object?>{
                  'type': 'label',
                  'x': 0.5,
                  'y': 0.5,
                  'text': 'Ready',
                },
              ],
            }),
            200,
          );
        }),
      );

      expect(client.supportsBinaryNetworkAssets, isFalse);
      final resolver = ManagedCanvasAssetResolver(client);
      expect((await resolver.resolve('canvas_a'))?.id, 'canvas_a');
      expect((await resolver.resolve('canvas_a'))?.id, 'canvas_a');
      expect(requests, 1);
      expect(
        await ManagedVisualAssetResolver(client).resolve('image_a'),
        isNull,
      );
    },
  );
}
