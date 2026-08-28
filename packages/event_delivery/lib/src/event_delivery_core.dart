import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:platform_contracts/platform_contracts.dart';

enum EventPriority {
  analytics(0),
  normal(50),
  critical(100);

  const EventPriority(this.value);
  final int value;
}

final class EventOutboxPolicy {
  const EventOutboxPolicy({
    this.maxCount = 1000,
    this.maxBytes = 1024 * 1024,
    this.maxAge = const Duration(days: 14),
    this.maxBackoff = const Duration(hours: 1),
  }) : assert(maxCount > 0),
       assert(maxBytes > 0),
       assert(!maxAge.isNegative),
       assert(!maxBackoff.isNegative);

  final int maxCount;
  final int maxBytes;
  final Duration maxAge;
  final Duration maxBackoff;
}

final class QueuedEvent {
  const QueuedEvent({
    required this.envelope,
    required this.priority,
    required this.attemptCount,
    required this.createdAt,
    this.nextAttemptAt,
  });

  final MosaicEventEnvelope envelope;
  final EventPriority priority;
  final int attemptCount;
  final DateTime createdAt;
  final DateTime? nextAttemptAt;
}

abstract interface class EventOutbox {
  Future<void> enqueue(
    MosaicEventEnvelope event, {
    EventPriority priority = EventPriority.analytics,
    DateTime? createdAt,
  });

  Future<List<QueuedEvent>> due({DateTime? now, int limit = 50});

  Future<void> markDelivered(String eventId);

  Future<void> markRetryableFailure(String eventId, {DateTime? now});

  Future<void> discard(String eventId);

  Future<void> clear();

  Future<void> close();
}

final class EventContext {
  EventContext({
    required String actorId,
    required String sessionId,
    String? feedRequestId,
    String? playRevisionId,
  }) : actorId = _requireText(actorId, 'actorId'),
       sessionId = _requireText(sessionId, 'sessionId'),
       feedRequestId = _optionalText(feedRequestId),
       playRevisionId = _optionalText(playRevisionId);

  final String actorId;
  final String sessionId;
  final String? feedRequestId;
  final String? playRevisionId;
}

typedef EventContextProvider = FutureOr<EventContext> Function();
typedef EventIdFactory = String Function();
typedef EventClock = DateTime Function();
typedef EventInternalErrorReporter =
    void Function(Object error, StackTrace stackTrace, {String? operation});

/// Converts provider-neutral [Telemetry] events into canonical durable Mosaic
/// event envelopes without exposing storage or transport details to renderers.
final class MosaicEventTelemetry implements Telemetry {
  MosaicEventTelemetry({
    required this.outbox,
    required this.contextProvider,
    EventIdFactory? eventIdFactory,
    EventClock? clock,
    this.onInternalError,
  }) : _eventIdFactory = eventIdFactory ?? secureUuidV4,
       _clock = clock ?? DateTime.now;

  final EventOutbox outbox;
  final EventContextProvider contextProvider;
  final EventInternalErrorReporter? onInternalError;
  final EventIdFactory _eventIdFactory;
  final EventClock _clock;

  @override
  void event(String name, Map<String, Object?> payload) {
    try {
      final normalizedName = _requireText(name, 'name');
      final eventId = _requireText(_eventIdFactory(), 'eventId');
      final occurredAt = _clock().toUtc();
      final stablePayload = _cloneJsonObject(payload);
      unawaited(
        _enqueue(
          eventId: eventId,
          name: normalizedName,
          occurredAt: occurredAt,
          payload: stablePayload,
        ),
      );
    } on Object catch (error, stackTrace) {
      _reportInternal(error, stackTrace, operation: 'event_prepare');
    }
  }

  Future<void> _enqueue({
    required String eventId,
    required String name,
    required DateTime occurredAt,
    required Map<String, Object?> payload,
  }) async {
    try {
      final context = await contextProvider();
      await outbox.enqueue(
        MosaicEventEnvelope(
          eventId: eventId,
          event: name,
          occurredAt: occurredAt,
          actorId: context.actorId,
          sessionId: context.sessionId,
          feedRequestId: context.feedRequestId,
          playRevisionId: context.playRevisionId,
          payload: payload,
        ),
      );
    } on Object catch (error, stackTrace) {
      _reportInternal(error, stackTrace, operation: 'event_enqueue');
    }
  }

  @override
  void error(Object error, StackTrace stackTrace, {String? operation}) {
    _reportInternal(
      error,
      stackTrace,
      operation: operation ?? 'telemetry_error',
    );
  }

