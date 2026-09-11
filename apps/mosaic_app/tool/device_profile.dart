// Opt-in device harness. The normal app entrypoint has no profiling overhead.
// flutter run --profile -t tool/device_profile.dart \
//   --dart-define=MOSAIC_API_BASE_URL=https://api.mixli.app/
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:mosaic_app/main.dart' as app;
import 'package:play_flutter/play_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await app.main();
  Timer(const Duration(seconds: 15), () {
    final refresh = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .first
        .display
        .refreshRate;
    final probe = PlayPerformanceProbe(
      targetRefreshHz: refresh > 0 ? refresh : 60,
      maxSamples: 2400,
    )..start();
    debugPrint('MIXLI_PROFILE sampling started');
    Timer(const Duration(seconds: 60), () {
      final frames = probe.stop().frames;
      probe.dispose();
      debugPrint(
        'MIXLI_PROFILE ${jsonEncode({'refreshHz': frames.targetRefreshHz, 'frameBudgetUs': frames.frameBudget.inMicroseconds, 'frames': frames.totalFrames, 'overBudgetFrames': frames.overBudgetFrames, 'p95BuildUs': frames.p95Build.inMicroseconds, 'p95RasterUs': frames.p95Raster.inMicroseconds, 'p95TotalUs': frames.p95Total.inMicroseconds})}',
      );
    });
  });
}
