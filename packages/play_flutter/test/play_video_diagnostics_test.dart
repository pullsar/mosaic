import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:platform_contracts/runtime_diagnostics.dart';
import 'package:play_flutter/play_flutter.dart';

final class _TelemetryEvent {
  const _TelemetryEvent(this.name, this.payload);

  final String name;
  final Map<String, Object?> payload;
}

final class _FakeTelemetry implements Telemetry {
  final events = <_TelemetryEvent>[];

  @override
  void event(String name, Map<String, Object?> payload) {
    events.add(_TelemetryEvent(name, Map<String, Object?>.from(payload)));
  }

  @override
  void error(Object error, StackTrace stackTrace, {String? operation}) {}

  @override
  FutureOr<T> trace<T>(String operation, FutureOr<T> Function() body) => body();
}

final class _Runtime implements RuntimeDiagnosticsProvider {
  const _Runtime(this.value);

  final RuntimeDiagnosticSnapshot value;

  @override
  RuntimeDiagnosticSnapshot snapshot() => value;
}

const _runtime = _Runtime(
  RuntimeDiagnosticSnapshot(
    runtime: MosaicRuntimeKind.web,
    operatingSystem: MosaicOperatingSystem.ios,
    browser: MosaicBrowserFamily.safari,
  ),
);

void main() {
  test('first-frame diagnostic records format and coarse browser dimensions', () {
    final telemetry = _FakeTelemetry();
    final observer = PlayVideoDiagnosticObserver(
      telemetry: telemetry,
      runtimeDiagnostics: _runtime,
    );

    observer(
      PlayVideoPlaybackEvent(
        assetId: 'asset_1',
        phase: PlayVideoPlaybackPhase.firstFramePainted,
        sourceType: 'network',
        elapsed: const Duration(milliseconds: 340),
        format: PlayVideoFormatMetadata(
          container: 'mp4',
          videoCodec: 'h264',
          videoProfile: 'main',
          audioCodec: 'aac',
        ),
      ),
    );

    expect(telemetry.events, hasLength(1));
    expect(telemetry.events.single.name, 'media_playback');
    expect(telemetry.events.single.payload, {
      'assetId': 'asset_1',
      'phase': 'firstFramePainted',
      'sourceType': 'network',
      'runtime': 'web',
      'operatingSystem': 'ios',
      'browser': 'safari',
      'elapsedMs': 340,
      'container': 'mp4',
      'videoCodec': 'h264',
      'videoProfile': 'main',
      'audioCodec': 'aac',
    });
  });

  test('playback error records error type without retaining the message', () {
    final telemetry = _FakeTelemetry();
    final observer = PlayVideoDiagnosticObserver(
      telemetry: telemetry,
      runtimeDiagnostics: _runtime,
    );

    observer(
      PlayVideoPlaybackEvent(
        assetId: 'asset_2',
        phase: PlayVideoPlaybackPhase.playbackError,
        sourceType: 'network',
        error: StateError('decoder detail'),
        format: PlayVideoFormatMetadata(
          videoCodec: 'h264',
          videoProfile: 'main',
        ),
      ),
    );

    final payload = telemetry.events.single.payload;
    expect(payload['errorType'], 'StateError');
    expect(payload.values, isNot(contains('decoder detail')));
    expect(payload.containsKey('userAgent'), isFalse);
  });

  test('non-compatibility phases do not emit diagnostic events', () {
    final telemetry = _FakeTelemetry();
    final observer = PlayVideoDiagnosticObserver(
      telemetry: telemetry,
      runtimeDiagnostics: _runtime,
    );

    for (final phase in <PlayVideoPlaybackPhase>[
      PlayVideoPlaybackPhase.initialized,
      PlayVideoPlaybackPhase.autoplayStarted,
      PlayVideoPlaybackPhase.autoplayBlocked,
      PlayVideoPlaybackPhase.userPlaybackStarted,
    ]) {
      observer(
        PlayVideoPlaybackEvent(
          assetId: 'asset',
          phase: phase,
          sourceType: 'network',
        ),
      );
    }

    expect(telemetry.events, isEmpty);
  });
}
