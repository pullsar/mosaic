import 'dart:convert';

import 'package:event_delivery/event_delivery.dart';
import 'package:http/http.dart' as http;
import 'package:play_schema/play_schema.dart';

enum ConsumerApiFailureKind {
  retryable,
  identityRecoveryRequired,
  invalidCursor,
  rejected,
  malformedResponse,
}

sealed class ConsumerApiResult<T> {
  const ConsumerApiResult();
}

final class ConsumerApiSuccess<T> extends ConsumerApiResult<T> {
  const ConsumerApiSuccess(this.value);

  final T value;
}

final class ConsumerApiFailure<T> extends ConsumerApiResult<T> {
  const ConsumerApiFailure(this.kind, {this.statusCode});

  final ConsumerApiFailureKind kind;
  final int? statusCode;
}

final class ConsumerTopic {
  ConsumerTopic({required String id, required String label})
    : id = _requiredText(id, 'topic.id', 200),
      label = _requiredText(label, 'topic.label', 200);

  final String id;
  final String label;

  factory ConsumerTopic.fromJson(Map<String, Object?> json) => ConsumerTopic(
    id: _requiredJsonString(json, 'id', 200),
    label: _requiredJsonString(json, 'label', 200),
  );
}

enum ConsumerSearchIntent {
  interest('interest'),
  learning('learning');

  const ConsumerSearchIntent(this.wireName);
  final String wireName;

  static ConsumerSearchIntent fromWire(Object? value) {
    for (final intent in values) {
      if (intent.wireName == value) return intent;
    }
    throw FormatException('Unsupported search intent: $value');
  }
}

enum ConsumerSearchMatchKind {
  topicExact('topic_exact'),
  topicPrefix('topic_prefix'),
  playExact('play_exact'),
  playPrefix('play_prefix');

  const ConsumerSearchMatchKind(this.wireName);
  final String wireName;

  static ConsumerSearchMatchKind fromWire(Object? value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    throw FormatException('Unsupported search match kind: $value');
  }
}

sealed class ConsumerSearchResult {
  const ConsumerSearchResult({required this.position, required this.matchKind});

  final int position;
  final ConsumerSearchMatchKind matchKind;
}

final class ConsumerSearchTopicResult extends ConsumerSearchResult {
  ConsumerSearchTopicResult({
    required super.position,
    required super.matchKind,
    required String topicId,
    required String label,
  }) : topicId = _requiredText(topicId, 'topicId', 200),
       label = _requiredText(label, 'label', 200) {
    if (matchKind != ConsumerSearchMatchKind.topicExact &&
        matchKind != ConsumerSearchMatchKind.topicPrefix) {
      throw const FormatException('Topic result requires a topic match kind.');
    }
  }

  final String topicId;
  final String label;

  factory ConsumerSearchTopicResult.fromJson(Map<String, Object?> json) =>
      ConsumerSearchTopicResult(
        position: _requiredBoundedInt(json['position'], 'position', 0, 59),
        matchKind: ConsumerSearchMatchKind.fromWire(json['matchKind']),
        topicId: _requiredJsonString(json, 'topicId', 200),
        label: _requiredJsonString(json, 'label', 200),
      );
}

final class ConsumerSearchPlayResult extends ConsumerSearchResult {
  ConsumerSearchPlayResult._({
    required super.position,
    required super.matchKind,
    required this.playId,
    required this.revisionId,
    required this.play,
  });

  final String playId;
  final String revisionId;
  final PlayDocument play;

