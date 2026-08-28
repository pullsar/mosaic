import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

final class _VideoController implements PlayVideoController {
  var initializeCount = 0;
  var playCount = 0;
  var pauseCount = 0;
  var releaseCount = 0;

  @override
  Future<void> initialize() async => initializeCount += 1;

  @override
  Future<void> play() async => playCount += 1;

  @override
  Future<void> pause() async => pauseCount += 1;

  @override
  Future<void> release() async => releaseCount += 1;

  @override
  Widget buildView(BuildContext context) => const Text('video-view');
}

PlayMediaLayerBuilder _builder({
  PlayVideoAssetResolver? videoResolver,
  PlayVideoControllerFactory? controllerFactory,
  ActiveMediaCoordinator? coordinator,
  UnsupportedPlayMediaBuilder? unsupportedBuilder,
}) => PlayMediaLayerBuilder(
  ownerId: 'play_revision_1',
  visualResolver: MapPlayVisualAssetResolver(const {}),
  videoResolver: videoResolver ?? MapPlayVideoAssetResolver(const {}),
  mediaCoordinator: coordinator ?? ActiveMediaCoordinator(),
  videoControllerFactory:
      controllerFactory ??
      (_) => throw StateError('Video controller should not be requested.'),
  unsupportedBuilder: unsupportedBuilder,
);

PresentationLayer _layer(String type, {String? assetId}) => PresentationLayer(
  type: type,
  role: 'media',
  assetId: assetId,
);

void main() {
  testWidgets('routes only image and video_clip to production adapters', (
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

    final builder = _builder();
    final image = builder.call(context, _layer('image', assetId: 'image_1'));
    final video = builder.call(
      context,
      _layer('video_clip', assetId: 'video_1'),
    );

    expect(image, isA<ResolvedPlayVisual>());
    expect((image as ResolvedPlayVisual).assetId, 'image_1');
    expect(video, isA<ResolvedPlayVideo>());
    expect((video as ResolvedPlayVideo).assetId, 'video_1');
    expect(video.ownerId, 'play_revision_1');
  });

  testWidgets('audio canvas and unknown media fail closed', (tester) async {
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

    final builder = _builder();
    for (final type in const ['audio', 'canvas', 'future_media']) {
      final widget = builder.call(context, _layer(type, assetId: 'asset_1'));
      expect(widget, isA<PlayMediaUnavailable>());
      expect((widget as PlayMediaUnavailable).type, type);
    }
  });

  testWidgets('missing asset identity never invokes a renderer', (tester) async {
    var videoLookups = 0;
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

    final builder = _builder(
      videoResolver: CallbackPlayVideoAssetResolver((assetId) {
        videoLookups += 1;
        return null;
      }),
    );
    final widget = builder.call(context, _layer('video_clip', assetId: '  '));

    expect(widget, isA<PlayMediaUnavailable>());
    expect(videoLookups, 0);
  });

  testWidgets('custom unsupported fallback preserves the original layer', (
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

    final builder = _builder(
      unsupportedBuilder: (context, layer) => Text('unsupported:${layer.type}'),
    );
    final widget = builder.call(context, _layer('audio', assetId: 'audio_1'));

    expect(widget, isA<Text>());
    expect((widget as Text).data, 'unsupported:audio');
  });

  testWidgets('resolved video acquires the declared Play owner', (tester) async {
    final coordinator = ActiveMediaCoordinator();
    final controller = _VideoController();
    final asset = PlayVideoAsset(
      id: 'video_1',
      source: NetworkPlayVideoSource(
        Uri.parse('https://cdn.example.com/video_1.mp4'),
      ),
    );
    final builder = _builder(
      coordinator: coordinator,
      videoResolver: MapPlayVideoAssetResolver({'video_1': asset}),
      controllerFactory: (_) => controller,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => builder.call(
            context,
            _layer('video_clip', assetId: 'video_1'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(controller.initializeCount, 1);
    expect(controller.playCount, 1);
    expect(coordinator.owns('play_revision_1', controller), isTrue);
    expect(find.text('video-view'), findsOneWidget);
  });

  testWidgets('mismatched resolved video identity fails closed', (tester) async {
    final requested = PlayVideoAsset(
      id: 'different_video',
      source: NetworkPlayVideoSource(
        Uri.parse('https://cdn.example.com/different.mp4'),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVideo(
          ownerId: 'play_revision_1',
          assetId: 'video_1',
          resolver: CallbackPlayVideoAssetResolver((_) => requested),
          coordinator: ActiveMediaCoordinator(),
          controllerFactory: (_) => _VideoController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PlayVideoUnavailable), findsOneWidget);
    expect(find.text('video-view'), findsNothing);
  });
}
