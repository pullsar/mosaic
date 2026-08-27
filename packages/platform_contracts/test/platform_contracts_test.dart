import 'package:platform_contracts/platform_contracts.dart';
import 'package:test/test.dart';

final class _Handle implements ManagedMediaHandle {
  var pauseCount = 0;
  var releaseCount = 0;

  @override
  Future<void> pause() async {
    pauseCount += 1;
  }

  @override
  Future<void> release() async {
    releaseCount += 1;
  }
}

void main() {
  test('activating a new owner releases previous media', () async {
    final coordinator = ActiveMediaCoordinator();
    final first = _Handle();
    final second = _Handle();

    await coordinator.activate('play_a', first);
    await coordinator.activate('play_b', second);

    expect(first.pauseCount, 1);
    expect(first.releaseCount, 1);
    expect(second.pauseCount, 0);
    expect(second.releaseCount, 0);
    expect(coordinator.ownerId, 'play_b');
  });

  test('suspension pauses without discarding ownership', () async {
    final coordinator = ActiveMediaCoordinator();
    final handle = _Handle();

    await coordinator.activate('play_a', handle);
    await coordinator.suspend();

    expect(handle.pauseCount, 1);
    expect(handle.releaseCount, 0);
    expect(coordinator.ownerId, 'play_a');
  });

  test('releaseAll clears active media', () async {
    final coordinator = ActiveMediaCoordinator();
    final handle = _Handle();

    await coordinator.activate('play_a', handle);
    await coordinator.releaseAll();

    expect(handle.pauseCount, 1);
    expect(handle.releaseCount, 1);
    expect(coordinator.hasActiveMedia, isFalse);
  });
}