  static ConsumerSearchPlayResult fromJson(
    Map<String, Object?> json, {
    required PlayCompatibilityChecker compatibilityChecker,
    required PlayCapabilityEnvelope capabilities,
  }) {
    final playId = _requiredJsonString(json, 'playId', 200);
    final revisionId = _requiredJsonString(json, 'revisionId', 200);
    final matchKind = ConsumerSearchMatchKind.fromWire(json['matchKind']);
    if (matchKind != ConsumerSearchMatchKind.playExact &&
        matchKind != ConsumerSearchMatchKind.playPrefix &&
        matchKind != ConsumerSearchMatchKind.topicExact &&
        matchKind != ConsumerSearchMatchKind.topicPrefix) {
      throw const FormatException('Invalid Play search match kind.');
    }
    final play = _validatedPlayDocument(
      _jsonObject(json['document'], 'search Play document'),
      playId: playId,
      revisionId: revisionId,
      compatibilityChecker: compatibilityChecker,
      capabilities: capabilities,
    );
    return ConsumerSearchPlayResult._(
      position: _requiredBoundedInt(json['position'], 'position', 0, 59),
      matchKind: matchKind,
      playId: playId,
      revisionId: revisionId,
      play: play,
    );
  }
}

final class ConsumerSearchPage {
  ConsumerSearchPage._({
    required this.requestId,
    required this.intent,
    required this.queryHash,
    required this.resultCount,
    required this.items,
    required this.nextCursor,
  });

  final String requestId;
  final ConsumerSearchIntent intent;
  final String queryHash;
  final int resultCount;
  final List<ConsumerSearchResult> items;
  final String? nextCursor;

  static ConsumerSearchPage fromJson(
    Map<String, Object?> json, {
    required PlayCompatibilityChecker compatibilityChecker,
    required PlayCapabilityEnvelope capabilities,
  }) {
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > 20) {
      throw const FormatException(
        'search items must contain at most 20 results',
      );
    }
    final queryHash = _requiredJsonString(json, 'queryHash', 64);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(queryHash)) {
      throw const FormatException('queryHash must be SHA-256 hex');
    }
    final rawCursor = json['nextCursor'];
    if (rawCursor != null && rawCursor is! String) {
      throw const FormatException('search nextCursor must be a string or null');
    }
    final items = <ConsumerSearchResult>[];
    for (final raw in rawItems) {
      final item = _jsonObject(raw, 'search item');
      switch (item['kind']) {
        case 'topic':
          items.add(ConsumerSearchTopicResult.fromJson(item));
        case 'play':
          items.add(
            ConsumerSearchPlayResult.fromJson(
              item,
              compatibilityChecker: compatibilityChecker,
              capabilities: capabilities,
            ),
          );
        default:
          throw const FormatException('search item kind must be topic or play');
      }
    }
    return ConsumerSearchPage._(
      requestId: _requiredJsonString(json, 'requestId', 200),
      intent: ConsumerSearchIntent.fromWire(json['intent']),
      queryHash: queryHash,
      resultCount: _requiredBoundedInt(
        json['resultCount'],
        'resultCount',
        0,
        60,
      ),
      items: List<ConsumerSearchResult>.unmodifiable(items),
      nextCursor: rawCursor == null
          ? null
          : _requiredText(rawCursor as String, 'nextCursor', 512),
    );
  }
}

final class ConsumerFeedSearchIntent {
  ConsumerFeedSearchIntent({required this.intent, required String topicId})
    : topicId = _requiredText(topicId, 'topicId', 200);

  final ConsumerSearchIntent intent;
  final String topicId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': intent.wireName,
    'topicId': topicId,
  };
}

final class ConsumerPreferences {
  ConsumerPreferences({
    List<String> interestTopicIds = const [],
    List<String> learningTopicIds = const [],
  }) : interestTopicIds = List.unmodifiable(
         _topicIds(interestTopicIds, 'interestTopicIds'),
       ),
       learningTopicIds = List.unmodifiable(
         _topicIds(learningTopicIds, 'learningTopicIds'),
       );

  final List<String> interestTopicIds;
  final List<String> learningTopicIds;

  factory ConsumerPreferences.fromJson(Map<String, Object?> json) =>
      ConsumerPreferences(
        interestTopicIds: _jsonStringList(
          json['interestTopicIds'],
          'interestTopicIds',
        ),
        learningTopicIds: _jsonStringList(
          json['learningTopicIds'],
          'learningTopicIds',
        ),
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'interestTopicIds': interestTopicIds,
    'learningTopicIds': learningTopicIds,
  };
}

