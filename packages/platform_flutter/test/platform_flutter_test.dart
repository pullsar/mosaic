import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:platform_flutter/platform_flutter.dart';

final class _Handle implements ManagedMediaHandle {
  _Handle({this.pauseGate});

  final Completer<void>? pauseGate;
  var pauseCount = 0;
  var releaseCount = 0;

  @override
  Future<void> pause() async {
    pauseCount += 1;
    await pauseGate?.future;
  }

  @override
  Future<void> release() async {
    releaseCount += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('maps every Flutter lifecycle state into Mosaic domain state', () {
    expect(
      mapFlutterLifecycleState(AppLifecycleState.resumed),
      AppRuntimeState.resumed,
    );
    expect(
      mapFlutterLifecycleState(AppLifecycleState.inactive),
      AppRuntimeState.inactive,
    );
    expect(
      mapFlutterLifecycleState(AppLifecycleState.paused),
      AppRuntimeState.paused,
    );
    expect(
      mapFlutterLifecycleState(AppLifecycleState.hidden),
      AppRuntimeState.hidden,
    );
    expect(
      mapFlutterLifecycleState(AppLifecycleState.detached),
      AppRuntimeState.detached,
    );
  });

  test(
    'background state pauses media and detached state releases it',
    () async {
      final coordinator = ActiveMediaCoordinator();
      final handle = _Handle();
      await coordinator.activate('play_a', handle);

      final bridge = FlutterLifecycleBridge(mediaCoordinator: coordinator);
      await bridge.handleState(AppRuntimeState.paused);
      expect(handle.pauseCount, 1);
      expect(handle.releaseCount, 0);

      await bridge.handleState(AppRuntimeState.detached);
      expect(handle.pauseCount, 2);
      expect(handle.releaseCount, 1);
      bridge.dispose();
    },
  );

  test('resume waits for the preceding pause transition', () async {
    final pauseGate = Completer<void>();
    final coordinator = ActiveMediaCoordinator();
    final handle = _Handle(pauseGate: pauseGate);
    await coordinator.activate('play_a', handle);
    var resumed = 0;
    final bridge = FlutterLifecycleBridge(
      mediaCoordinator: coordinator,
      onSemanticResume: () => resumed += 1,
    );

    final pause = bridge.handleState(AppRuntimeState.paused);
    await Future<void>.delayed(Duration.zero);
    final resume = bridge.handleState(AppRuntimeState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(resumed, 0);

    pauseGate.complete();
    await Future.wait([pause, resume]);
    expect(resumed, 1);
    bridge.dispose();
  });

  test(
    'resume invokes semantic recovery instead of assuming controller continuity',
    () async {
      final coordinator = ActiveMediaCoordinator();
      var resumed = 0;
      final bridge = FlutterLifecycleBridge(
        mediaCoordinator: coordinator,
        onSemanticResume: () => resumed += 1,
      );

      await bridge.handleState(AppRuntimeState.resumed);
      expect(resumed, 1);
      bridge.dispose();
    },
  );

  test('permission statuses collapse into concise Mosaic states', () {
    expect(
      mapPermissionStatus(PermissionStatus.granted),
      MosaicPermissionState.granted,
    );
    expect(
      mapPermissionStatus(PermissionStatus.limited),
      MosaicPermissionState.granted,
    );
    expect(
      mapPermissionStatus(PermissionStatus.provisional),
      MosaicPermissionState.granted,
    );
    expect(
      mapPermissionStatus(PermissionStatus.denied),
      MosaicPermissionState.denied,
    );
    expect(
      mapPermissionStatus(PermissionStatus.restricted),
      MosaicPermissionState.restricted,
    );
    expect(
      mapPermissionStatus(PermissionStatus.permanentlyDenied),
      MosaicPermissionState.permanentlyDenied,
    );
  });

  test(
    'permission gateway requests only the mapped native permission',
    () async {
      Permission? requested;
      final gateway = FlutterPermissionGateway(
        requestStatus: (permission) async {
          requested = permission;
          return PermissionStatus.denied;
        },
      );

      final state = await gateway.request(MosaicPermission.microphone);

      expect(requested, Permission.microphone);
      expect(state, MosaicPermissionState.denied);
    },
  );

  test('unsupported native permission adapters fail closed', () async {
    final gateway = FlutterPermissionGateway(
      checkStatus: (_) async => throw UnsupportedError('web'),
    );

    final state = await gateway.check(MosaicPermission.notifications);

    expect(state, MosaicPermissionState.unsupported);
  });
}
