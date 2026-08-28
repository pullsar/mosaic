import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

final class _ReferenceAudioEngine implements AudioEngine {
  final List<String> events = <String>[];

  @override
  Map<String, num> get latencyMetrics => const <String, num>{};

  @override
  Future<void> load(String assetId, Uri uri) async {
    events.add('load:$assetId');
  }

  @override
  Future<void> play(String assetId) async {
    events.add('play:$assetId');
  }

  @override
  Future<void> release(String assetId) async {
    events.add('release:$assetId');
  }

  @override
  Future<void> schedule(String assetId, Duration offset) async {
    events.add('schedule:$assetId');
  }

  @override
  Future<void> stop(String assetId) async {
    events.add('stop:$assetId');
  }
}

PlayDocument _playFixture(String name) {
  final raw =
      jsonDecode(File('../play_schema/fixtures/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayDocument.fromJson(raw);
}

PlayAudioAsset _audioFixture(String name) {
  final raw =
      jsonDecode(File('fixtures/audio/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayAudioAssetCodec.decode(raw);
}

PlayMediaLayerBuilder _mediaBuilder(
  PlayDocument play,
  PlayAudioAsset audio,
  _ReferenceAudioEngine engine,
) => PlayMediaLayerBuilder(
  ownerId: playMediaOwnerId(play),
  visualResolver: MapPlayVisualAssetResolver(const {}),
  videoResolver: MapPlayVideoAssetResolver(const {}),
  audioResolver: MapPlayAudioAssetResolver({audio.id: audio}),
  audioEngine: engine,
  mediaCoordinator: ActiveMediaCoordinator(),
  videoControllerFactory: (_) =>
      throw StateError('Video controller should not be requested.'),
);

void main() {
  test('managed audio asset fixtures decode without answer-leaking semantics', () {
    final note = _audioFixture('audio_csharp4.json');
    final pattern = _audioFixture('audio_ceg.json');

    expect(note.id, 'audio_csharp4');
    expect(note.semanticLabel, 'Hear piano note');
    expect(note.semanticLabel, isNot(contains('sharp')));
    expect(pattern.id, 'audio_ceg');
    expect(pattern.semanticLabel, 'Hear piano pattern');
  });

  testWidgets('Which piano key uses managed audio only after Hear', (
    tester,
  ) async {
    final play = _playFixture('which_piano_key.json');
    final audio = _audioFixture('audio_csharp4.json');
    final engine = _ReferenceAudioEngine();
    final media = _mediaBuilder(play, audio, engine);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaySurface(play: play, mediaBuilder: media.call),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Which note?'), findsOneWidget);
    expect(find.text('Hear'), findsOneWidget);
    expect(engine.events, isEmpty);

    await tester.tap(find.text('Hear'));
    await tester.pumpAndSettle();
    expect(engine.events, ['load:audio_csharp4', 'play:audio_csharp4']);

    await tester.tap(find.text('C♯'));
    await tester.pump();
    expect(find.text('C♯'), findsWidgets);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('Play it back uses managed audio and authored piano sequence', (
    tester,
  ) async {
    final play = _playFixture('play_it_back.json');
    final audio = _audioFixture('audio_ceg.json');
    final engine = _ReferenceAudioEngine();
    final media = _mediaBuilder(play, audio, engine);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaySurface(play: play, mediaBuilder: media.call),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Play it back.'), findsOneWidget);
    expect(engine.events, isEmpty);

    await tester.tap(find.text('Hear'));
    await tester.pumpAndSettle();
    expect(engine.events, ['load:audio_ceg', 'play:audio_ceg']);

    await tester.tap(find.text('C'));
    await tester.tap(find.text('E'));
    await tester.tap(find.text('G'));
    await tester.pump();

    expect(find.text('C · E · G'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  test('audio codec rejects unsupported versions and non-HTTPS media', () {
    expect(
      () => PlayAudioAssetCodec.decode({
        'schemaVersion': 2,
        'id': 'a',
        'uri': 'https://cdn.example.com/a.m4a',
      }),
      throwsFormatException,
    );
    expect(
      () => PlayAudioAssetCodec.decode({
        'schemaVersion': 1,
        'id': 'a',
        'uri': 'http://cdn.example.com/a.m4a',
      }),
      throwsArgumentError,
    );
  });
}