final class ConsumerRemotePlayActionState {
  ConsumerRemotePlayActionState({
    required String playId,
    required this.saved,
    String? savedRevisionId,
    required this.moreLikeThis,
    required this.notInterested,
  }) : playId = _requiredText(playId, 'playId', 200),
       savedRevisionId = savedRevisionId == null
           ? null
           : _requiredText(savedRevisionId, 'savedRevisionId', 200) {
    if (saved && this.savedRevisionId == null) {
      throw const FormatException('savedRevisionId is required when saved');
    }
  }

  final String playId;
  final bool saved;
  final String? savedRevisionId;
  final bool moreLikeThis;
  final bool notInterested;

  factory ConsumerRemotePlayActionState.fromJson(Map<String, Object?> json) {
    final saved = json['saved'];
    final moreLikeThis = json['moreLikeThis'];
    final notInterested = json['notInterested'];
    if (saved is! bool || moreLikeThis is! bool || notInterested is! bool) {
      throw const FormatException('action flags must be booleans');
    }
    final rawRevision = json['savedRevisionId'];
    if (rawRevision != null && rawRevision is! String) {
      throw const FormatException('savedRevisionId must be a string or null');
    }
    return ConsumerRemotePlayActionState(
      playId: _requiredJsonString(json, 'playId', 200),
      saved: saved,
      savedRevisionId: rawRevision as String?,
      moreLikeThis: moreLikeThis,
      notInterested: notInterested,
    );
  }
}

final class ConsumerRemoteActionState {
  ConsumerRemoteActionState({
    required this.play,
    required List<String> mutedTopicIds,
  }) : mutedTopicIds = List.unmodifiable(
         _topicIds(mutedTopicIds, 'mutedTopicIds'),
       );

  final ConsumerRemotePlayActionState play;
  final List<String> mutedTopicIds;

  factory ConsumerRemoteActionState.fromJson(Map<String, Object?> json) =>
      ConsumerRemoteActionState(
        play: ConsumerRemotePlayActionState.fromJson(
          _jsonObject(json['play'], 'action play state'),
        ),
        mutedTopicIds: _jsonStringList(json['mutedTopicIds'], 'mutedTopicIds'),
      );
}

enum ConsumerFeedSourceBucket {
  known('known'),
  wildcard('wildcard'),
  curatedFallback('curated_fallback');

  const ConsumerFeedSourceBucket(this.wireName);
  final String wireName;

  static ConsumerFeedSourceBucket fromWire(Object? value) {
    if (value is! String) {
      throw const FormatException('feed item sourceBucket must be a string');
    }
    for (final bucket in values) {
      if (bucket.wireName == value) return bucket;
    }
    throw FormatException('Unsupported feed sourceBucket: $value');
  }
}

final class ConsumerFeedItem {
  ConsumerFeedItem._({
    required this.playId,
    required this.revisionId,
    required this.sourceBucket,
    required this.play,
  });

  final String playId;
  final String revisionId;
  final ConsumerFeedSourceBucket sourceBucket;
  final PlayDocument play;

  Map<String, Object?> get validatedDocumentJson => play.toJson();

  static ConsumerFeedItem fromJson(
    Map<String, Object?> json, {
    required PlayCompatibilityChecker compatibilityChecker,
    required PlayCapabilityEnvelope capabilities,
  }) {
    final playId = _requiredJsonString(json, 'playId', 200);
    final revisionId = _requiredJsonString(json, 'revisionId', 200);
    final sourceBucket = ConsumerFeedSourceBucket.fromWire(
      json['sourceBucket'],
    );
    final play = _validatedPlayDocument(
      _jsonObject(json['document'], 'feed item document'),
      playId: playId,
      revisionId: revisionId,
      compatibilityChecker: compatibilityChecker,
      capabilities: capabilities,
    );
    return ConsumerFeedItem._(
      playId: playId,
      revisionId: revisionId,
      sourceBucket: sourceBucket,
      play: play,
    );
  }
}

