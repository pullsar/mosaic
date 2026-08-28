import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

void main() {
  test('SoLoud adapter exposes the configured low-latency device contract', () {
    final metrics = SoLoudAudioEngine().latencyMetrics;

    expect(metrics['sampleRateHz'], 44100);
    expect(metrics['bufferFrames'], 1024);
    expect(metrics['estimatedBufferMs'], closeTo(23.22, 0.01));
  });

  test(
    'SoLoud adapter rejects insecure media before native initialization',
    () async {
      final engine = SoLoudAudioEngine();

      await expectLater(
        engine.load('audio_a', Uri.parse('http://cdn.example.com/audio_a.m4a')),
        throwsArgumentError,
      );
    },
  );

  test(
    'SoLoud adapter rejects negative scheduling before source lookup',
    () async {
      final engine = SoLoudAudioEngine();

      await expectLater(
        engine.schedule('audio_a', const Duration(microseconds: -1)),
        throwsArgumentError,
      );
    },
  );

  test('unused SoLoud disposal stays headless', () async {
    final engine = SoLoudAudioEngine();

    await engine.dispose();

    expect(engine.latencyMetrics['sampleRateHz'], 44100);
  });
}
