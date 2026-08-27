import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:platform_contracts/platform_contracts.dart';

typedef SemanticResumeCallback = FutureOr<void> Function();
typedef LifecycleErrorCallback =
    void Function(Object error, StackTrace stackTrace);

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
    this.onError,
  }) {
    _listener = AppLifecycleListener(onStateChange: _onStateChange);
  }

  final ActiveMediaCoordinator mediaCoordinator;
  final SemanticResumeCallback? onSemanticResume;
  final LifecycleErrorCallback? onError;
  late final AppLifecycleListener _listener;
  Future<void> _tail = Future<void>.value();
  var _disposed = false;

  void _onStateChange(AppLifecycleState state) {
    final transition = handleState(mapFlutterLifecycleState(state));
    unawaited(
      transition.catchError((Object error, StackTrace stackTrace) {
        final callback = onError;
        if (callback != null) {
          callback(error, stackTrace);
          return;
        }
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'platform_flutter',
            context: ErrorDescription('while applying app lifecycle state'),
          ),
        );
      }),
    );
  }

  /// Applies lifecycle transitions in arrival order.
  ///
  /// A rapid pause/resume cannot rebuild semantic state before native media
  /// has actually paused, and one failed transition does not poison the queue.
  Future<void> handleState(AppRuntimeState state) {
    if (_disposed) return Future<void>.value();
    final completer = Completer<void>();
    _tail = _tail.then((_) async {
      if (_disposed) {
        completer.complete();
        return;
      }
      try {
        await _applyState(state);
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _applyState(AppRuntimeState state) async {
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

  void dispose() {
    _disposed = true;
    _listener.dispose();
  }
}
