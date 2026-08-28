import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

PlayFrameSample _sample({
  required int totalMs,
  int? buildMs,
  int? rasterMs,
}) => PlayFrameSample(
  build: Duration(milliseconds: buildMs ?? totalMs ~/ 2),
  raster: Duration(milliseconds: rasterMs ?? totalMs ~/ 3),
  total: Duration(milliseconds: totalMs),
);

void main() {
  group('PlayFramePerformanceAccumulator', () {
    test('rejects impossible refresh rates and sample windows', () {
      for (final refreshRate in <double>[0, -1, double.infinity, double.nan]) {
        expect(
          () => PlayFramePerformanceAccumulator(
            targetRefreshHz: refreshRate,
          ),
          throwsArgumentError,
        );
      }

      expect(
        () => PlayFramePerformanceAccumulator(
          targetRefreshHz: 60,
          maxSamples: 0,
        ),
        throwsArgumentError,
      );
    });

    test('summarizes a 60 Hz profiling window deterministically', () {
      final accumulator = PlayFramePerformanceAccumulator(
        targetRefreshHz: 60,
      )..recordAll(<PlayFrameSample>[
        _sample(totalMs: 8, buildMs: 3, rasterMs: 4),
        _sample(totalMs: 10, buildMs: 4, rasterMs: 5),
        _sample(totalMs: 12, buildMs: 5, rasterMs: 6),
        _sample(totalMs: 17, buildMs: 6, rasterMs: 10),
        _sample(totalMs: 25, buildMs: 9, rasterMs: 14),
      ]);

      final summary = accumulator.summary;

      expect(summary.frameBudget.inMicroseconds, 16667);
      expect(summary.totalFrames, 5);
      expect(summary.overBudgetFrames, 2);
      expect(summary.overBudgetRatio, closeTo(0.4, 0.0001));
      expect(summary.p50Total, const Duration(milliseconds: 12));
      expect(summary.p95Total, const Duration(milliseconds: 25));
      expect(summary.p95Build, const Duration(milliseconds: 9));
      expect(summary.p95Raster, const Duration(milliseconds: 14));
      expect(summary.maxTotal, const Duration(milliseconds: 25));
    });

    test('uses the tighter 120 Hz frame budget', () {
      final accumulator = PlayFramePerformanceAccumulator(
        targetRefreshHz: 120,
      )..recordAll(<PlayFrameSample>[
        _sample(totalMs: 8),
        _sample(totalMs: 9),
      ]);

      final summary = accumulator.summary;

      expect(summary.frameBudget.inMicroseconds, 8333);
      expect(summary.totalFrames, 2);
      expect(summary.overBudgetFrames, 1);
      expect(summary.overBudgetRatio, 0.5);
    });

    test('retains only the bounded most-recent sample window', () {
      final accumulator = PlayFramePerformanceAccumulator(
        targetRefreshHz: 60,
        maxSamples: 3,
      )..recordAll(<PlayFrameSample>[
        _sample(totalMs: 5),
        _sample(totalMs: 10),
        _sample(totalMs: 15),
        _sample(totalMs: 20),
      ]);

      final summary = accumulator.summary;

      expect(accumulator.sampleCount, 3);
      expect(summary.totalFrames, 3);
      expect(summary.p50Total, const Duration(milliseconds: 15));
      expect(summary.maxTotal, const Duration(milliseconds: 20));
      expect(summary.overBudgetFrames, 1);
    });

    test('empty windows report zero-valued statistics', () {
      final summary = PlayFramePerformanceAccumulator(
        targetRefreshHz: 60,
      ).summary;

      expect(summary.totalFrames, 0);
      expect(summary.overBudgetFrames, 0);
      expect(summary.overBudgetRatio, 0);
      expect(summary.p50Total, Duration.zero);
      expect(summary.p95Total, Duration.zero);
      expect(summary.p95Build, Duration.zero);
      expect(summary.p95Raster, Duration.zero);
      expect(summary.maxTotal, Duration.zero);
    });
  });

  test('constructing a performance probe is inert until explicitly started', () {
    final probe = PlayPerformanceProbe(targetRefreshHz: 60);
    addTearDown(probe.dispose);

    expect(probe.isRunning, isFalse);
    expect(probe.snapshot.frames.totalFrames, 0);
    expect(probe.snapshot.firstFrameLatency, isNull);
    expect(probe.snapshot.audioReadyLatency, isNull);
  });
}
