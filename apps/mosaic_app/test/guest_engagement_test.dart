import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/guest_engagement.dart';

final class _MemoryGuestStore implements GuestEngagementStore {
  _MemoryGuestStore({this.state, this.readGate});

  GuestEngagementState? state;
  final Completer<GuestEngagementState?>? readGate;
  int writes = 0;

  @override
  Future<GuestEngagementState?> readGuestEngagement() async =>
      readGate == null ? state : readGate!.future;

  @override
  Future<void> writeGuestEngagement(GuestEngagementState next) async {
    state = next;
    writes += 1;
  }
}

void main() {
  final now = DateTime.utc(2026, 8, 31, 12);

  test('five distinct visible revisions unlock one prompt', () async {
    final store = _MemoryGuestStore();
    final controller = GuestEngagementController(
      store: store,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    for (var index = 0; index < 5; index += 1) {
      await controller.recordVisible(
        playId: 'play_$index',
        revisionId: 'rev_1',
      );
    }

    expect(controller.shouldPrompt, isTrue);
    expect(store.state?.seenIdentities, hasLength(5));
  });

  test('duplicates rebuilds and retry visibility do not advance', () async {
    final controller = GuestEngagementController(
      store: _MemoryGuestStore(),
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    for (var index = 0; index < 8; index += 1) {
      await controller.recordVisible(playId: 'same', revisionId: 'rev_same');
    }

    expect(controller.shouldPrompt, isFalse);
    expect(controller.state.seenIdentities, hasLength(1));
  });

  test('dismissal suppresses the session and enforces cooldown', () async {
    final store = _MemoryGuestStore();
    var clock = now;
    final controller = GuestEngagementController(
      store: store,
      clock: () => clock,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    for (var index = 0; index < 5; index += 1) {
      await controller.recordVisible(
        playId: 'play_$index',
        revisionId: 'rev_$index',
      );
    }

    await controller.dismissPrompt();
    expect(controller.shouldPrompt, isFalse);
    clock = now.add(const Duration(days: 6, hours: 23));
    expect(controller.shouldPrompt, isFalse);
    clock = now.add(const Duration(days: 7));
    expect(controller.shouldPrompt, isTrue);
  });

  test('visibility recorded during initialization is merged', () async {
    final gate = Completer<GuestEngagementState?>();
    final store = _MemoryGuestStore(readGate: gate);
    final controller = GuestEngagementController(
      store: store,
      clock: () => now,
    );
    addTearDown(controller.dispose);

    final initialization = controller.initialize();
    final recording = controller.recordVisible(
      playId: 'live',
      revisionId: 'rev_live',
    );
    gate.complete(
      const GuestEngagementState(
        seenIdentities: <String>['cached\u0000rev_cached'],
      ),
    );
    await Future.wait<void>(<Future<void>>[initialization, recording]);

    expect(controller.state.seenIdentities, <String>[
      'cached\u0000rev_cached',
      'live\u0000rev_live',
    ]);
  });

  test('state JSON is bounded and rejects malformed values', () {
    final state = GuestEngagementState.fromJson(<String, Object?>{
      'seenIdentities': List<String>.generate(8, (index) => 'r\u0000$index'),
      'dismissedAt': now.toIso8601String(),
    });
    expect(state.seenIdentities, hasLength(5));
    expect(state.dismissedAt, now);
    expect(
      () => GuestEngagementState.fromJson(<String, Object?>{
        'seenIdentities': <Object?>[1],
      }),
      throwsFormatException,
    );
  });

  test(
    'storage failures are reported without breaking guest browsing',
    () async {
      final errors = <Object>[];
      final controller = GuestEngagementController(
        store: _FailingGuestStore(),
        clock: () => now,
        onError: (error, stackTrace) => errors.add(error),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.recordVisible(playId: 'play', revisionId: 'rev_1');

      expect(controller.state.seenIdentities, <String>['play\u0000rev_1']);
      expect(errors, hasLength(2));
    },
  );

  test('initialization may finish after controller disposal', () async {
    final gate = Completer<GuestEngagementState?>();
    final controller = GuestEngagementController(
      store: _MemoryGuestStore(readGate: gate),
      clock: () => now,
    );

    final initialization = controller.initialize();
    controller.dispose();
    gate.complete(null);
    await expectLater(initialization, completes);
  });
}

final class _FailingGuestStore implements GuestEngagementStore {
  @override
  Future<GuestEngagementState?> readGuestEngagement() =>
      Future<GuestEngagementState?>.error(StateError('read failed'));

  @override
  Future<void> writeGuestEngagement(GuestEngagementState state) =>
      Future<void>.error(StateError('write failed'));
}
