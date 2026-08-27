import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:platform_contracts/platform_contracts.dart';

typedef SemanticResumeCallback = FutureOr<void> Function();

AppRuntimeState mapFlutterLifecycleState(AppLifecycleState state) =>
    switch (state) {
      AppLifecycleState.resumed => AppRuntimeState.resumed,
      AppLifecycleState.inactive => AppRuntimeState.inactive,
      AppLifecycleState.paused => AppRuntimeState.paused,
      AppLifecycleState.hidden => AppRuntimeState.hidden,
      AppLifecycleState.detached => AppRuntimeState.detached,
    };

final class FlutterLifecycleBridge {
  FlutterLifecycleBridge({
    required this.mediaCoordinator,
    this.onSemanticResume,
  }) {
    _listener = AppLifecycleListener(onStateChange: _onStateChange);
  }

  final ActiveMediaCoordinator mediaCoordinator;
  final SemanticResumeCallback? onSemanticResume;
  late final AppLifecycleListener _listener;

  void _onStateChange(AppLifecycleState state) {
    unawaited(handleState(mapFlutterLifecycleState(state)));
  }

  Future<void> handleState(AppRuntimeState state) async {
    if (state == AppRuntimeState.resumed) {
      final callback = onSemanticResume;
      if (callback != null) await Future<void>.sync(callback);
      return;
    }
    if (state == AppRuntimeState.detached) {
      await mediaCoordinator.releaseAll();
      return;
    }
    await mediaCoordinator.suspend();
  }

  void dispose() => _listener.dispose();
}
