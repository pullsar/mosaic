import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';

final class _FakeVideoController implements PlayVideoController {
  _FakeVideoController(
    this.name, {
    this.initializeGate,
    this.initializeError,
    this.muteError,
    this.playError,
    this.releaseError,
  });

  final String name;
  final Completer<void>? initializeGate;
  final Object? initializeError;
  final Object? muteError;
  final Object? playError;
  final Object? releaseError;
  final List<String> events = <String>[];
  final List<bool> muteValues = <bool>[];
  var initializeCount = 0;
  var playCount = 0;
  var pauseCount = 0;
  var releaseCount = 0;

  @override
  Future<void> initialize() async {
    initializeCount += 1;
    events.add('$name.initialize:start');
    await initializeGate?.future;
    final error = initializeError;
    if (error != null) throw error;
    events.add('$name.initialize:end');
  }

  @override
  Future<void> setMuted(bool muted) async {
    muteValues.add(muted);
    events.add('$name.muted:$muted');
    final error = muteError;
    if (error != null) throw error;
  }

  @override
  Future<void> play() async {
    playCount += 1;
    events.add('$name.play');
    final error = playError;
    if (error != null) throw error;
  }

  @override
  Future<void> pause() async {
    pauseCount += 1;
    events.add('$name.pause');
  }

  @override
  Future<void> release() async {
    releaseCount += 1;
    events.add('$name.release');
    final error = releaseError;
    if (error != null) throw error;
  }

  @override
  Widget buildView(BuildContext context) => Text('view:$name');
}

final class _ReplacementHandle implements ManagedMediaHandle {
  var pauseCount = 0;
  var releaseCount = 0;

  @override
  Future<void> pause() async => pauseCount += 1;

  @override
  Future<void> release() async => releaseCount += 1;
}

PlayVideoAsset _asset(
  String id, {
  bool autoplay = true,
  bool muted = true,
}) => PlayVideoAsset(
  id: id,
  semanticLabel: 'Video $id',
  source: NetworkPlayVideoSource(Uri.parse('https://cdn.example.com/$id.mp4')),
  autoplay: autoplay,
  muted: muted,
);