  @override
  FutureOr<T> trace<T>(String operation, FutureOr<T> Function() body) async {
    try {
      return await body();
    } on Object catch (error, stackTrace) {
      _reportInternal(error, stackTrace, operation: operation);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _reportInternal(
    Object error,
    StackTrace stackTrace, {
    String? operation,
  }) {
    final reporter = onInternalError;
    if (reporter == null) return;
    try {
      reporter(error, stackTrace, operation: operation);
    } on Object {
      // Telemetry failures cannot destabilize the feature being observed.
    }
  }
}

enum EventDeliveryDisposition { accepted, retryableFailure, rejected }

final class EventDeliveryResult {
  const EventDeliveryResult(this.disposition, {this.statusCode});

  final EventDeliveryDisposition disposition;
  final int? statusCode;
}

abstract interface class EventTransport {
  Future<EventDeliveryResult> deliver(MosaicEventEnvelope event);
  Future<void> close();
}

typedef RejectedEventObserver =
    void Function(MosaicEventEnvelope event, EventDeliveryResult result);

final class EventDrainSummary {
  const EventDrainSummary({
    required this.delivered,
    required this.rejected,
    required this.retryDeferred,
  });

  final int delivered;
  final int rejected;
  final int retryDeferred;
}

/// Coalesces concurrent drain requests and delivers at most [limit] due events
/// serially. One retryable transport failure stops the current drain so an
/// outage does not fan out into a burst of doomed requests.
final class EventDrainController {
  EventDrainController({
    required this.outbox,
    required this.transport,
    this.onRejected,
  });

  final EventOutbox outbox;
  final EventTransport transport;
  final RejectedEventObserver? onRejected;
  Future<EventDrainSummary>? _inFlight;

  Future<EventDrainSummary> drain({DateTime? now, int limit = 50}) {
    if (limit <= 0) {
      return Future.value(
        const EventDrainSummary(delivered: 0, rejected: 0, retryDeferred: 0),
      );
    }
    final existing = _inFlight;
    if (existing != null) return existing;

    late final Future<EventDrainSummary> operation;
    operation = _drain(now: now, limit: limit).whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
    _inFlight = operation;
    return operation;
  }

  Future<EventDrainSummary> _drain({DateTime? now, required int limit}) async {
    var delivered = 0;
    var rejected = 0;
    var retryDeferred = 0;
    final events = await outbox.due(now: now, limit: limit);

    for (final queued in events) {
      EventDeliveryResult result;
      try {
        result = await transport.deliver(queued.envelope);
      } on Object {
        result = const EventDeliveryResult(
          EventDeliveryDisposition.retryableFailure,
        );
      }

      switch (result.disposition) {
        case EventDeliveryDisposition.accepted:
          await outbox.markDelivered(queued.envelope.eventId);
          delivered += 1;
        case EventDeliveryDisposition.rejected:
          await outbox.discard(queued.envelope.eventId);
          rejected += 1;
          final observer = onRejected;
          if (observer != null) {
            try {
              observer(queued.envelope, result);
            } on Object {
              // Rejection observers cannot prevent queue progress.
            }
          }
        case EventDeliveryDisposition.retryableFailure:
          await outbox.markRetryableFailure(queued.envelope.eventId, now: now);
          retryDeferred += 1;
          return EventDrainSummary(
            delivered: delivered,
            rejected: rejected,
            retryDeferred: retryDeferred,
          );
      }
    }

    return EventDrainSummary(
      delivered: delivered,
      rejected: rejected,
      retryDeferred: retryDeferred,
    );
  }
}

String secureUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String pair(int index) => bytes[index].toRadixString(16).padLeft(2, '0');
  return '${pair(0)}${pair(1)}${pair(2)}${pair(3)}-'
      '${pair(4)}${pair(5)}-'
      '${pair(6)}${pair(7)}-'
      '${pair(8)}${pair(9)}-'
      '${pair(10)}${pair(11)}${pair(12)}${pair(13)}${pair(14)}${pair(15)}';
}

String _requireText(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}

String? _optionalText(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

Map<String, Object?> _cloneJsonObject(Map<String, Object?> value) {
  final decoded = jsonDecode(jsonEncode(value));
  if (decoded is! Map) {
    throw const FormatException('Telemetry payload must be a JSON object.');
  }
  final result = <String, Object?>{};
  for (final entry in decoded.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException('Telemetry payload keys must be strings.');
    }
    result[key] = entry.value;
  }
  return Map<String, Object?>.unmodifiable(result);
}
