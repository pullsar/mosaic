import 'dart:async';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';

import 'app_event_runtime.dart';
import 'consumer_api_client.dart';
import 'consumer_local_state.dart';

enum ConsumerReportReason {
  spam('spam'),
  misleading('misleading'),
  harassment('harassment'),
  sexualContent('sexual_content'),
  violenceOrDangerous('violence_or_dangerous'),
  rightsOrOwnership('rights_or_ownership'),
  other('other');

  const ConsumerReportReason(this.wireName);
  final String wireName;
}

typedef ConsumerActionErrorReporter =
    void Function(Object error, StackTrace stackTrace, {String? operation});

final class ConsumerActionController {
  ConsumerActionController({
    required AppEventRuntime eventRuntime,
    required ConsumerLocalState localState,
    ConsumerApiClient? api,
    DateTime Function()? clock,
    String Function()? eventIdFactory,
    ConsumerActionErrorReporter? onError,
  }) : _eventRuntime = eventRuntime,
       _localState = localState,
       _api = api,
       _clock = clock ?? DateTime.now,
       _eventIdFactory = eventIdFactory ?? secureUuidV4,
       _onError = onError;

  static const int _maxCachedPlayStates = 64;

  final AppEventRuntime _eventRuntime;
  final ConsumerLocalState _localState;
  final ConsumerApiClient? _api;
  final DateTime Function() _clock;
  final String Function() _eventIdFactory;
  final ConsumerActionErrorReporter? _onError;
  final Map<String, ConsumerPlayActionState> _states =
      <String, ConsumerPlayActionState>{};
  final Set<String> _busyPlayIds = <String>{};
  final Set<String> _busyTopicIds = <String>{};
  final Set<String> _mutedTopicIds = <String>{};
  final Set<void Function()> _listeners = <void Function()>{};
  bool _mutedTopicsLoaded = false;
  bool _closed = false;

  ConsumerPlayActionState? stateFor(String playId) => _states[playId.trim()];

  bool isPlayBusy(String playId) => _busyPlayIds.contains(playId.trim());

  bool isTopicMuted(String topicId) => _mutedTopicIds.contains(topicId.trim());

  bool isTopicBusy(String topicId) => _busyTopicIds.contains(topicId.trim());

  List<String> get mutedTopicIds =>
      List<String>.unmodifiable(_mutedTopicIds.toList()..sort());

  bool isItemEligible({
    required String playId,
    required Iterable<String> topicIds,
  }) {
    final normalizedPlayId = _text(playId, 'playId');
    if (_states[normalizedPlayId]?.notInterested == true) return false;
    for (final topicId in topicIds) {
      final normalized = topicId.trim();
      if (normalized.isNotEmpty && _mutedTopicIds.contains(normalized)) {
        return false;
      }
    }
    return true;
  }