final class ConsumerFeedPage {
  ConsumerFeedPage._({
    required this.requestId,
    required this.rankingConfigVersion,
    required this.fallback,
    required this.items,
    required this.nextCursor,
  });

  final String requestId;
  final String rankingConfigVersion;
  final bool fallback;
  final List<ConsumerFeedItem> items;
  final String? nextCursor;

  static ConsumerFeedPage fromJson(
    Map<String, Object?> json, {
    required PlayCompatibilityChecker compatibilityChecker,
    required PlayCapabilityEnvelope capabilities,
  }) {
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > 20) {
      throw const FormatException(
        'feed items must be an array of at most 20 items',
      );
    }
    final fallback = json['fallback'];
    if (fallback is! bool) {
      throw const FormatException('feed fallback must be a boolean');
    }
    final rawCursor = json['nextCursor'];
    if (rawCursor != null && rawCursor is! String) {
      throw const FormatException('feed nextCursor must be a string or null');
    }
    final nextCursor = rawCursor == null
        ? null
        : _requiredText(rawCursor as String, 'nextCursor', 512);
    return ConsumerFeedPage._(
      requestId: _requiredJsonString(json, 'requestId', 200),
      rankingConfigVersion: _requiredJsonString(
        json,
        'rankingConfigVersion',
        200,
      ),
      fallback: fallback,
      items: List.unmodifiable(
        rawItems.map(
          (value) => ConsumerFeedItem.fromJson(
            _jsonObject(value, 'feed item'),
            compatibilityChecker: compatibilityChecker,
            capabilities: capabilities,
          ),
        ),
      ),
      nextCursor: nextCursor,
    );
  }
}

