from pathlib import Path

path = Path('packages/play_flutter/test/play_surface_golden_test.dart')
if path.exists():
    raise SystemExit('golden test already exists')

path.write_text(r'''import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

const _surfaceKey = ValueKey<String>('golden-play-surface');

final class _GoldenAudioEngine implements AudioEngine {
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

PlayDocument _playFixture(String name) {
  final raw =
      jsonDecode(File('../play_schema/fixtures/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayDocument.fromJson(raw);
}

PlayCanvasAsset _canvasFixture(String name) {
  final raw =
      jsonDecode(File('fixtures/canvas/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayCanvasAsset.fromJson(raw);
}

PlayAudioAsset _audioFixture(String name) {
  final raw =
      jsonDecode(File('fixtures/audio/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayAudioAssetCodec.decode(raw);
}

PlayMediaLayerBuilder _mediaBuilder(
  PlayDocument play, {
  Map<String, PlayVisualAsset> visuals = const <String, PlayVisualAsset>{},
  Map<String, PlayCanvasAsset> canvases = const <String, PlayCanvasAsset>{},
  Map<String, PlayAudioAsset> audio = const <String, PlayAudioAsset>{},
}) => PlayMediaLayerBuilder(
  ownerId: playMediaOwnerId(play),
  visualResolver: MapPlayVisualAssetResolver(visuals),
  videoResolver: MapPlayVideoAssetResolver(const {}),
  audioResolver: MapPlayAudioAssetResolver(audio),
  audioEngine: _GoldenAudioEngine(),
  canvasResolver: MapPlayCanvasAssetResolver(canvases),
  mediaCoordinator: ActiveMediaCoordinator(),
  videoControllerFactory: (_) =>
      throw StateError('Golden harness must not initialize video plugins.'),
);

ThemeData _theme(Brightness brightness) => switch (brightness) {
  Brightness.light => ThemeData(
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF262626)),
  ),
  Brightness.dark => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: MosaicVisualTokens.surface,
    colorScheme: const ColorScheme.dark(
      surface: MosaicVisualTokens.surface,
      onSurface: MosaicVisualTokens.foreground,
    ),
  ),
};

Future<void> _pumpGolden(
  WidgetTester tester, {
  required Size size,
  required PlayDocument play,
  required PlayMediaLayerBuilder media,
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
  bool disableAnimations = false,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(brightness),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: const EdgeInsets.only(top: 24, bottom: 16),
          textScaler: textScaler,
          disableAnimations: disableAnimations,
        ),
        child: Scaffold(
          body: RepaintBoundary(
            key: _surfaceKey,
            child: PlaySurface(play: play, mediaBuilder: media.call),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  testWidgets('compact visual choice entry stays composition-first', (
    tester,
  ) async {
    final play = _playFixture('four_day_getaway.json');
    final canvas = _canvasFixture('getaway_mood_01.json');

    await _pumpGolden(
      tester,
      size: const Size(320, 640),
      play: play,
      media: _mediaBuilder(play, canvases: {canvas.id: canvas}),
    );

    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/four_day_getaway_320x640.png'),
    );
  });

  testWidgets('artwork choice remains legible in dark mode', (tester) async {
    final play = _playFixture('which_century.json');
    final visual = PlayVisualAsset(
      id: 'artwork_01',
      source: MemoryPlayVisualSource(
        File('fixtures/images/artwork_01.png').readAsBytesSync(),
      ),
      semanticLabel: 'Artwork detail',
      fit: BoxFit.contain,
    );

    await _pumpGolden(
      tester,
      size: const Size(390, 844),
      play: play,
      media: _mediaBuilder(play, visuals: {visual.id: visual}),
      brightness: Brightness.dark,
    );

    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/which_century_dark_390x844.png'),
    );
  });

  testWidgets('audio and piano controls tolerate enlarged text', (tester) async {
    final play = _playFixture('play_it_back.json');
    final audio = _audioFixture('audio_ceg.json');

    await _pumpGolden(
      tester,
      size: const Size(390, 844),
      play: play,
      media: _mediaBuilder(play, audio: {audio.id: audio}),
      textScaler: const TextScaler.linear(1.3),
    );

    expect(find.text('Hear'), findsOneWidget);
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/play_it_back_large_text_390x844.png'),
    );
  });

  testWidgets('drag puzzle stays stable with reduced motion requested', (
    tester,
  ) async {
    final play = _playFixture('move_one_match.json');
    final canvas = _canvasFixture('puzzle_match_01.json');
    final solved = _canvasFixture('puzzle_match_01_solved.json');

    await _pumpGolden(
      tester,
      size: const Size(320, 640),
      play: play,
      media: _mediaBuilder(
        play,
        canvases: {canvas.id: canvas, solved.id: solved},
      ),
      disableAnimations: true,
    );

    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/move_one_match_reduced_motion_320x640.png'),
    );
  });

  testWidgets('choice reveal remains concise on a compact surface', (
    tester,
  ) async {
    final play = _playFixture('four_day_getaway.json');
    final canvas = _canvasFixture('getaway_mood_01.json');

    await _pumpGolden(
      tester,
      size: const Size(320, 640),
      play: play,
      media: _mediaBuilder(play, canvases: {canvas.id: canvas}),
    );
    await tester.tap(find.text('Marrakech'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/four_day_getaway_reveal_320x640.png'),
    );
  });
}
''')