  void addListener(void Function() listener) {
    if (_closed) return;
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  Future<ConsumerPlayActionState> load({
    required String playId,
    required String revisionId,
  }) async {
    _ensureOpen();
    final id = _text(playId, 'playId');
    final revision = _text(revisionId, 'revisionId');
    await _loadMutedTopics();
    final cached = _states[id];
    if (cached != null) {
      _rememberState(cached);
      return cached;
    }

    final local = await _localState.readPlayActionState(id);
    final initial =
        local ??
        ConsumerPlayActionState(
          playId: id,
          saved: false,
          moreLikeThis: false,
          notInterested: false,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        );
    _rememberState(initial);
    _notify();

    if (local == null) {
      unawaited(_seedFromRemote(id, revision));
    }
    return initial;
  }

  Future<bool> toggleSave({
    required String playId,
    required String revisionId,
    required String feedRequestId,
  }) async {
    final current = await load(playId: playId, revisionId: revisionId);
    final id = current.playId;
    if (!_busyPlayIds.add(id)) return false;
    final now = _clock().toUtc();
    final nextSaved = !current.saved;
    final next = current.copyWith(
      saved: nextSaved,
      savedRevisionId: nextSaved ? revisionId : null,
      clearSavedRevisionId: !nextSaved,
      updatedAt: now,
    );
    _rememberState(next);
    _notify();
    try {
      await _enqueuePlayEvent(
        name: nextSaved
            ? MosaicEventName.playSaved
            : MosaicEventName.playUnsaved,
        playId: id,
        revisionId: revisionId,
        feedRequestId: feedRequestId,
        occurredAt: now,
      );
    } on Object catch (error, stackTrace) {
      _rememberState(current);
      _report(error, stackTrace, operation: 'consumer_action_save_enqueue');
      return false;
    } finally {
      _busyPlayIds.remove(id);
      _notify();
    }
    await _persistPlayStateBestEffort(
      next,
      operation: 'consumer_action_save_cache',
    );
    return true;
  }

  Future<bool> moreLikeThis({
    required String playId,
    required String revisionId,
    required String feedRequestId,
  }) async {
    final current = await load(playId: playId, revisionId: revisionId);
    if (current.moreLikeThis) return true;
    return _applyOneShotPlayAction(
      current: current,
      revisionId: revisionId,
      feedRequestId: feedRequestId,
      eventName: MosaicEventName.moreLikeThis,
      operation: 'consumer_action_more_like_this',
      transform: (state, now) =>
          state.copyWith(moreLikeThis: true, updatedAt: now),
    );
  }

  Future<bool> notInterested({
    required String playId,
    required String revisionId,
    required String feedRequestId,
  }) async {
    final current = await load(playId: playId, revisionId: revisionId);
    if (current.notInterested) return true;
    return _applyOneShotPlayAction(
      current: current,
      revisionId: revisionId,
      feedRequestId: feedRequestId,
      eventName: MosaicEventName.playNotInterested,
      operation: 'consumer_action_not_interested',
      transform: (state, now) =>
          state.copyWith(notInterested: true, updatedAt: now),
    );
  }

  Future<bool> setTopicMuted({
    required String topicId,
    required bool muted,
    required String feedRequestId,
    required String playRevisionId,
  }) async {
    _ensureOpen();
    await _loadMutedTopics();
    final id = _text(topicId, 'topicId');
    final alreadyMuted = _mutedTopicIds.contains(id);
    if (alreadyMuted == muted) return true;
    if (!_busyTopicIds.add(id)) return false;

    if (muted) {
      _mutedTopicIds.add(id);
    } else {
      _mutedTopicIds.remove(id);
    }
    _notify();

    final now = _clock().toUtc();
    try {
      await _eventRuntime.resources.outbox.enqueue(
        MosaicEventEnvelope(
          eventId: _eventId(),
          event: muted
              ? MosaicEventName.topicMuted
              : MosaicEventName.topicUnmuted,
          occurredAt: now,
          actorId: _eventRuntime.resources.actorId,
          sessionId: _eventRuntime.sessionId,
          feedRequestId: _text(feedRequestId, 'feedRequestId'),
          playRevisionId: _text(playRevisionId, 'playRevisionId'),
          payload: <String, Object?>{'topicId': id},
        ),
        priority: EventPriority.normal,
        createdAt: now,
      );
      _eventRuntime.requestDrain();
    } on Object catch (error, stackTrace) {
      if (alreadyMuted) {
        _mutedTopicIds.add(id);
      } else {
        _mutedTopicIds.remove(id);
      }
      _report(
        error,
        stackTrace,
        operation: 'consumer_action_topic_mute_enqueue',
      );
      return false;
    } finally {
      _busyTopicIds.remove(id);
      _notify();
    }

    await _persistMutedTopicsBestEffort();
    return true;
  }

  Future<bool> report({
    required String playId,
    required String revisionId,
    required String feedRequestId,
    required ConsumerReportReason reason,
    bool dismiss = false,
  }) async {
    _ensureOpen();
    final now = _clock().toUtc();
    try {
      await _eventRuntime.resources.outbox.enqueue(
        MosaicEventEnvelope(
          eventId: _eventId(),
          event: MosaicEventName.playReported,
          occurredAt: now,
          actorId: _eventRuntime.resources.actorId,
          sessionId: _eventRuntime.sessionId,
          feedRequestId: _text(feedRequestId, 'feedRequestId'),
          playRevisionId: _text(revisionId, 'revisionId'),
          payload: <String, Object?>{
            'playId': _text(playId, 'playId'),
            'reason': reason.wireName,
            'dismiss': dismiss,
          },
        ),
        priority: EventPriority.critical,
        createdAt: now,
      );
      _eventRuntime.requestDrain();
      return true;
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_action_report');
      return false;
    }
  }

  Future<bool> _applyOneShotPlayAction({
    required ConsumerPlayActionState current,
    required String revisionId,
    required String feedRequestId,
    required String eventName,
    required String operation,
    required ConsumerPlayActionState Function(
      ConsumerPlayActionState state,
      DateTime now,
    )
    transform,
  }) async {
    final id = current.playId;
    if (!_busyPlayIds.add(id)) return false;
    final now = _clock().toUtc();
    final next = transform(current, now);
    _rememberState(next);
    _notify();
    try {
      await _enqueuePlayEvent(
        name: eventName,
        playId: id,
        revisionId: revisionId,
        feedRequestId: feedRequestId,
        occurredAt: now,
      );
    } on Object catch (error, stackTrace) {
      _rememberState(current);
      _report(error, stackTrace, operation: '${operation}_enqueue');
      return false;
    } finally {
      _busyPlayIds.remove(id);
      _notify();
    }
    await _persistPlayStateBestEffort(next, operation: '${operation}_cache');
    return true;
  }

  Future<void> _enqueuePlayEvent({
    required String name,
    required String playId,
    required String revisionId,
    required String feedRequestId,
    required DateTime occurredAt,
  }) async {
    await _eventRuntime.resources.outbox.enqueue(
      MosaicEventEnvelope(
        eventId: _eventId(),
        event: name,
        occurredAt: occurredAt,
        actorId: _eventRuntime.resources.actorId,
        sessionId: _eventRuntime.sessionId,
        feedRequestId: _text(feedRequestId, 'feedRequestId'),
        playRevisionId: _text(revisionId, 'revisionId'),
        payload: <String, Object?>{'playId': _text(playId, 'playId')},
      ),
      priority: EventPriority.normal,
      createdAt: occurredAt,
    );
    _eventRuntime.requestDrain();
  }

  Future<void> _loadMutedTopics() async {
    if (_mutedTopicsLoaded) return;
    final topics = await _localState.readMutedTopicIds();
    _mutedTopicIds
      ..clear()
      ..addAll(topics.map((topic) => _text(topic, 'topicId')));
    _mutedTopicsLoaded = true;
  }

  Future<void> _seedFromRemote(String playId, String revisionId) async {
    final api = _api;
    if (api == null || _closed) return;
    try {
      final result = await api.getActionState(playId);
      if (_closed || _states[playId]?.updatedAt.millisecondsSinceEpoch != 0) {
        return;
      }
      if (result case ConsumerApiSuccess<ConsumerRemoteActionState>(
        :final value,
      )) {
        final remote = value.play;
        final seeded = ConsumerPlayActionState(
          playId: playId,
          savedRevisionId: remote.saved
              ? remote.savedRevisionId ?? revisionId
              : null,
          saved: remote.saved,
          moreLikeThis: remote.moreLikeThis,
          notInterested: remote.notInterested,
          updatedAt: _clock().toUtc(),
        );
        _rememberState(seeded);
        await _persistPlayStateBestEffort(
          seeded,
          operation: 'consumer_action_reconcile_cache',
        );
        _notify();
      }
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_action_reconcile');
    }
  }

  Future<void> _persistPlayStateBestEffort(
    ConsumerPlayActionState state, {
    required String operation,
  }) async {
    try {
      await _localState.writePlayActionState(state);
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: operation);
    }
  }

