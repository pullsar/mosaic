import 'dart:convert';

import 'package:event_delivery/event_delivery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:play_schema/play_schema.dart';

const _actorToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

final _actorAccess = ActorAccessIdentity(
  actorId: 'actor_1',
  accessToken: _actorToken,
);

Map<String, Object?> _playJson({
  String id = 'play_1',
  String revisionId = 'rev_1',
}) => <String, Object?>{
  'schemaVersion': 1,
  'id': id,
  'revisionId': revisionId,
  'format': 'discover',
  'classification': 'fact',
  'topics': <String>['science'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 15,
  'assets': <String>[],
  'sources': <Object?>[],
  'entryState': 'start',
  'states': <String, Object?>{
    'start': <String, Object?>{
      'presentation': <String, Object?>{
        'layers': <Object?>[
          <String, Object?>{'type': 'text', 'value': 'Hello'},
        ],
      },
      'input': <String, Object?>{'type': 'tap'},
      'validation': <String, Object?>{'type': 'none'},
      'transition': <String, Object?>{},
    },
  },
};

Map<String, Object?> _feedJson({
  String playId = 'play_1',
  String revisionId = 'rev_1',
  String? nextCursor = 'opaque+/=_cursor',
}) => <String, Object?>{
  'requestId': 'feed_request_1',
  'rankingConfigVersion': 'm2-rules-v1',
  'fallback': false,
  'items': <Object?>[
    <String, Object?>{
      'playId': playId,
      'revisionId': revisionId,
      'sourceBucket': 'known',
      'document': _playJson(),
    },
  ],
  'nextCursor': nextCursor,
};

void main() {
  test('first private request registers actor before preferences', () async {
    final paths = <String>[];
    final client = ConsumerApiClient(
      baseUri: Uri.parse('https://api.example.test/'),
      actorAccess: _actorAccess,
      client: MockClient((request) async {
        paths.add(request.url.path);
        expect(request.headers['authorization'], 'Bearer $_actorToken');
        if (request.url.path == '/v1/actors') {
          expect(jsonDecode(request.body), <String, Object?>{'actorId': 'actor_1'});
          return http.Response('{"actorId":"actor_1"}', 201);
        }
        return http.Response(
          '{"interestTopicIds":["science"],"learningTopicIds":[]}',
          200,
        );
      }),
    );

    final result = await client.getPreferences();

    expect(paths, <String>['/v1/actors', '/v1/actors/actor_1/preferences']);
    expect(result, isA<ConsumerApiSuccess<ConsumerPreferences>>());
    final preferences = (result as ConsumerApiSuccess<ConsumerPreferences>).value;
    expect(preferences.interestTopicIds, <String>['science']);
  });

  test('feed passes opaque cursor unchanged and validates Play envelope IDs', () async {
    const cursor = 'opaque+/=_cursor';
    final client = ConsumerApiClient(
      baseUri: Uri.parse('https://api.example.test/'),
      actorAccess: _actorAccess,
      client: MockClient((request) async {
        if (request.url.path == '/v1/actors') return http.Response('{}', 200);
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['cursor'], cursor);
        return http.Response(jsonEncode(_feedJson(nextCursor: cursor)), 200);
      }),
    );

    final result = await client.fetchFeed(
      capabilities: PlayCapabilityEnvelope.m1(),
      cursor: cursor,
    );

    expect(result, isA<ConsumerApiSuccess<ConsumerFeedPage>>());
    final page = (result as ConsumerApiSuccess<ConsumerFeedPage>).value;
    expect(page.nextCursor, cursor);
    expect(page.items.single.play.id, 'play_1');
    expect(page.items.single.validatedDocumentJson['revisionId'], 'rev_1');
  });

  test('feed rejects envelope/document identifier mismatch', () async {
    final client = ConsumerApiClient(
      baseUri: Uri.parse('https://api.example.test/'),
      actorAccess: _actorAccess,
      client: MockClient((request) async {
        if (request.url.path == '/v1/actors') return http.Response('{}', 201);
        return http.Response(
          jsonEncode(_feedJson(playId: 'play_other')),
          200,
        );
      }),
    );

    final result = await client.fetchFeed(
      capabilities: PlayCapabilityEnvelope.m1(),
    );

    expect(result, isA<ConsumerApiFailure<ConsumerFeedPage>>());
    expect(
      (result as ConsumerApiFailure<ConsumerFeedPage>).kind,
      ConsumerApiFailureKind.malformedResponse,
    );
  });

  test('invalid cursor and actor rejection are distinct from retryable failure', () async {
    var feedStatus = 400;
    var feedBody = '{"error":"invalid_feed_cursor"}';
    final client = ConsumerApiClient(
      baseUri: Uri.parse('https://api.example.test/'),
      actorAccess: _actorAccess,
      client: MockClient((request) async {
        if (request.url.path == '/v1/actors') return http.Response('{}', 201);
        return http.Response(feedBody, feedStatus);
      }),
    );

    final invalidCursor = await client.fetchFeed(
      capabilities: PlayCapabilityEnvelope.m1(),
    );
    feedStatus = 403;
    feedBody = '{"error":"actor_credential_rejected"}';
    final rejected = await client.fetchFeed(
      capabilities: PlayCapabilityEnvelope.m1(),
    );
    feedStatus = 503;
    feedBody = '{}';
    final unavailable = await client.fetchFeed(
      capabilities: PlayCapabilityEnvelope.m1(),
    );

    expect(
      (invalidCursor as ConsumerApiFailure<ConsumerFeedPage>).kind,
      ConsumerApiFailureKind.invalidCursor,
    );
    expect(
      (rejected as ConsumerApiFailure<ConsumerFeedPage>).kind,
      ConsumerApiFailureKind.identityRecoveryRequired,
    );
    expect(
      (unavailable as ConsumerApiFailure<ConsumerFeedPage>).kind,
      ConsumerApiFailureKind.retryable,
    );
  });

  test('actor registration rotation blocks private request without retry loop', () async {
    var requests = 0;
    final client = ConsumerApiClient(
      baseUri: Uri.parse('https://api.example.test/'),
      actorAccess: _actorAccess,
      client: MockClient((request) async {
        requests += 1;
        return http.Response('{"error":"actor_rotation_required"}', 409);
      }),
    );

    final result = await client.getPreferences();
    final failure = result as ConsumerApiFailure<ConsumerPreferences>;

    expect(requests, 1);
    expect(failure.kind, ConsumerApiFailureKind.identityRecoveryRequired);
    expect(failure.statusCode, 409);
  });

  test('public topic search does not require actor registration', () async {
    final paths = <String>[];
    final client = ConsumerApiClient(
      baseUri: Uri.parse('https://api.example.test/root/'),
      actorAccess: _actorAccess,
      client: MockClient((request) async {
        paths.add(request.url.path);
        expect(request.url.queryParameters['q'], 'science');
        return http.Response(
          '{"topics":[{"id":"science","label":"Science"}]}',
          200,
        );
      }),
    );

    final result = await client.searchTopics(query: ' science ');

    expect(paths, <String>['/root/v1/topics']);
    expect(result, isA<ConsumerApiSuccess<List<ConsumerTopic>>>());
  });
}
