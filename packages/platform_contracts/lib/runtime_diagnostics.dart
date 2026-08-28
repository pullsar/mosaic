enum MosaicRuntimeKind { native, web }

enum MosaicOperatingSystem {
  android,
  ios,
  macos,
  windows,
  linux,
  fuchsia,
  unknown,
}

enum MosaicBrowserFamily { none, safari, chrome, firefox, edge, other }

/// Coarse runtime dimensions suitable for operational playback diagnostics.
///
/// This contract deliberately excludes raw user-agent strings, device model,
/// advertising identifiers, IP-derived location and other fingerprinting data.
final class RuntimeDiagnosticSnapshot {
  const RuntimeDiagnosticSnapshot({
    required this.runtime,
    required this.operatingSystem,
    required this.browser,
  });

  final MosaicRuntimeKind runtime;
  final MosaicOperatingSystem operatingSystem;
  final MosaicBrowserFamily browser;

  Map<String, String> toPayload() => {
    'runtime': runtime.name,
    'operatingSystem': operatingSystem.name,
    'browser': browser.name,
  };
}

abstract interface class RuntimeDiagnosticsProvider {
  RuntimeDiagnosticSnapshot snapshot();
}
