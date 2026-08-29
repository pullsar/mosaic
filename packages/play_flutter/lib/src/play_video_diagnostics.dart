import 'package:platform_contracts/platform_contracts.dart';
import 'package:platform_contracts/runtime_diagnostics.dart';

import 'play_video_renderer.dart';

abstract final class PlayVideoDiagnosticEventName {
  static const playback = 'media_playback';
}

/// Converts renderer playback outcomes into bounded operational telemetry.
///
/// Only first-frame success and hard playback errors are emitted because those
/// are the compatibility signals used by the device/browser matrix. Error
/// messages and raw user-agent strings are intentionally excluded.
final class PlayVideoDiagnosticObserver {
  const PlayVideoDiagnosticObserver({
    required this.telemetry,
    required this.runtimeDiagnostics,
  });

  final Telemetry telemetry;
  final RuntimeDiagnosticsProvider runtimeDiagnostics;

  void call(PlayVideoPlaybackEvent event) {
    if (event.phase != PlayVideoPlaybackPhase.firstFramePainted &&
        event.phase != PlayVideoPlaybackPhase.playbackError) {
      return;
    }

    final format = event.format;
    final payload = <String, Object?>{
      'assetId': event.assetId,
      'phase': event.phase.name,
      'sourceType': event.sourceType,
      ...runtimeDiagnostics.snapshot().toPayload(),
      if (event.elapsed != null) 'elapsedMs': event.elapsed!.inMilliseconds,
      if (format?.container != null) 'container': format!.container,
      if (format?.videoCodec != null) 'videoCodec': format!.videoCodec,
      if (format?.videoProfile != null) 'videoProfile': format!.videoProfile,
      if (format?.audioCodec != null) 'audioCodec': format!.audioCodec,
      if (event.phase == PlayVideoPlaybackPhase.playbackError &&
          event.error != null)
        'errorType': event.error.runtimeType.toString(),
    };
    telemetry.event(PlayVideoDiagnosticEventName.playback, payload);
  }
}
