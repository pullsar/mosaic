import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

final class GuestEngagementState {
  const GuestEngagementState({
    this.seenIdentities = const <String>[],
    this.dismissedAt,
  });

  static const int maxSeenIdentities = 5;

  final List<String> seenIdentities;
  final DateTime? dismissedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'seenIdentities': seenIdentities,
    'dismissedAt': dismissedAt?.toUtc().toIso8601String(),
  };

  factory GuestEngagementState.fromJson(Map<String, Object?> json) {
    final rawIdentities = json['seenIdentities'];
    if (rawIdentities is! List) {
      throw const FormatException('seenIdentities must be a list');
    }

    final identities = LinkedHashSet<String>();
    for (final identity in rawIdentities) {
      if (identity is! String || identity.isEmpty) {
        throw const FormatException('seenIdentities must contain strings');
      }
      identities
        ..remove(identity)
        ..add(identity);
    }

    final rawDismissedAt = json['dismissedAt'];
    DateTime? dismissedAt;
    if (rawDismissedAt != null) {
      if (rawDismissedAt is! String) {
        throw const FormatException('dismissedAt must be a timestamp');
      }
      dismissedAt = DateTime.tryParse(rawDismissedAt)?.toUtc();
      if (dismissedAt == null) {
        throw const FormatException('dismissedAt must be a timestamp');
      }
    }

    return GuestEngagementState(
      seenIdentities: identities
          .skip(
            identities.length > maxSeenIdentities
                ? identities.length - maxSeenIdentities
                : 0,
          )
          .toList(growable: false),
      dismissedAt: dismissedAt,
    );
  }
}

abstract interface class GuestEngagementStore {
  Future<GuestEngagementState?> readGuestEngagement();

  Future<void> writeGuestEngagement(GuestEngagementState state);
}

final class MemoryGuestEngagementStore implements GuestEngagementStore {
  GuestEngagementState? _state;

  @override
  Future<GuestEngagementState?> readGuestEngagement() async => _state;

  @override
  Future<void> writeGuestEngagement(GuestEngagementState state) async {
    _state = state;
  }
}

final class GuestEngagementController extends ChangeNotifier {
  GuestEngagementController({
    required GuestEngagementStore store,
    DateTime Function()? clock,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) : _store = store,
       _clock = clock ?? DateTime.now,
       _onError = onError;

  static const int promptThreshold = 5;
  static const Duration promptCooldown = Duration(days: 7);

  final GuestEngagementStore _store;
  final DateTime Function() _clock;
  final void Function(Object error, StackTrace stackTrace)? _onError;
  final LinkedHashSet<String> _pendingIdentities = LinkedHashSet<String>();

  GuestEngagementState _state = const GuestEngagementState();
  Future<void>? _initialization;
  Future<void> _writeTail = Future<void>.value();
  bool _initialized = false;
  bool _disposed = false;

  GuestEngagementState get state => _state;

  bool get shouldPrompt {
    if (!_initialized || _state.seenIdentities.length < promptThreshold) {
      return false;
    }
    final dismissedAt = _state.dismissedAt;
    return dismissedAt == null ||
        !_clock().toUtc().isBefore(dismissedAt.add(promptCooldown));
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    GuestEngagementState? stored;
    try {
      stored = await _store.readGuestEngagement();
    } on Object catch (error, stackTrace) {
      _onError?.call(error, stackTrace);
    }
    final identities = LinkedHashSet<String>.from(
      stored?.seenIdentities ?? const <String>[],
    )..addAll(_pendingIdentities);
    _pendingIdentities.clear();

    _state = GuestEngagementState(
      seenIdentities: _bounded(identities),
      dismissedAt: stored?.dismissedAt,
    );
    _initialized = true;
    if (identities.isNotEmpty &&
        (stored == null ||
            !listEquals(stored.seenIdentities, _state.seenIdentities))) {
      await _persist();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> recordVisible({
    required String playId,
    required String revisionId,
  }) async {
    final play = playId.trim();
    final revision = revisionId.trim();
    if (play.isEmpty || revision.isEmpty) {
      throw ArgumentError('playId and revisionId must not be empty');
    }
    final identity = '$play\u0000$revision';

    if (!_initialized) {
      _pendingIdentities.add(identity);
      await initialize();
      return;
    }
    if (_state.seenIdentities.contains(identity)) {
      return;
    }

    final identities = LinkedHashSet<String>.from(_state.seenIdentities)
      ..add(identity);
    _state = GuestEngagementState(
      seenIdentities: _bounded(identities),
      dismissedAt: _state.dismissedAt,
    );
    if (!_disposed) notifyListeners();
    await _persist();
  }

  Future<void> dismissPrompt() async {
    if (!_initialized) {
      await initialize();
    }
    _state = GuestEngagementState(
      seenIdentities: _state.seenIdentities,
      dismissedAt: _clock().toUtc(),
    );
    if (!_disposed) notifyListeners();
    await _persist();
  }

  List<String> _bounded(LinkedHashSet<String> identities) => identities
      .skip(
        identities.length > GuestEngagementState.maxSeenIdentities
            ? identities.length - GuestEngagementState.maxSeenIdentities
            : 0,
      )
      .toList(growable: false);

  Future<void> _persist() {
    final snapshot = _state;
    final write = _writeTail.then((_) async {
      try {
        await _store.writeGuestEngagement(snapshot);
      } on Object catch (error, stackTrace) {
        _onError?.call(error, stackTrace);
      }
    });
    _writeTail = write;
    return write;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
