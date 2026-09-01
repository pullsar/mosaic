import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/guest_engagement.dart';

final class _MemoryGuestStore implements GuestEngagementStore {
  _MemoryGuestStore({this.readGate});

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

  test(
    'five distinct views do not prompt without meaningful interaction',
    () async {
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

      expect(controller.shouldPrompt, isFalse);
      expect(store.state?.seenIdentities, hasLength(5));
    },
  );

  test('five distinct views prompt after one persisted interaction', () async {
    final store = _MemoryGuestStore()
      ..state = GuestEngagementState.fromJson(<String, Object?>{
        'seenIdentities': <String>[],
        'hasMeaningfulInteraction': true,
      });
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
    expect(controller.state.toJson()['hasMeaningfulInteraction'], isTrue);
    expect(store.state?.toJson()['hasMeaningfulInteraction'], isTrue);
  });

  test('eight distinct views prompt without an interaction', () async {
    final store = _MemoryGuestStore();
    final controller = GuestEngagementController(
      store: store,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    for (var index = 0; index < 8; index += 1) {
      await controller.recordVisible(
        playId: 'play_$index',
        revisionId: 'rev_1',
      );
    }

    expect(controller.shouldPrompt, isTrue);
    expect(controller.state.seenIdentities, hasLength(8));
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

  test(
    'dismissal resets the baseline before five fresh interactions',
    () async {
      final store = _MemoryGuestStore();
      var clock = now;
      final controller = GuestEngagementController(
        store: store,
        clock: () => clock,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      for (var index = 0; index < 8; index += 1) {
        await controller.recordVisible(
          playId: 'play_$index',
          revisionId: 'rev_$index',
        );
      }

      await controller.dismissPrompt();
      expect(controller.shouldPrompt, isFalse);
      expect(controller.state.seenIdentities, isEmpty);
      expect(controller.state.toJson()['hasMeaningfulInteraction'], isFalse);
      clock = now.add(const Duration(days: 6, hours: 23));
      expect(controller.shouldPrompt, isFalse);
      clock = now.add(const Duration(days: 7));
      expect(controller.shouldPrompt, isFalse);

      for (var index = 0; index < 5; index += 1) {
        await controller.recordVisible(
          playId: 'fresh_$index',
          revisionId: 'rev_fresh_$index',
        );
      }
      expect(controller.shouldPrompt, isFalse);
      await controller.recordMeaningfulInteraction();
      expect(controller.shouldPrompt, isTrue);
    },
  );

  test('dismissal requires eight fresh views without an interaction', () async {
    final store = _MemoryGuestStore();
    var clock = now;
    final controller = GuestEngagementController(
      store: store,
      clock: () => clock,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    for (var index = 0; index < 8; index += 1) {
      await controller.recordVisible(
        playId: 'before_$index',
        revisionId: 'rev_before_$index',
      );
    }

    await controller.dismissPrompt();
    clock = now.add(const Duration(days: 7));
    for (var index = 0; index < 7; index += 1) {
      await controller.recordVisible(
        playId: 'after_$index',
        revisionId: 'rev_after_$index',
      );
    }
    expect(controller.shouldPrompt, isFalse);
    await controller.recordVisible(
      playId: 'after_7',
      revisionId: 'rev_after_7',
    );
    expect(controller.shouldPrompt, isTrue);
    expect(store.state?.seenIdentities, hasLength(8));
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
      'hasMeaningfulInteraction': true,
    });
    expect(state.seenIdentities, hasLength(8));
    expect(state.dismissedAt, now);
    expect(state.toJson()['hasMeaningfulInteraction'], isTrue);
    final legacyState = GuestEngagementState.fromJson(<String, Object?>{
      'seenIdentities': <String>['legacy\u0000rev_1'],
      'dismissedAt': null,
    });
    expect(legacyState.seenIdentities, <String>['legacy\u0000rev_1']);
    expect(legacyState.toJson()['hasMeaningfulInteraction'], isFalse);
    expect(
      () => GuestEngagementState.fromJson(<String, Object?>{
        'seenIdentities': <Object?>[1],
      }),
      throwsFormatException,
    );
    expect(
      () => GuestEngagementState.fromJson(<String, Object?>{
        'seenIdentities': <String>[],
        'hasMeaningfulInteraction': 'yes',
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
