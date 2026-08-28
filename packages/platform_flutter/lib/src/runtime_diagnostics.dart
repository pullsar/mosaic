import 'package:flutter/foundation.dart';
import 'package:platform_contracts/runtime_diagnostics.dart';

import 'runtime_browser_stub.dart'
    if (dart.library.js_interop) 'runtime_browser_web.dart' as browser;

final class FlutterRuntimeDiagnostics implements RuntimeDiagnosticsProvider {
  const FlutterRuntimeDiagnostics();

  @override
  RuntimeDiagnosticSnapshot snapshot() => RuntimeDiagnosticSnapshot(
    runtime: kIsWeb ? MosaicRuntimeKind.web : MosaicRuntimeKind.native,
    operatingSystem: _operatingSystem(defaultTargetPlatform),
    browser: kIsWeb ? browser.currentBrowserFamily() : MosaicBrowserFamily.none,
  );
}

MosaicOperatingSystem _operatingSystem(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => MosaicOperatingSystem.android,
  TargetPlatform.iOS => MosaicOperatingSystem.ios,
  TargetPlatform.macOS => MosaicOperatingSystem.macos,
  TargetPlatform.windows => MosaicOperatingSystem.windows,
  TargetPlatform.linux => MosaicOperatingSystem.linux,
  TargetPlatform.fuchsia => MosaicOperatingSystem.fuchsia,
};
