import 'dart:async';

import 'package:platform_contracts/platform_contracts.dart';
import 'package:test/test.dart';

final class _Handle implements ManagedMediaHandle {
  _Handle(
    this.name,
    this.events, {
    this.releaseGate,
    this.pauseError,
    this.releaseError,
  });

  final String name;
  final List<String> events;
  final Completer<void>? releaseGate;
  final Object? pauseError;
  final Object? releaseError;
  var pauseCount = 0;
  var releaseCount = 0;

  @override
  Future<void> pause() async {
    pauseCount += 1;
    events.add('$name.pause');
    final error = pauseError;
    if (error != null) throw error;
  }

  @override
  Future<void> release() async {
    releaseCount += 1;
    events.add('$name.release:start');
    await releaseGate?.future;
    final error = releaseError;
    if (error != null) throw error;
    events.add('$name.release:end');
  }
}

final class _PermissionGateway implements PermissionGateway {
  MosaicPermissionState state = MosaicPermissionState.denied;
  final checked = <MosaicPermission>[];
  final requested = <MosaicPermission>[];

  @override
  Future<MosaicPermissionState> check(MosaicPermission permission) async {
    checked.add(permission);
    return state;
  }

  @override
  Future<MosaicPermissionState> request(MosaicPermission permission) async {
    requested.add(permission);
    return state;
  }
}

void main() {
  test('activating a new owner releases previous media', () async {
    final coordinator = ActiveMediaCoordinator();
    final events = <String>[];
    final first = _Handle('first', events);
    final second = _Handle('second', events);

    await coordinator.activate('play_a', first);
    await coordinator.activate('play_b', second);

    expect(first.pauseCount, 1);
    expect(first.releaseCount, 1);
    expect(second.pauseCount, 0);
    expect(second.releaseCount, 0);
    expect(coordinator.ownerId, 'play_b');
  });

  test(
    'rapid activations are serialized and release intermediate media',
    () async {
      final coordinator = ActiveMediaCoordinator();
      final events = <String>[];
      final firstRelease = Completer<void>();
      final first = _Handle('first', events, releaseGate: firstRelease);
      final second = _Handle('second', events);
      final third = _Handle('third', events);
      await coordinator.activate('play_a', first);

      final activateSecond = coordinator.activate('play_b', second);
      await Future<void>.delayed(Duration.zero);
      final activateThird = coordinator.activate('play_c', third);
      await Future<void>.delayed(Duration.zero);

      expect(events, ['first.pause', 'first.release:start']);
      expect(second.pauseCount, 0);

      firstRelease.complete();
      await Future.wait([activateSecond, activateThird]);

      expect(second.pauseCount, 1);
      expect(second.releaseCount, 1);
      expect(coordinator.ownerId, 'play_c');
      expect(coordinator.hasActiveMedia, isTrue);
    },
  );

  test('pause failure still attempts release and preserves retry ownership', () async {
    final coordinator = ActiveMediaCoordinator();
    final events = <String>[];
    final pauseFailure = StateError('pause failed');
    final first = _Handle('first', events, pauseError: pauseFailure);
    final second = _Handle('second', events);
    await coordinator.activate('play_a', first);

    await expectLater(
      coordinator.activate('play_b', second),
      throwsA(same(pauseFailure)),
    );

    expect(first.pauseCount, 1);
    expect(first.releaseCount, 1);
    expect(coordinator.ownerId, 'play_a');
    expect(coordinator.hasActiveMedia, isTrue);
    expect(second.pauseCount, 0);
  });

  test('stale release cannot discard a replacement with the same owner ID', () async {
    final coordinator = ActiveMediaCoordinator();
    final events = <String>[];
    final first = _Handle('first', events);
    final replacement = _Handle('replacement', events);

    await coordinator.activate('play_a', first);
    await coordinator.activate('play_a', replacement);
    await coordinator.release('play_a', expectedHandle: first);

    expect(coordinator.ownerId, 'play_a');
    expect(coordinator.hasActiveMedia, isTrue);
    expect(replacement.pauseCount, 0);
    expect(replacement.releaseCount, 0);

    await coordinator.release('play_a', expectedHandle: replacement);
    expect(replacement.pauseCount, 1);
    expect(replacement.releaseCount, 1);
    expect(coordinator.hasActiveMedia, isFalse);
  });

  test('suspension pauses without discarding ownership', () async {
    final coordinator = ActiveMediaCoordinator();
    final events = <String>[];
    final handle = _Handle('active', events);

    await coordinator.activate('play_a', handle);
    await coordinator.suspend();

    expect(handle.pauseCount, 1);
    expect(handle.releaseCount, 0);
    expect(coordinator.ownerId, 'play_a');
  });

  test(
    'releaseAll clears active media after native release completes',
    () async {
      final coordinator = ActiveMediaCoordinator();
      final events = <String>[];
      final releaseGate = Completer<void>();
      final handle = _Handle('active', events, releaseGate: releaseGate);
      await coordinator.activate('play_a', handle);

      final release = coordinator.releaseAll();
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.ownerId, 'play_a');

      releaseGate.complete();
      await release;
      expect(handle.pauseCount, 1);
      expect(handle.releaseCount, 1);
      expect(coordinator.hasActiveMedia, isFalse);
    },
  );

  test('permission service maps only the invoked user action', () async {
    final gateway = _PermissionGateway();
    final service = ContextualPermissionService(gateway);

    final state = await service.requestFromUserAction(
      PermissionUseCase.microphoneRecording,
    );

    expect(state, MosaicPermissionState.denied);
    expect(gateway.requested, [MosaicPermission.microphone]);
    expect(gateway.checked, isEmpty);
  });

  test('permission denial cannot mutate caller-owned draft state', () async {
    final gateway = _PermissionGateway();
    final service = ContextualPermissionService(gateway);
    final draft = <String, Object?>{'id': 'draft_1', 'caption': 'Still here'};
    final snapshot = Map<String, Object?>.of(draft);

    final state = await service.requestFromUserAction(
      PermissionUseCase.cameraCapture,
    );

    expect(state, MosaicPermissionState.denied);
    expect(draft, snapshot);
  });
}
