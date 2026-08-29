import 'package:event_delivery/event_delivery.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _actorToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

final _actorAccess = ActorAccessIdentity(
  actorId: 'actor_1',
  accessToken: _actorToken,
);

void main() {
  test(
    'normalizes API base URI and keeps explicit localhost exception narrow',
    () {
      final policy = ApiHttpPolicy(
        baseUri: Uri.parse('https://api.example.test/root'),
      );
      expect(
        policy.resolve('v1/feed').toString(),
        'https://api.example.test/root/v1/feed',
      );

      expect(
        () => ApiHttpPolicy(baseUri: Uri.parse('http://api.example.test/')),
        throwsArgumentError,
      );
      expect(
        () => ApiHttpPolicy(
          baseUri: Uri.parse('http://localhost:3000/'),
          allowInsecureLocalhost: true,
        ),
        returnsNormally,
      );
    },
  );

  test(
    'actor registration preserves accepted, retryable and recovery classes',
    () async {
      var status = 201;
      final policy = ApiHttpPolicy(
        baseUri: Uri.parse('https://api.example.test/'),
      );
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/actors');
        expect(request.headers['authorization'], 'Bearer $_actorToken');
        return http.Response('{}', status);
      });

      final created = await policy.registerActor(
        client: client,
        actorAccess: _actorAccess,
      );
      status = 503;
      final unavailable = await policy.registerActor(
        client: client,
        actorAccess: _actorAccess,
      );
      status = 409;
      final rotation = await policy.registerActor(
        client: client,
        actorAccess: _actorAccess,
      );

      expect(created.disposition, ActorRegistrationDisposition.accepted);
      expect(created.statusCode, 201);
      expect(
        unavailable.disposition,
        ActorRegistrationDisposition.retryableFailure,
      );
      expect(
        rotation.disposition,
        ActorRegistrationDisposition.identityRecoveryRequired,
      );
    },
  );

  test('retryable HTTP classification is shared and bounded', () {
    for (final status in [408, 425, 429, 500, 503]) {
      expect(isRetryableHttpStatus(status), isTrue, reason: '$status');
    }
    for (final status in [200, 400, 401, 403, 404, 409, 422]) {
      expect(isRetryableHttpStatus(status), isFalse, reason: '$status');
    }
  });
}
