import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

final class _FakeAudioEngine implements AudioEngine {
  @override
  Map<String, num> get latencyMetrics => const <String, num>{};

  @override
  Future<void> load(String assetId, Uri uri) async {}

  @override
  Future<void> play(String assetId) async {}

  @override
  Future<void> release(String assetId) async {}

  @override
  Future<void> schedule(String assetId, Duration offset) async {}

  @override
  Future<void> stop(String assetId) async {}
}

void main() {
  testWidgets('media router binds audio only when resolver and engine exist', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );

    final layer = PresentationLayer(
      type: 'audio',
      role: 'media',
      assetId: 'audio_1',
    );
    final audio = PlayAudioAsset(
      id: 'audio_1',
      uri: Uri.parse('https://cdn.example.com/audio_1.m4a'),
    );
    final coordinator = ActiveMediaCoordinator();

    final unsupported = PlayMediaLayerBuilder(
      ownerId: 'rev_1',
      visualResolver: MapPlayVisualAssetResolver(const {}),
      videoResolver: MapPlayVideoAssetResolver(const {}),
      mediaCoordinator: coordinator,
      videoControllerFactory: (_) =>
          throw StateError('Video controller should not be requested.'),
    ).call(context, layer);
    expect(unsupported, isA<PlayMediaUnavailable>());

    final routed = PlayMediaLayerBuilder(
      ownerId: 'rev_1',
      visualResolver: MapPlayVisualAssetResolver(const {}),
      videoResolver: MapPlayVideoAssetResolver(const {}),
      audioResolver: MapPlayAudioAssetResolver({'audio_1': audio}),
      audioEngine: _FakeAudioEngine(),
      mediaCoordinator: coordinator,
      videoControllerFactory: (_) =>
          throw StateError('Video controller should not be requested.'),
    ).call(context, layer);

    expect(routed, isA<ResolvedPlayAudio>());
    final resolved = routed as ResolvedPlayAudio;
    expect(resolved.ownerId, 'rev_1');
    expect(resolved.assetId, 'audio_1');
  });
}