  Future<void> _persistMutedTopicsBestEffort() async {
    try {
      await _localState.writeMutedTopicIds(_mutedTopicIds);
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace, operation: 'consumer_action_topic_mute_cache');
    }
  }

  void _rememberState(ConsumerPlayActionState state) {
    final id = state.playId;
    _states.remove(id);
    _states[id] = state;
    while (_states.length > _maxCachedPlayStates) {
      String? candidate;
      for (final key in _states.keys) {
        if (!_busyPlayIds.contains(key) && key != id) {
          candidate = key;
          break;
        }
      }
      if (candidate == null) break;
      _states.remove(candidate);
    }
  }

  void dispose() {
    _closed = true;
    _listeners.clear();
    _states.clear();
    _busyPlayIds.clear();
    _busyTopicIds.clear();
    _mutedTopicIds.clear();
  }

  String _eventId() => _text(_eventIdFactory(), 'eventId');

  void _ensureOpen() {
    if (_closed) throw StateError('ConsumerActionController is closed.');
  }

  void _notify() {
    if (_closed) return;
    for (final listener in List<void Function()>.of(_listeners)) {
      try {
        listener();
      } on Object catch (error, stackTrace) {
        _report(error, stackTrace, operation: 'consumer_action_listener');
      }
    }
  }

  void _report(
    Object error,
    StackTrace stackTrace, {
    required String operation,
  }) {
    try {
      _onError?.call(error, stackTrace, operation: operation);
    } on Object {
      // Action UX must not fail because an observer failed.
    }
  }
}

String _text(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 200) {
    throw ArgumentError.value(value, name, 'must be 1 to 200 characters');
  }
  return normalized;
}
