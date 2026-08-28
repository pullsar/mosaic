import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:platform_flutter/platform_flutter.dart';
import 'package:play_flutter/play_flutter.dart';

final class _VideoController implements PlayVideoController {
  var initializeCount = 0;
  var playCount = 0;
  var pauseCount = 0;
  var releaseCount = 0;
  final muteValues = <bool>[];

  @override
  Future<void> initialize() async => initializeCount += 1;

  @override
  Future<void> setMuted(bool muted) async => muteValues.add(muted);

  @override
  Future<void> play() async => playCount += 1;

  @override
  Future<void> pause() async => pauseCount += 1;

  @override
  Future<void> release() async => releaseCount += 1;

  @override
  Widget buildView(BuildContext context) => const Text('video');
}

final class _VideoLifecycleHarness extends StatefulWidget {
  const _VideoLifecycleHarness({
    required this.coordinator,
    required this.controller,
    required this.asset,
    super.key,
  });

  final ActiveMediaCoordinator coordinator;
  final _VideoController controller;
  final PlayVideoAsset asset;

  @override
  State<_VideoLifecycleHarness> createState() => _VideoLifecycleHarnessState();
}

final class _VideoLifecycleHarnessState extends State<_VideoLifecycleHarness> {
  late final FlutterLifecycleBridge _bridge;
  var _resumeEpoch = 0;

  @override
  void initState() {
    super.initState();
    _bridge = FlutterLifecycleBridge(
      mediaCoordinator: widget.coordinator,
      onSemanticResume: () {
        if (mounted) setState(() => _resumeEpoch += 1);
      },
    );
  }

  Future<void> pauseAndResume() async {
    await _bridge.handleState(AppRuntimeState.paused);
    await _bridge.handleState(AppRuntimeState.resumed);
  }

  @override
  void dispose() {
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OwnedPlayVideo(
    ownerId: 'video-owner',
    asset: widget.asset,
    coordinator: widget.coordinator,
    controllerFactory: (_) => widget.controller,
    semanticResumeEpoch: _resumeEpoch,
  );
}

final class _AudioEngine implements AudioEngine {
  final events = <String>[];

  @override
  Map<String, num> get latencyMetrics => const <String, num>{};

  @override
  Future<void> load(String assetId, Uri uri) async => events.add('load');

  @override
  Future<void> play(String assetId) async => events.add('play');

  @override
  Future<void> schedule(String assetId, Duration offset) async =>
      events.add('schedule');

  @override
  Future<void> stop(String assetId) async => events.add('stop');

  @override
  Future<void> release(String assetId) async => events.add('release');
}

final class _AudioLifecycleHarness extends StatefulWidget {
  const _AudioLifecycleHarness({
    required this.coordinator,
    required this.engine,
    super.key,
  });

  final ActiveMediaCoordinator coordinator;
  final _AudioEngine engine;

  @override
  State<_AudioLifecycleHarness> createState() => _AudioLifecycleHarnessState();
}

final class _AudioLifecycleHarnessState extends State<_AudioLifecycleHarness> {
  late final FlutterLifecycleBridge _bridge;
  late final PlayAudioAsset _asset;
  var _resumeEpoch = 0;

  @override
  void initState() {
    super.initState();
    _asset = PlayAudioAsset(
      id: 'audio_a',
      uri: Uri.parse('https://cdn.example.com/audio_a.m4a'),
      semanticLabel: 'Hear note',
    );
    _bridge = FlutterLifecycleBridge(
      mediaCoordinator: widget.coordinator,
      onSemanticResume: () {
        if (mounted) setState(() => _resumeEpoch += 1);
      },
    );
  }

  Future<void> pauseAndResume() async {
    await _bridge.handleState(AppRuntimeState.paused);
    await _bridge.handleState(AppRuntimeState.resumed);
  }

  @override
  void dispose() {
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The epoch read makes semantic-resume rebuild intent explicit while the
    // exact audio asset/engine/coordinator identities remain stable.
    final semanticResumeObserved = _resumeEpoch >= 0;
    return Semantics(
      container: semanticResumeObserved,
      child: OwnedPlayAudio(
        ownerId: 'audio-owner',
        asset: _asset,
        engine: widget.engine,
        coordinator: widget.coordinator,
      ),
    );
  }
}

void main() {
  testWidgets('Flutter lifecycle resumes only previously playing managed video', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final controller = _VideoController();
    final asset = PlayVideoAsset(
      id: 'video_a',
      source: NetworkPlayVideoSource(
        Uri.parse('https://cdn.example.com/video_a.mp4'),
      ),
    );
    final key = GlobalKey<_VideoLifecycleHarnessState>();

    await tester.pumpWidget(
      MaterialApp(
        home: _VideoLifecycleHarness(
          key: key,
          coordinator: coordinator,
          controller: controller,
          asset: asset,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.playCount, 1);

    await key.currentState!.pauseAndResume();
    await tester.pumpAndSettle();

    expect(controller.pauseCount, 1);
    expect(controller.playCount, 2);
    expect(coordinator.owns('video-owner', controller), isTrue);
  });

  testWidgets('Flutter lifecycle never auto-replays user-initiated audio', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final engine = _AudioEngine();
    final key = GlobalKey<_AudioLifecycleHarnessState>();

    await tester.pumpWidget(
      MaterialApp(
        home: _AudioLifecycleHarness(
          key: key,
          coordinator: coordinator,
          engine: engine,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(engine.events, isEmpty);

    await tester.tap(find.text('Hear'));
    await tester.pumpAndSettle();
    expect(engine.events, ['load', 'play']);

    await key.currentState!.pauseAndResume();
    await tester.pumpAndSettle();

    expect(engine.events, ['load', 'play', 'stop']);
    expect(find.text('Replay'), findsOneWidget);
    expect(coordinator.hasActiveMedia, isTrue);
  });
}
