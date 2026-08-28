import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';

final class _FakeAudioEngine implements AudioEngine {
  final List<String> events = <String>[];
  Object? loadError;
  Object? playError;
  Object? stopError;
  Object? releaseError;

  @override
  Map<String, num> get latencyMetrics => const <String, num>{};

  @override
  Future<void> load(String assetId, Uri uri) async {
    events.add('load:$assetId');
    final error = loadError;
    if (error != null) throw error;
  }

  @override
  Future<void> play(String assetId) async {
    events.add('play:$assetId');
    final error = playError;
    if (error != null) throw error;
  }

  @override
  Future<void> schedule(String assetId, Duration offset) async {
    events.add('schedule:$assetId:${offset.inMicroseconds}');
  }

  @override
  Future<void> stop(String assetId) async {
    events.add('stop:$assetId');
    final error = stopError;
    if (error != null) throw error;
  }

  @override
  Future<void> release(String assetId) async {
    events.add('release:$assetId');
    final error = releaseError;
    if (error != null) throw error;
  }
}

final class _ReplacementHandle implements ManagedMediaHandle {
  var pauseCount = 0;
  var releaseCount = 0;

  @override
  Future<void> pause() async => pauseCount += 1;

  @override
  Future<void> release() async => releaseCount += 1;
}

PlayAudioAsset _asset(String id) => PlayAudioAsset(
  id: id,
  uri: Uri.parse('https://cdn.example.com/$id.m4a'),
  semanticLabel: 'Hear $id',
);

Future<void> _pumpAudio(
  WidgetTester tester, {
  required String ownerId,
  required PlayAudioAsset asset,
  required _FakeAudioEngine engine,
  required ActiveMediaCoordinator coordinator,
  bool active = true,
  PlayAudioErrorCallback? onError,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: OwnedPlayAudio(
        ownerId: ownerId,
        asset: asset,
        engine: engine,
        coordinator: coordinator,
        active: active,
        onError: onError,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  test('audio assets require absolute HTTPS', () {
    expect(
      () => PlayAudioAsset(id: 'a', uri: Uri.parse('http://example.com/a.m4a')),
      throwsArgumentError,
    );
    expect(
      () => PlayAudioAsset(id: 'a', uri: Uri.parse('/a.m4a')),
      throwsArgumentError,
    );
  });

  testWidgets('mounting audio does not allocate or autoplay', (tester) async {
    final engine = _FakeAudioEngine();
    final coordinator = ActiveMediaCoordinator();

    await _pumpAudio(
      tester,
      ownerId: 'play_a',
      asset: _asset('audio_a'),
      engine: engine,
      coordinator: coordinator,
    );

    expect(engine.events, isEmpty);
    expect(coordinator.hasActiveMedia, isFalse);
    expect(find.text('Hear'), findsOneWidget);
  });

  testWidgets('Hear lazily loads, acquires ownership, and plays', (tester) async {
    final engine = _FakeAudioEngine();
    final coordinator = ActiveMediaCoordinator();

    await _pumpAudio(
      tester,
      ownerId: 'play_a',
      asset: _asset('audio_a'),
      engine: engine,
      coordinator: coordinator,
    );
    await tester.tap(find.text('Hear'));
    await tester.pumpAndSettle();

    expect(engine.events, ['load:audio_a', 'play:audio_a']);
    expect(coordinator.ownerId, 'play_a');
    expect(coordinator.hasActiveMedia, isTrue);
    expect(find.text('Replay'), findsOneWidget);
  });

  testWidgets('play failure releases ownership and fails closed', (tester) async {
    final engine = _FakeAudioEngine()..playError = StateError('play failed');
    final coordinator = ActiveMediaCoordinator();
    final observed = <Object>[];

    await _pumpAudio(
      tester,
      ownerId: 'play_a',
      asset: _asset('audio_a'),
      engine: engine,
      coordinator: coordinator,
      onError: (asset, error, stackTrace) => observed.add(error),
    );
    await tester.tap(find.text('Hear'));
    await tester.pumpAndSettle();

    expect(
      engine.events,
      ['load:audio_a', 'play:audio_a', 'stop:audio_a', 'release:audio_a'],
    );
    expect(coordinator.hasActiveMedia, isFalse);
    expect(find.byType(PlayAudioUnavailable), findsOneWidget);
    expect(observed.whereType<StateError>(), isNotEmpty);
  });

  testWidgets('load failure attempts cleanup without acquiring ownership', (
    tester,
  ) async {
    final engine = _FakeAudioEngine()..loadError = StateError('load failed');
    final coordinator = ActiveMediaCoordinator();

    await _pumpAudio(
      tester,
      ownerId: 'play_a',
      asset: _asset('audio_a'),
      engine: engine,
      coordinator: coordinator,
    );
    await tester.tap(find.text('Hear'));
    await tester.pumpAndSettle();

    expect(engine.events, ['load:audio_a', 'release:audio_a']);
    expect(coordinator.hasActiveMedia, isFalse);
    expect(find.byType(PlayAudioUnavailable), findsOneWidget);
  });

  testWidgets('reconfiguration releases through the original coordinator', (
    tester,
  ) async {
    final engine = _FakeAudioEngine();
    final firstCoordinator = ActiveMediaCoordinator();
    final secondCoordinator = ActiveMediaCoordinator();
    final asset = _asset('audio_a');

    await _pumpAudio(
      tester,
      ownerId: 'play_a',
      asset: asset,
      engine: engine,
      coordinator: firstCoordinator,
    );
    await tester.tap(find.text('Hear'));
    await tester.pumpAndSettle();
    expect(firstCoordinator.hasActiveMedia, isTrue);

    await _pumpAudio(
      tester,
      ownerId: 'play_b',
      asset: asset,
      engine: engine,
      coordinator: secondCoordinator,
    );
    await tester.pumpAndSettle();

    expect(firstCoordinator.hasActiveMedia, isFalse);
    expect(secondCoordinator.hasActiveMedia, isFalse);
    expect(
      engine.events,
      ['load:audio_a', 'play:audio_a', 'stop:audio_a', 'release:audio_a'],
    );
    expect(find.text('Hear'), findsOneWidget);
  });

  testWidgets('suspension stops audio without automatic foreground replay', (
    tester,
  ) async {
    final engine = _FakeAudioEngine();
    final coordinator = ActiveMediaCoordinator();

    await _pumpAudio(
      tester,
      ownerId: 'play_a',
      asset: _asset('audio_a'),
      engine: engine,
      coordinator: coordinator,
    );
    await tester.tap(find.text('Hear'));
    await tester.pumpAndSettle();

    await coordinator.suspend();
    await tester.pump();

    expect(engine.events, ['load:audio_a', 'play:audio_a', 'stop:audio_a']);
    expect(coordinator.hasActiveMedia, isTrue);
    expect(find.text('Replay'), findsOneWidget);
  });

  testWidgets('stale external replacement is never released by audio teardown', (
    tester,
  ) async {
    final engine = _FakeAudioEngine();
    final coordinator = ActiveMediaCoordinator();

    await _pumpAudio(
      tester,
      ownerId: 'play_a',
      asset: _asset('audio_a'),
      engine: engine,
      coordinator: coordinator,
    );
    await tester.tap(find.text('Hear'));
    await tester.pumpAndSettle();

    final replacement = _ReplacementHandle();
    await coordinator.activate('play_a', replacement);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    await tester.pump();

    expect(coordinator.owns('play_a', replacement), isTrue);
    expect(replacement.pauseCount, 0);
    expect(replacement.releaseCount, 0);
  });
}