final class ConsumerApiClient {
  ConsumerApiClient({
    required Uri baseUri,
    required ActorAccessIdentity actorAccess,
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 10),
    bool allowInsecureLocalhost = false,
    PlayCompatibilityChecker compatibilityChecker =
        const PlayCompatibilityChecker(),
  }) : _policy = ApiHttpPolicy(
         baseUri: baseUri,
         requestTimeout: requestTimeout,
         allowInsecureLocalhost: allowInsecureLocalhost,
       ),
       _actorAccess = actorAccess,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _compatibilityChecker = compatibilityChecker;

  final ApiHttpPolicy _policy;
  final ActorAccessIdentity _actorAccess;
  final http.Client _client;
  final bool _ownsClient;
  final PlayCompatibilityChecker _compatibilityChecker;
  var _registered = false;
  var _closed = false;

  Future<ConsumerApiResult<List<ConsumerTopic>>> searchTopics({
    String query = '',
    int limit = 30,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.length > 100) {
      throw ArgumentError.value(
        query,
        'query',
        'must be at most 100 characters',
      );
    }
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 100');
    }
    final endpoint = _policy
        .resolve('v1/topics')
        .replace(
          queryParameters: <String, String>{
            'q': normalizedQuery,
            'limit': '$limit',
          },
        );
    final response = await _send(() => _client.get(endpoint));
    if (response == null) {
      return const ConsumerApiFailure(ConsumerApiFailureKind.retryable);
    }
    if (response.statusCode != 200) {
      return _failureForResponse(response);
    }
    try {
      final json = _decodeResponseObject(response.body);
      final rawTopics = json['topics'];
      if (rawTopics is! List || rawTopics.length > 100) {
        throw const FormatException(
          'topics must be an array of at most 100 items',
        );
      }
      return ConsumerApiSuccess(
        List<ConsumerTopic>.unmodifiable(
          rawTopics.map(
            (value) => ConsumerTopic.fromJson(_jsonObject(value, 'topic')),
          ),
        ),
      );
    } on Object {
      return const ConsumerApiFailure(
        ConsumerApiFailureKind.malformedResponse,
        statusCode: 200,
      );
    }
  }

  Future<ConsumerApiResult<ConsumerSearchPage>> search({
    required PlayCapabilityEnvelope capabilities,
    String? query,
    ConsumerSearchIntent? intent,
    String? cursor,
    int limit = 12,
  }) async {
    if (limit < 1 || limit > 20) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 20');
    }
    if (cursor != null && (cursor.isEmpty || cursor.length > 512)) {
      throw ArgumentError.value(
        cursor,
        'cursor',
        'must be 1 to 512 characters',
      );
    }
    String? normalizedQuery;
    if (cursor == null) {
      normalizedQuery = query?.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (normalizedQuery == null ||
          normalizedQuery.isEmpty ||
          normalizedQuery.length > 80) {
        throw ArgumentError.value(query, 'query', 'must be 1 to 80 characters');
      }
      if (intent == null) {
        throw ArgumentError.notNull('intent');
      }
    }
    final registrationFailure = await _ensureRegistered<ConsumerSearchPage>();
    if (registrationFailure != null) return registrationFailure;
    final response = await _send(
      () => _client.post(
        _policy.resolve('v1/search'),
        headers: actorAuthorizationHeaders(
          _actorAccess.accessToken,
          json: true,
        ),
        body: jsonEncode(<String, Object?>{
          'actorId': _actorAccess.actorId,
          'capabilities': capabilities.toJson(),
          'cursor': cursor,
          'limit': limit,
          if (cursor == null) 'query': normalizedQuery,
          if (cursor == null) 'intent': intent!.wireName,
        }),
      ),
    );
    if (response == null) {
      return const ConsumerApiFailure(ConsumerApiFailureKind.retryable);
    }
    if (response.statusCode != 200) {
      return _failureForResponse(
        response,
        invalidCursorCode: 'invalid_search_cursor',
      );
    }
    try {
      return ConsumerApiSuccess(
        ConsumerSearchPage.fromJson(
          _decodeResponseObject(response.body),
          compatibilityChecker: _compatibilityChecker,
          capabilities: capabilities,
        ),
      );
    } on Object {
      return const ConsumerApiFailure(
        ConsumerApiFailureKind.malformedResponse,
        statusCode: 200,
      );
    }
  }

  Future<ConsumerApiResult<ConsumerPreferences>> getPreferences() async {
    final registrationFailure = await _ensureRegistered<ConsumerPreferences>();
    if (registrationFailure != null) return registrationFailure;
    final response = await _send(
      () => _client.get(
        _preferencesEndpoint,
        headers: actorAuthorizationHeaders(_actorAccess.accessToken),
      ),
    );
    if (response == null) {
      return const ConsumerApiFailure(ConsumerApiFailureKind.retryable);
    }
    if (response.statusCode != 200) {
      return _failureForResponse(response);
    }
    try {
      return ConsumerApiSuccess(
        ConsumerPreferences.fromJson(_decodeResponseObject(response.body)),
      );
    } on Object {
      return const ConsumerApiFailure(
        ConsumerApiFailureKind.malformedResponse,
        statusCode: 200,
      );
    }
  }

  Future<ConsumerApiResult<ConsumerPreferences>> replacePreferences(
    ConsumerPreferences preferences,
  ) async {
    final registrationFailure = await _ensureRegistered<ConsumerPreferences>();
    if (registrationFailure != null) return registrationFailure;
    final response = await _send(
      () => _client.put(
        _preferencesEndpoint,
        headers: actorAuthorizationHeaders(
          _actorAccess.accessToken,
          json: true,
        ),
        body: jsonEncode(preferences.toJson()),
      ),
    );
    if (response == null) {
      return const ConsumerApiFailure(ConsumerApiFailureKind.retryable);
    }
    if (response.statusCode != 204) {
      return _failureForResponse(response);
    }
    return ConsumerApiSuccess(preferences);
  }

  Future<ConsumerApiResult<ConsumerRemoteActionState>> getActionState(
    String playId,
  ) async {
    final normalizedPlayId = playId.trim();
    if (normalizedPlayId.isEmpty || normalizedPlayId.length > 200) {
      throw ArgumentError.value(
        playId,
        'playId',
        'must be 1 to 200 characters',
      );
    }
    final registrationFailure =
        await _ensureRegistered<ConsumerRemoteActionState>();
    if (registrationFailure != null) return registrationFailure;
    final response = await _send(
      () => _client.get(
        _actionStateEndpoint(normalizedPlayId),
        headers: actorAuthorizationHeaders(_actorAccess.accessToken),
      ),
    );
    if (response == null) {
      return const ConsumerApiFailure(ConsumerApiFailureKind.retryable);
    }
    if (response.statusCode != 200) {
      return _failureForResponse(response);
    }
    try {
      final state = ConsumerRemoteActionState.fromJson(
        _decodeResponseObject(response.body),
      );
      if (state.play.playId != normalizedPlayId) {
        throw const FormatException('action state Play identity mismatch');
      }
      return ConsumerApiSuccess(state);
    } on Object {
      return const ConsumerApiFailure(
        ConsumerApiFailureKind.malformedResponse,
        statusCode: 200,
      );
    }
  }

  Future<ConsumerApiResult<ConsumerFeedPage>> fetchFeed({
    required PlayCapabilityEnvelope capabilities,
    String? cursor,
    int limit = 8,
    ConsumerFeedSearchIntent? searchIntent,
  }) async {
    if (limit < 1 || limit > 20) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 20');
    }
    if (cursor != null && (cursor.isEmpty || cursor.length > 512)) {
      throw ArgumentError.value(
        cursor,
        'cursor',
        'must be 1 to 512 characters',
      );
    }
    final registrationFailure = await _ensureRegistered<ConsumerFeedPage>();
    if (registrationFailure != null) return registrationFailure;
    final response = await _send(
      () => _client.post(
        _policy.resolve('v1/feed'),
        headers: actorAuthorizationHeaders(
          _actorAccess.accessToken,
          json: true,
        ),
        body: jsonEncode(<String, Object?>{
          'actorId': _actorAccess.actorId,
          'capabilities': capabilities.toJson(),
          'cursor': cursor,
          'limit': limit,
          if (searchIntent != null) 'searchIntent': searchIntent.toJson(),
        }),
      ),
    );
    if (response == null) {
      return const ConsumerApiFailure(ConsumerApiFailureKind.retryable);
    }
    if (response.statusCode != 200) {
      return _failureForResponse(
        response,
        invalidCursorCode: 'invalid_feed_cursor',
      );
    }
    try {
      return ConsumerApiSuccess(
        ConsumerFeedPage.fromJson(
          _decodeResponseObject(response.body),
          compatibilityChecker: _compatibilityChecker,
          capabilities: capabilities,
        ),
      );
    } on Object {
      return const ConsumerApiFailure(
        ConsumerApiFailureKind.malformedResponse,
        statusCode: 200,
      );
    }
  }

  Uri _actionStateEndpoint(String playId) => _policy.resolve(
    'v1/actors/${Uri.encodeComponent(_actorAccess.actorId)}/actions/'
    '${Uri.encodeComponent(playId)}',
  );

  Uri get _preferencesEndpoint => _policy.resolve(
    'v1/actors/${Uri.encodeComponent(_actorAccess.actorId)}/preferences',
  );

  Future<ConsumerApiFailure<T>?> _ensureRegistered<T>() async {
    if (_registered) return null;
    if (_closed) {
      return const ConsumerApiFailure(ConsumerApiFailureKind.retryable);
    }
    final result = await _policy.registerActor(
      client: _client,
      actorAccess: _actorAccess,
    );
    switch (result.disposition) {
      case ActorRegistrationDisposition.accepted:
        _registered = true;
        return null;
      case ActorRegistrationDisposition.retryableFailure:
        return ConsumerApiFailure(
          ConsumerApiFailureKind.retryable,
          statusCode: result.statusCode,
        );
      case ActorRegistrationDisposition.identityRecoveryRequired:
        return ConsumerApiFailure(
          ConsumerApiFailureKind.identityRecoveryRequired,
          statusCode: result.statusCode,
        );
      case ActorRegistrationDisposition.rejected:
        return ConsumerApiFailure(
          ConsumerApiFailureKind.rejected,
          statusCode: result.statusCode,
        );
    }
  }

  Future<http.Response?> _send(Future<http.Response> Function() request) async {
    if (_closed) return null;
    try {
      return await request().timeout(_policy.requestTimeout);
    } on Object {
      return null;
    }
  }

  ConsumerApiFailure<T> _failureForResponse<T>(
    http.Response response, {
    String? invalidCursorCode,
  }) {
    final statusCode = response.statusCode;
    if (statusCode == 401 || statusCode == 403) {
      return ConsumerApiFailure(
        ConsumerApiFailureKind.identityRecoveryRequired,
        statusCode: statusCode,
      );
    }
    if (isRetryableHttpStatus(statusCode)) {
      return ConsumerApiFailure(
        ConsumerApiFailureKind.retryable,
        statusCode: statusCode,
      );
    }
    if (invalidCursorCode != null &&
        statusCode == 400 &&
        _responseErrorCode(response.body) == invalidCursorCode) {
      return ConsumerApiFailure(
        ConsumerApiFailureKind.invalidCursor,
        statusCode: statusCode,
      );
    }
    return ConsumerApiFailure(
      ConsumerApiFailureKind.rejected,
      statusCode: statusCode,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _registered = false;
    if (_ownsClient) _client.close();
  }
}

