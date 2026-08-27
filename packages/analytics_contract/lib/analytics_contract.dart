abstract final class MosaicEventName {
  static const playImpression = 'play_impression';
  static const playVisible = 'play_visible';
  static const playStarted = 'play_started';
  static const playAction = 'play_action';
  static const playResolved = 'play_resolved';
  static const playCompleted = 'play_completed';
  static const playDismissed = 'play_dismissed';
  static const playSaved = 'play_saved';
  static const playShared = 'play_shared';
  static const moreLikeThis = 'more_like_this';
}

final class MosaicEventEnvelope {
  const MosaicEventEnvelope({
    required this.event,
    required this.occurredAt,
    required this.actorId,
    required this.sessionId,
    this.version = 1,
    this.feedRequestId,
    this.playRevisionId,
    this.payload = const {},
  });

  final String event;
  final int version;
  final DateTime occurredAt;
  final String actorId;
  final String sessionId;
  final String? feedRequestId;
  final String? playRevisionId;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {
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