Future<void> _settleOwnership(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  test(
    'network video sources require absolute HTTPS and immutable headers',
    () {
      final headers = <String, String>{'Authorization': 'Bearer original'};
      final source = NetworkPlayVideoSource(
        Uri.parse('https://cdn.example.com/video.mp4'),
        headers: headers,
      );
      headers['Authorization'] = 'Bearer mutated';

      expect(source.headers?['Authorization'], 'Bearer original');
      expect(
        () => NetworkPlayVideoSource(Uri.parse('http://example.com/video.mp4')),
        throwsArgumentError,
      );
      expect(
        () => NetworkPlayVideoSource(Uri.parse('/video.mp4')),
        throwsArgumentError,
      );
    },
  );

  testWidgets('initializes, mutes, acquires ownership, autoplays, and renders', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final controller = _FakeVideoController('first');

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: _asset('video_a'),
          coordinator: coordinator,
          controllerFactory: (_) => controller,
        ),
      ),
    );
    await _settleOwnership(tester);

    expect(controller.initializeCount, 1);
    expect(controller.muteValues, [true]);
    expect(controller.playCount, 1);
    expect(
      controller.events.take(4),
      [
        'first.initialize:start',
        'first.initialize:end',
        'first.muted:true',
        'first.play',
      ],
    );
    expect(coordinator.owns('play_a', controller), isTrue);
    expect(find.text('view:first'), findsOneWidget);
    expect(find.bySemanticsLabel('Video video_a'), findsOneWidget);
  });

  testWidgets('audible autoplay is rejected before play', (tester) async {
    final coordinator = ActiveMediaCoordinator();
    final controller = _FakeVideoController('audible');

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: _asset('video_a', muted: false),
          coordinator: coordinator,
          controllerFactory: (_) => controller,
        ),
      ),
    );
    await _settleOwnership(tester);

    expect(controller.muteValues, [false]);
    expect(controller.playCount, 0);
    expect(controller.releaseCount, 1);
    expect(coordinator.hasActiveMedia, isFalse);
    expect(find.byType(PlayVideoUnavailable), findsOneWidget);
  });

  testWidgets('manual unmuted video stays idle across semantic resume', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final controller = _FakeVideoController('manual');
    final asset = _asset('video_a', autoplay: false, muted: false);

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: asset,
          coordinator: coordinator,
          controllerFactory: (_) => controller,
        ),
      ),
    );
    await _settleOwnership(tester);

    expect(controller.muteValues, [false]);
    expect(controller.playCount, 0);
    expect(coordinator.owns('play_a', controller), isTrue);
    expect(find.text('view:manual'), findsOneWidget);

    await coordinator.suspend();
    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: asset,
          coordinator: coordinator,
          controllerFactory: (_) => controller,
          semanticResumeEpoch: 1,
        ),
      ),
    );
    await _settleOwnership(tester);

    expect(controller.pauseCount, 1);
    expect(controller.playCount, 0);
    expect(coordinator.owns('play_a', controller), isTrue);
  });

  testWidgets(
    'shared lifecycle suspension pauses without releasing ownership',
    (tester) async {
      final coordinator = ActiveMediaCoordinator();
      final controller = _FakeVideoController('active');

      await tester.pumpWidget(
        MaterialApp(
          home: OwnedPlayVideo(
            ownerId: 'play_a',
            asset: _asset('video_a'),
            coordinator: coordinator,
            controllerFactory: (_) => controller,
          ),
        ),
      );
      await _settleOwnership(tester);

      await coordinator.suspend();

      expect(controller.pauseCount, 1);
      expect(controller.releaseCount, 0);
      expect(coordinator.owns('play_a', controller), isTrue);
    },
  );

  testWidgets('semantic resume restarts a previously playing exact controller', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final controller = _FakeVideoController('active');
    final asset = _asset('video_a');

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: asset,
          coordinator: coordinator,
          controllerFactory: (_) => controller,
        ),
      ),
    );
    await _settleOwnership(tester);
    expect(controller.playCount, 1);

    await coordinator.suspend();
    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: asset,
          coordinator: coordinator,
          controllerFactory: (_) => controller,
          semanticResumeEpoch: 1,
        ),
      ),
    );
    await _settleOwnership(tester);

    expect(controller.pauseCount, 1);
    expect(controller.playCount, 2);
    expect(coordinator.owns('play_a', controller), isTrue);
  });

  testWidgets('becoming inactive releases the exact controller', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final controller = _FakeVideoController('active');

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: _asset('video_a'),
          coordinator: coordinator,
          controllerFactory: (_) => controller,
        ),
      ),
    );
    await _settleOwnership(tester);

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: _asset('video_a'),
          coordinator: coordinator,
          controllerFactory: (_) => controller,
          active: false,
        ),
      ),
    );
    await _settleOwnership(tester);

    expect(controller.pauseCount, 1);
    expect(controller.releaseCount, 1);
    expect(coordinator.hasActiveMedia, isFalse);
    expect(find.text('view:active'), findsNothing);
  });

  testWidgets('replacement waits for stale initialization cleanup', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final firstGate = Completer<void>();
    final first = _FakeVideoController('first', initializeGate: firstGate);
    final second = _FakeVideoController('second');
    var created = 0;
    PlayVideoController factory(PlayVideoAsset asset) {
      created += 1;
      return asset.id == 'video_a' ? first : second;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: _asset('video_a'),
          coordinator: coordinator,
          controllerFactory: factory,
        ),
      ),
    );
    await tester.pump();
    expect(first.initializeCount, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: _asset('video_b'),
          coordinator: coordinator,
          controllerFactory: factory,
        ),
      ),
    );
    await tester.pump();
    expect(second.initializeCount, 0);

    firstGate.complete();
    await _settleOwnership(tester);
    await _settleOwnership(tester);

    expect(created, 2);
    expect(first.playCount, 0);
    expect(first.releaseCount, 1);
    expect(second.initializeCount, 1);
    expect(second.muteValues, [true]);
    expect(second.playCount, 1);
    expect(coordinator.owns('play_a', second), isTrue);
    expect(find.text('view:second'), findsOneWidget);
  });

  testWidgets('semantic resume only plays the exact current controller', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final stale = _FakeVideoController('stale');
    final asset = _asset('video_a');

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: asset,
          coordinator: coordinator,
          controllerFactory: (_) => stale,
        ),
      ),
    );
    await _settleOwnership(tester);
    expect(stale.playCount, 1);

    final replacement = _ReplacementHandle();
    await coordinator.activate('play_a', replacement);
    expect(stale.pauseCount, 1);
    expect(stale.releaseCount, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: asset,
          coordinator: coordinator,
          controllerFactory: (_) => stale,
          semanticResumeEpoch: 1,
        ),
      ),
    );
    await _settleOwnership(tester);

    expect(stale.playCount, 1);
    expect(coordinator.owns('play_a', replacement), isTrue);
  });

  testWidgets('mute failure releases the controller and fails closed', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final muteFailure = StateError('mute failed');
    final controller = _FakeVideoController('broken-mute', muteError: muteFailure);
    final observed = <Object>[];

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: _asset('video_a'),
          coordinator: coordinator,
          controllerFactory: (_) => controller,
          onError: (asset, error, stackTrace) => observed.add(error),
        ),
      ),
    );
    await _settleOwnership(tester);

    expect(controller.playCount, 0);
    expect(controller.releaseCount, 1);
    expect(coordinator.hasActiveMedia, isFalse);
    expect(find.byType(PlayVideoUnavailable), findsOneWidget);
    expect(observed, contains(same(muteFailure)));
  });

  testWidgets('autoplay failure releases ownership and fails closed', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final playFailure = StateError('play failed');
    final controller = _FakeVideoController(
      'broken-play',
      playError: playFailure,
    );
    final observed = <Object>[];

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: _asset('video_a'),
          coordinator: coordinator,
          controllerFactory: (_) => controller,
          onError: (asset, error, stackTrace) => observed.add(error),
        ),
      ),
    );
    await _settleOwnership(tester);

    expect(controller.initializeCount, 1);
    expect(controller.playCount, 1);
    expect(controller.pauseCount, 1);
    expect(controller.releaseCount, 1);
    expect(coordinator.hasActiveMedia, isFalse);
    expect(find.byType(PlayVideoUnavailable), findsOneWidget);
    expect(observed, contains(same(playFailure)));
  });

  testWidgets(
    'release failure blocks replacement and preserves retry ownership',
    (tester) async {
      final coordinator = ActiveMediaCoordinator();
      final releaseFailure = StateError('release failed');
      final first = _FakeVideoController(
        'first',
        releaseError: releaseFailure,
      );
      final second = _FakeVideoController('second');
      final observed = <Object>[];

      PlayVideoController factory(PlayVideoAsset asset) =>
          asset.id == 'video_a' ? first : second;

      await tester.pumpWidget(
        MaterialApp(
          home: OwnedPlayVideo(
            ownerId: 'play_a',
            asset: _asset('video_a'),
            coordinator: coordinator,
            controllerFactory: factory,
            onError: (asset, error, stackTrace) => observed.add(error),
          ),
        ),
      );
      await _settleOwnership(tester);
      expect(coordinator.owns('play_a', first), isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: OwnedPlayVideo(
            ownerId: 'play_a',
            asset: _asset('video_b'),
            coordinator: coordinator,
            controllerFactory: factory,
            onError: (asset, error, stackTrace) => observed.add(error),
          ),
        ),
      );
      await _settleOwnership(tester);

      expect(first.pauseCount, 1);
      expect(first.releaseCount, 1);
      expect(second.initializeCount, 0);
      expect(coordinator.owns('play_a', first), isTrue);
      expect(find.byType(PlayVideoUnavailable), findsOneWidget);
      expect(observed, contains(same(releaseFailure)));
    },
  );

  testWidgets('initialization failure cleans up and fails closed', (
    tester,
  ) async {
    final coordinator = ActiveMediaCoordinator();
    final controller = _FakeVideoController(
      'broken',
      initializeError: StateError('initialize failed'),
    );
    final observed = <Object>[];

    await tester.pumpWidget(
      MaterialApp(
        home: OwnedPlayVideo(
          ownerId: 'play_a',
          asset: _asset('video_a'),
          coordinator: coordinator,
          controllerFactory: (_) => controller,
          onError: (asset, error, stackTrace) {
            observed.add(error);
            throw StateError('observer failure');
          },
        ),
      ),
    );
    await _settleOwnership(tester);

    expect(controller.releaseCount, 1);
    expect(controller.playCount, 0);
    expect(coordinator.hasActiveMedia, isFalse);
    expect(find.byType(PlayVideoUnavailable), findsOneWidget);
    expect(observed, hasLength(1));
  });
}