PlayDocument _validatedPlayDocument(
  Map<String, Object?> rawDocument, {
  required String playId,
  required String revisionId,
  required PlayCompatibilityChecker compatibilityChecker,
  required PlayCapabilityEnvelope capabilities,
}) {
  final decoded = compatibilityChecker.decode(rawDocument, capabilities);
  if (decoded is! DecodedPlay) {
    throw const FormatException('Play is malformed or unsupported.');
  }
  final play = decoded.play;
  if (play.id != playId || play.revisionId != revisionId) {
    throw const FormatException(
      'Play identifiers do not match the decoded document.',
    );
  }
  return play;
}

int _requiredBoundedInt(Object? value, String field, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw FormatException('$field must be an integer between $min and $max');
  }
  return value;
}

Map<String, Object?> _decodeResponseObject(String body) {
  final value = jsonDecode(body);
  return _jsonObject(value, 'response');
}

String? _responseErrorCode(String body) {
  try {
    final value = _decodeResponseObject(body)['error'];
    return value is String ? value : null;
  } on Object {
    return null;
  }
}

Map<String, Object?> _jsonObject(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$field must contain string keys');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _requiredJsonString(
  Map<String, Object?> json,
  String key,
  int maxLength,
) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return _requiredText(value, key, maxLength);
}

String _requiredText(String value, String field, int maxLength) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) {
    throw FormatException('$field must be 1 to $maxLength characters');
  }
  return normalized;
}

List<String> _jsonStringList(Object? value, String field) {
  if (value is! List || value.length > 64) {
    throw FormatException('$field must be an array of at most 64 items');
  }
  return value
      .map((item) {
        if (item is! String)
          throw FormatException('$field must contain strings');
        return _requiredText(item, field, 200);
      })
      .toList(growable: false);
}

List<String> _topicIds(List<String> values, String field) {
  if (values.length > 64) {
    throw ArgumentError.value(values, field, 'supports at most 64 topics');
  }
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final normalized = _requiredText(value, field, 200);
    if (seen.add(normalized)) result.add(normalized);
  }
  return result;
}
