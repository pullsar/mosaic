abstract final class MosaicEventName {
  static const playImpression = 'play_impression';
  static const playVisible = 'play_visible';
  static const playStarted = 'play_started';
  static const playAction = 'play_action';
  static const playResolved = 'play_resolved';
  static const playCompleted = 'play_completed';
  static const playDismissed = 'play_dismissed';
  static const playSaved = 'play_saved';
  static const playUnsaved = 'play_unsaved';
  static const playShared = 'play_shared';
  static const moreLikeThis = 'more_like_this';
  static const playNotInterested = 'play_not_interested';
  static const topicMuted = 'topic_muted';
  static const topicUnmuted = 'topic_unmuted';
  static const playReported = 'play_reported';
  static const searchSubmitted = 'search_submitted';
  static const searchResultSelected = 'search_result_selected';
  static const searchAbandoned = 'search_abandoned';
  static const mediaPlayback = 'media_playback';
}

final class MosaicEventEnvelope {
  const MosaicEventEnvelope({
    required this.eventId,
    required this.event,
    required this.occurredAt,
    required this.actorId,
    required this.sessionId,
    this.version = 1,
    this.feedRequestId,
    this.playRevisionId,
    this.payload = const {},
  });

  factory MosaicEventEnvelope.fromJson(Map<String, Object?> json) {
    String requiredText(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key must be a non-empty string.');
      }
      return value;
    }

    String? optionalText(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key must be null or a non-empty string.');
      }
      return value;
    }

    final version = json['version'];
    if (version is! int || version < 1) {
      throw const FormatException('version must be a positive integer.');
    }

    final occurredAtRaw = requiredText('occurredAt');
    final occurredAt = DateTime.tryParse(occurredAtRaw);
    if (occurredAt == null) {
      throw const FormatException('occurredAt must be an ISO-8601 timestamp.');
    }

    final payloadRaw = json['payload'];
    if (payloadRaw is! Map) {
      throw const FormatException('payload must be an object.');
    }
    final payload = <String, Object?>{};
    for (final entry in payloadRaw.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const FormatException('payload keys must be strings.');
      }
      payload[key] = entry.value;
    }

    return MosaicEventEnvelope(
      eventId: requiredText('eventId'),
      event: requiredText('event'),
      version: version,
      occurredAt: occurredAt.toUtc(),
      actorId: requiredText('actorId'),
      sessionId: requiredText('sessionId'),
      feedRequestId: optionalText('feedRequestId'),
      playRevisionId: optionalText('playRevisionId'),
      payload: Map<String, Object?>.unmodifiable(payload),
    );
  }

  /// Stable client-generated identity used for idempotent replay.
  final String eventId;
  final String event;
  final int version;
  final DateTime occurredAt;
  final String actorId;
  final String sessionId;
  final String? feedRequestId;
  final String? playRevisionId;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'event': event,
    'version': version,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'actorId': actorId,
    'sessionId': sessionId,
    if (feedRequestId != null) 'feedRequestId': feedRequestId,
    if (playRevisionId != null) 'playRevisionId': playRevisionId,
    'payload': payload,
  };
}
