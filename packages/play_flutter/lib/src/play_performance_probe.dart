import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';

/// One frame reduced to the timing dimensions Mosaic profiles on devices.
final class PlayFrameSample {
  const PlayFrameSample({
    required this.build,
    required this.raster,
    required this.total,
  });

  factory PlayFrameSample.fromFrameTiming(FrameTiming timing) =>
      PlayFrameSample(
        build: timing.buildDuration,
        raster: timing.rasterDuration,
        total: timing.totalSpan,
      );

  final Duration build;
  final Duration raster;
  final Duration total;
}

/// Bounded summary of a profiling window.
final class PlayFramePerformanceSummary {
  const PlayFramePerformanceSummary({
    required this.targetRefreshHz,
    required this.frameBudget,
    required this.totalFrames,
    required this.overBudgetFrames,
    required this.p50Total,
    required this.p95Total,
    required this.p95Build,
    required this.p95Raster,
    required this.maxTotal,
  });

  final double targetRefreshHz;
  final Duration frameBudget;
  final int totalFrames;
  final int overBudgetFrames;
  final Duration p50Total;
  final Duration p95Total;
  final Duration p95Build;
  final Duration p95Raster;
  final Duration maxTotal;

  double get overBudgetRatio =>
      totalFrames == 0 ? 0 : overBudgetFrames / totalFrames;
}

/// Keeps only a bounded recent profiling window and performs no work unless
/// samples are explicitly recorded.
final class PlayFramePerformanceAccumulator {
  PlayFramePerformanceAccumulator({
    required double targetRefreshHz,
    int maxSamples = 600,
  }) : targetRefreshHz = _validateRefreshRate(targetRefreshHz),
       maxSamples = _validateMaxSamples(maxSamples),
       frameBudget = Duration(
         microseconds: (Duration.microsecondsPerSecond / targetRefreshHz)
             .round(),
       );

  final double targetRefreshHz;
  final int maxSamples;
  final Duration frameBudget;
  final Queue<PlayFrameSample> _samples = Queue<PlayFrameSample>();

  int get sampleCount => _samples.length;

  void record(PlayFrameSample sample) {
    _samples.addLast(sample);
    while (_samples.length > maxSamples) {
      _samples.removeFirst();
    }
  }

  void recordAll(Iterable<PlayFrameSample> samples) {
    for (final sample in samples) {
      record(sample);
    }
  }

  void clear() => _samples.clear();

  PlayFramePerformanceSummary get summary {
    if (_samples.isEmpty) {
      return PlayFramePerformanceSummary(
        targetRefreshHz: targetRefreshHz,
        frameBudget: frameBudget,
        totalFrames: 0,
        overBudgetFrames: 0,
        p50Total: Duration.zero,
        p95Total: Duration.zero,
        p95Build: Duration.zero,
        p95Raster: Duration.zero,
        maxTotal: Duration.zero,
      );
    }

    final samples = _samples.toList(growable: false);
    final totals = samples.map((sample) => sample.total).toList()..sort();
    final builds = samples.map((sample) => sample.build).toList()..sort();
    final rasters = samples.map((sample) => sample.raster).toList()..sort();
    final budgetMicros = frameBudget.inMicroseconds;

    return PlayFramePerformanceSummary(
      targetRefreshHz: targetRefreshHz,
      frameBudget: frameBudget,
      totalFrames: samples.length,
      overBudgetFrames: samples
          .where((sample) => sample.total.inMicroseconds > budgetMicros)
          .length,
      p50Total: _percentile(totals, 0.50),
      p95Total: _percentile(totals, 0.95),
      p95Build: _percentile(builds, 0.95),
      p95Raster: _percentile(rasters, 0.95),
      maxTotal: totals.last,
    );
  }
}

/// Readiness markers captured around the same opt-in frame profiling window.
final class PlayPerformanceSnapshot {
  const PlayPerformanceSnapshot({
    required this.frames,
    required this.firstFrameLatency,
    required this.audioReadyLatency,
  });

  final PlayFramePerformanceSummary frames;
  final Duration? firstFrameLatency;
  final Duration? audioReadyLatency;
}

/// Opt-in physical-device profiling probe.
///
/// Constructing this class has no scheduler cost. [start] is the only operation
/// that registers a Flutter timings callback, so normal feed rendering pays no
/// profiling overhead. A profiling harness should call [start] immediately
/// before presenting the Play, call [markAudioReady] when its measured audio
/// path is ready, then call [stop] after the sampling window.
final class PlayPerformanceProbe {
  PlayPerformanceProbe({required double targetRefreshHz, int maxSamples = 600})
    : _frames = PlayFramePerformanceAccumulator(
        targetRefreshHz: targetRefreshHz,
        maxSamples: maxSamples,
      );

  final PlayFramePerformanceAccumulator _frames;
  bool _running = false;
  int? _startedAtMicros;
  Duration? _firstFrameLatency;
  Duration? _audioReadyLatency;

  bool get isRunning => _running;

  void start() {
    if (_running) {
      throw StateError('Play performance probe is already running.');
    }
    _frames.clear();
    _firstFrameLatency = null;
    _audioReadyLatency = null;
    _startedAtMicros = developer.Timeline.now;
    SchedulerBinding.instance.addTimingsCallback(_recordTimings);
    _running = true;
  }

  void markAudioReady() {
    final startedAt = _startedAtMicros;
    if (!_running || startedAt == null || _audioReadyLatency != null) return;
    _audioReadyLatency = _elapsedSince(startedAt, developer.Timeline.now);
  }

  PlayPerformanceSnapshot stop() {
    if (_running) {
      SchedulerBinding.instance.removeTimingsCallback(_recordTimings);
      _running = false;
    }
    _startedAtMicros = null;
    return snapshot;
  }

  PlayPerformanceSnapshot get snapshot => PlayPerformanceSnapshot(
    frames: _frames.summary,
    firstFrameLatency: _firstFrameLatency,
    audioReadyLatency: _audioReadyLatency,
  );

  void dispose() {
    if (_running) {
      SchedulerBinding.instance.removeTimingsCallback(_recordTimings);
      _running = false;
    }
    _startedAtMicros = null;
  }

  void _recordTimings(List<FrameTiming> timings) {
    if (!_running || timings.isEmpty) return;
    final startedAt = _startedAtMicros;
    if (startedAt != null && _firstFrameLatency == null) {
      final firstFinish = timings.first.timestampInMicroseconds(
        FramePhase.rasterFinish,
      );
      _firstFrameLatency = _elapsedSince(startedAt, firstFinish);
    }
    _frames.recordAll(timings.map(PlayFrameSample.fromFrameTiming));
  }
}

double _validateRefreshRate(double value) {
  if (!value.isFinite || value <= 0) {
    throw ArgumentError.value(value, 'targetRefreshHz', 'must be positive');
  }
  return value;
}

int _validateMaxSamples(int value) {
  if (value <= 0) {
    throw ArgumentError.value(value, 'maxSamples', 'must be positive');
  }
  return value;
}

Duration _percentile(List<Duration> sorted, double percentile) {
  final index = math.max(
    0,
    math.min(sorted.length - 1, (percentile * sorted.length).ceil() - 1),
  );
  return sorted[index];
}

Duration _elapsedSince(int startMicros, int endMicros) => Duration(
  microseconds: math.max(0, endMicros - startMicros),
);
