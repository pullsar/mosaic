import 'package:play_schema/play_schema.dart';

import 'consumer_api_client.dart';

final class ConsumerFeedResume {
  ConsumerFeedResume({
    this.requestId,
    this.cursor,
    this.visibleRevisionId,
    this.visiblePosition,
    required List<String> windowRevisionIds,
    required this.updatedAt,
  }) : windowRevisionIds = List<String>.unmodifiable(windowRevisionIds) {
    if (visiblePosition != null && visiblePosition! < 0) {
      throw ArgumentError.value(
        visiblePosition,
        'visiblePosition',
        'must be non-negative',
      );
    }
  }

  final String? requestId;
  final String? cursor;
  final String? visibleRevisionId;
  final int? visiblePosition;
  final List<String> windowRevisionIds;
  final DateTime updatedAt;

  bool get isEmpty =>
      requestId == null &&
      cursor == null &&
      visibleRevisionId == null &&
      visiblePosition == null &&
      windowRevisionIds.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'requestId': requestId,
    'cursor': cursor,
    'visibleRevisionId': visibleRevisionId,
    'visiblePosition': visiblePosition,
    'windowRevisionIds': windowRevisionIds,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static ConsumerFeedResume fromJson(Map<String, Object?> json) {
    final requestId = _optionalString(json['requestId'], 'requestId', 200);
    final cursor = _optionalString(json['cursor'], 'cursor', 512);
    final visibleRevisionId = _optionalString(
      json['visibleRevisionId'],
      'visibleRevisionId',
      200,
    );
    final visiblePosition = json['visiblePosition'];
    if (visiblePosition != null &&
        (visiblePosition is! int || visiblePosition < 0)) {
      throw const FormatException('visiblePosition must be a non-negative int');
    }
    final revisions = _stringList(
      json['windowRevisionIds'],
      'windowRevisionIds',
      64,
      200,
    );
    final updatedAtRaw = json['updatedAt'];
    if (updatedAtRaw is! String) {
      throw const FormatException('updatedAt must be a string');
    }
    final updatedAt = DateTime.tryParse(updatedAtRaw)?.toUtc();
    if (updatedAt == null) throw const FormatException('updatedAt is invalid');
    return ConsumerFeedResume(
      requestId: requestId,
      cursor: cursor,
      visibleRevisionId: visibleRevisionId,
      visiblePosition: visiblePosition as int?,
      windowRevisionIds: revisions,
      updatedAt: updatedAt,
    );
  }
}

final class ConsumerFeedCache {
  ConsumerFeedCache({
    required String requestId,
    required List<ConsumerFeedItem> items,
    required this.updatedAt,
  }) : requestId = _requiredString(requestId, 'requestId', 200),
       items = List<ConsumerFeedItem>.unmodifiable(items) {
    if (items.length > maxItems) {
      throw ArgumentError.value(
        items.length,
        'items',
        'must contain at most $maxItems items',
      );
    }
  }

  static const int maxItems = 12;
  static const Duration maxAge = Duration(days: 2);

  final String requestId;
  final List<ConsumerFeedItem> items;
  final DateTime updatedAt;

  bool isExpiredAt(DateTime now) =>
      now.toUtc().difference(updatedAt.toUtc()) > maxAge;

  Map<String, Object?> toJson() => <String, Object?>{
    'requestId': requestId,
    'items': items
        .map(
          (item) => <String, Object?>{
            'playId': item.playId,
            'revisionId': item.revisionId,
            'sourceBucket': item.sourceBucket.wireName,
            'document': item.validatedDocumentJson,
          },
        )
        .toList(growable: false),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static ConsumerFeedCache fromJson(
    Map<String, Object?> json, {
    required PlayCapabilityEnvelope capabilities,
    PlayCompatibilityChecker compatibilityChecker =
        const PlayCompatibilityChecker(),
  }) {
    final requestId = json['requestId'];
    if (requestId is! String) {
      throw const FormatException('requestId must be a string');
    }
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > maxItems) {
      throw const FormatException('cached feed items are invalid');
    }
    final updatedAtRaw = json['updatedAt'];
    if (updatedAtRaw is! String) {
      throw const FormatException('updatedAt must be a string');
    }
    final updatedAt = DateTime.tryParse(updatedAtRaw)?.toUtc();
    if (updatedAt == null) throw const FormatException('updatedAt is invalid');
    return ConsumerFeedCache(
      requestId: requestId,
      items: rawItems
          .map(
            (value) => ConsumerFeedItem.fromJson(
              _jsonObject(value, 'cached feed item'),
              compatibilityChecker: compatibilityChecker,
              capabilities: capabilities,
            ),
          )
          .toList(growable: false),
      updatedAt: updatedAt,
    );
  }
}

abstract interface class ConsumerLocalState {
  Future<ConsumerPreferences> readPreferences();

  Future<void> writePreferences(ConsumerPreferences preferences);

  Future<ConsumerFeedResume?> readFeedResume();

  Future<void> writeFeedResume(ConsumerFeedResume state);

  Future<void> clearFeedResume();

  Future<ConsumerFeedCache?> readRecentFeed({
    required PlayCapabilityEnvelope capabilities,
  });

  Future<void> writeRecentFeed(ConsumerFeedCache state);

  Future<void> clearRecentFeed();
}

final class DisabledConsumerLocalState implements ConsumerLocalState {
  const DisabledConsumerLocalState();

  @override
  Future<ConsumerPreferences> readPreferences() async => ConsumerPreferences();

  @override
  Future<void> writePreferences(ConsumerPreferences preferences) async {}

  @override
  Future<ConsumerFeedResume?> readFeedResume() async => null;

  @override
  Future<void> writeFeedResume(ConsumerFeedResume state) async {}

  @override
  Future<void> clearFeedResume() async {}

  @override
  Future<ConsumerFeedCache?> readRecentFeed({
    required PlayCapabilityEnvelope capabilities,
  }) async => null;

  @override
  Future<void> writeRecentFeed(ConsumerFeedCache state) async {}

  @override
  Future<void> clearRecentFeed() async {}
}

String _requiredString(String value, String field, int maxLength) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) {
    throw FormatException('$field must be 1 to $maxLength characters');
  }
  return normalized;
}

String? _optionalString(Object? value, String field, int maxLength) {
  if (value == null) return null;
  if (value is! String)
    throw FormatException('$field must be a string or null');
  return _requiredString(value, field, maxLength);
}

List<String> _stringList(
  Object? value,
  String field,
  int maxCount,
  int maxLength,
) {
  if (value is! List || value.length > maxCount) {
    throw FormatException('$field must be an array of at most $maxCount items');
  }
  final result = <String>[];
  final seen = <String>{};
  for (final raw in value) {
    if (raw is! String) throw FormatException('$field must contain strings');
    final normalized = _requiredString(raw, field, maxLength);
    if (seen.add(normalized)) result.add(normalized);
  }
  return result;
}

Map<String, Object?> _jsonObject(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  return value.map((key, nested) {
    if (key is! String) throw FormatException('$field keys must be strings');
    return MapEntry(key, nested);
  });
}
