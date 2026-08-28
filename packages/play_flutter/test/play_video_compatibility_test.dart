import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';

final class _CompatibilityVideoController implements PlayVideoController {
  _CompatibilityVideoController({Iterable<Object?> playOutcomes = const []})
    : _playOutcomes = Queue<Object?>.from(playOutcomes);

  final Queue<Object?> _playOutcomes;
  var initializeCount = 0;
  var playCount = 0;
  var pauseCount = 0;
  var releaseCount = 0;
  final List<bool> muteValues = <bool>[];

  @override
  Future<void> initialize() async => initializeCount += 1;

  @override
  Future<void> setMuted(bool muted) async => muteValues.add(muted);

  @override
  Future<void> play() async {
    playCount += 1;
    if (_playOutcomes.isEmpty) return;
    final outcome = _playOutcomes.removeFirst();
    if (outcome != null) throw outcome;
  }

  @override
  Future<void> pause() async => pauseCount += 1;

  @override
  Future<void> release() async => releaseCount += 1;

  @override
  Widget buildView(BuildContext context) => const ColoredBox(
    color: Colors.black,
    child: Center(child: Text('video-frame')),
  );
}

PlayVideoAsset _asset({
  bool autoplay = true,
  bool muted = true,
  PlayVideoFormatMetadata? format,
}) => PlayVideoAsset(
  id: 'clip',
  semanticLabel: 'Travel clip',
  source: NetworkPlayVideoSource(Uri.parse('https://cdn.example.com/clip.mp4')),
  autoplay: autoplay,
  muted: muted,
  format: format,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'manual video exposes a user play action and resumes only after it plays',
    (tester) async {
      final coordinator = ActiveMediaCoordinator();
      final controller = _CompatibilityVideoController();
      final asset = _asset(autoplay: false, muted: false);

      await tester.pumpWidget(
        MaterialApp(
          home: OwnedPlayVideo(
            ownerId: 'play',
            asset: asset,
            coordinator: coordinator,
            controllerFactory: (_) => controller,
          ),
        ),
      );
      await _settle(tester);

      expect(controller.playCount, 0);
      expect(coordinator.owns('play', controller), isTrue);
      expect(find.bySemanticsLabel('Play video'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Play video'));
      await _settle(tester);

      expect(controller.playCount, 1);
      expect(find.bySemanticsLabel('Play video'), findsNothing);

      await coordinator.suspend();
      await tester.pumpWidget(
        MaterialApp(
          home: OwnedPlayVideo(
            ownerId: 'play',
            asset: asset,
            coordinator: coordinator,
            controllerFactory: (_) => controller,
            semanticResumeEpoch: 1,
          ),
        ),
      );
      await _settle(tester);

      expect(controller.pauseCount, 1);
      expect(controller.playCount, 2);
    },
  );

  testWidgets(
    'recoverable autoplay rejection keeps ownership and falls back to tap',
    (tester) async {
      final coordinator = ActiveMediaCoordinator();
      final controller = _CompatibilityVideoController(
        playOutcomes: const <Object?>[
          PlayVideoPlaybackRejected('browser blocked autoplay'),
          null,
        ],
      );
      final events = <PlayVideoPlaybackEvent>[];

      await tester.pumpWidget(
        MaterialApp(
          home: OwnedPlayVideo(
            ownerId: 'play',
            asset: _asset(),
            coordinator: coordinator,
            controllerFactory: (_) => controller,
            onPlaybackEvent: events.add,
          ),
        ),
      );
      await _settle(tester);

      expect(controller.initializeCount, 1);
      expect(controller.playCount, 1);
      expect(controller.releaseCount, 0);
      expect(coordinator.owns('play', controller), isTrue);
      expect(find.byType(PlayVideoUnavailable), findsNothing);
      expect(find.bySemanticsLabel('Play video'), findsOneWidget);
      expect(
        events.map((event) => event.phase),
        containsAll(<PlayVideoPlaybackPhase>[
          PlayVideoPlaybackPhase.initialized,
          PlayVideoPlaybackPhase.autoplayBlocked,
          PlayVideoPlaybackPhase.firstFramePainted,
        ]),
      );

      await tester.tap(find.bySemanticsLabel('Play video'));
      await _settle(tester);

      expect(controller.playCount, 2);
      expect(find.bySemanticsLabel('Play video'), findsNothing);
      expect(
        events.map((event) => event.phase),
        contains(PlayVideoPlaybackPhase.userPlaybackStarted),
      );
    },
  );

  testWidgets('failed user playback remains owned and presents a retry path', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final failure = StateError('temporary playback failure');
    final controller = _CompatibilityVideoController(
      playOutcomes: <Object?>[failure, null],
    );
    final observedErrors = <Object>[];

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play',
          asset: _asset(autoplay: false),
          coordinator: coordinator,
          controllerFactory: (_) => controller,
          onError: (asset, error, stackTrace) => observedErrors.add(error),
        ),
      ),
    );
    await _settle(tester);

    await tester.tap(find.bySemanticsLabel('Play video'));
    await _settle(tester);

    expect(controller.playCount, 1);
    expect(controller.releaseCount, 0);
    expect(coordinator.owns('play', controller), isTrue);
    expect(find.bySemanticsLabel('Retry video'), findsOneWidget);
    expect(observedErrors, contains(same(failure)));

    await tester.tap(find.bySemanticsLabel('Retry video'));
    await _settle(tester);

    expect(controller.playCount, 2);
    expect(find.bySemanticsLabel('Retry video'), findsNothing);
  });

  test('video codec preserves derivative format metadata for telemetry', () {
    final asset = PlayVideoAssetCodec.decode(<String, Object?>{
      'schemaVersion': 1,
      'id': 'clip',
      'autoplay': true,
      'muted': true,
      'format': <String, Object?>{
        'container': 'mp4',
        'videoCodec': 'h264',
        'videoProfile': 'high',
        'audioCodec': 'aac',
      },
      'source': <String, Object?>{
        'type': 'network',
        'uri': 'https://cdn.example.com/clip.mp4',
      },
    });

    expect(asset.format?.container, 'mp4');
    expect(asset.format?.videoCodec, 'h264');
    expect(asset.format?.videoProfile, 'high');
    expect(asset.format?.audioCodec, 'aac');

    expect(
      () => PlayVideoAssetCodec.decode(<String, Object?>{
        'schemaVersion': 1,
        'id': 'clip',
        'format': <String, Object?>{},
        'source': <String, Object?>{
          'type': 'network',
          'uri': 'https://cdn.example.com/clip.mp4',
        },
      }),
      throwsFormatException,
    );
  });

  testWidgets('telemetry observers cannot destabilize playback', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final controller = _CompatibilityVideoController();

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play',
          asset: _asset(
            format: PlayVideoFormatMetadata(
              container: 'mp4',
              videoCodec: 'h264',
              videoProfile: 'main',
            ),
          ),
          coordinator: coordinator,
          controllerFactory: (_) => controller,
          onPlaybackEvent: (_) => throw StateError('observer failed'),
        ),
      ),
    );
    await _settle(tester);

    expect(controller.playCount, 1);
    expect(coordinator.owns('play', controller), isTrue);
    expect(find.text('video-frame'), findsOneWidget);
  });
}
