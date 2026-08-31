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
        feedRequestId: 'request',
        revisionId: 'rev_$index',
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
      await controller.recordVisible(
        feedRequestId: 'same',
        revisionId: 'rev_same',
      );
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
        feedRequestId: 'request',
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
      feedRequestId: 'live',
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
}
