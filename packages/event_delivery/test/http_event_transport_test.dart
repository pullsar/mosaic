import 'dart:convert';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final _actorAccess = ActorAccessIdentity(
  actorId: 'actor_1',
  accessToken: 'A' * 43,
);

MosaicEventEnvelope _event({
  String actorId = 'actor_1',
  String eventId = 'evt_1',
}) => MosaicEventEnvelope(
  eventId: eventId,
  event: MosaicEventName.mediaPlayback,
  occurredAt: DateTime.utc(2026, 8, 28, 18),
  actorId: actorId,
  sessionId: 'session_1',
  payload: const {'browser': 'safari', 'videoCodec': 'h264'},
);

void main() {
  test(
    'registers one actor with proof then accepts inserted and duplicate events',
    () async {
      final requests = <http.Request>[];
      var eventCalls = 0;
      final client = MockClient((request) async {
        requests.add(request);
        expect(request.headers['authorization'], 'Bearer ${'A' * 43}');
        expect(request.headers['content-type'], 'application/json');
        if (request.url.path == '/v1/actors') {
          expect(jsonDecode(request.body), {'actorId': 'actor_1'});
          return http.Response('{"actorId":"actor_1"}', 201);
        }
        expect(request.url.path, '/v1/events');
        eventCalls += 1;
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['actorId'], 'actor_1');
        expect(body['eventId'], eventCalls == 1 ? 'evt_1' : 'evt_2');
        return http.Response(
          eventCalls == 1 ? '{"status":"inserted"}' : '{"status":"duplicate"}',
          eventCalls == 1 ? 202 : 200,
        );
      });
      final transport = HttpEventTransport(
        baseUri: Uri.parse('https://api.example.test/'),
        actorAccess: _actorAccess,
        client: client,
      );

      final first = await transport.deliver(_event());
      final second = await transport.deliver(_event(eventId: 'evt_2'));

      expect(first.disposition, EventDeliveryDisposition.accepted);
      expect(first.statusCode, 202);
      expect(second.disposition, EventDeliveryDisposition.accepted);
      expect(second.statusCode, 200);
      expect(
        requests.where((request) => request.url.path == '/v1/actors'),
        hasLength(1),
      );
      expect(
        requests.where((request) => request.url.path == '/v1/events'),
        hasLength(2),
      );
    },
  );

  test('actor registration failure prevents event submission', () async {
    var eventSubmitted = false;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/actors') {
        return http.Response('temporary outage', 503);
      }
      eventSubmitted = true;
      return http.Response('unexpected', 500);
    });
    final transport = HttpEventTransport(
      baseUri: Uri.parse('https://api.example.test/'),
      actorAccess: _actorAccess,
      client: client,
    );

    final result = await transport.deliver(_event());

    expect(result.disposition, EventDeliveryDisposition.retryableFailure);
    expect(result.statusCode, 503);
    expect(eventSubmitted, isFalse);
  });

  test(
    'classifies retryable and permanent event responses separately',
    () async {
      var eventStatus = 429;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/actors') return http.Response('{}', 201);
        return http.Response('{}', eventStatus);
      });
      final transport = HttpEventTransport(
        baseUri: Uri.parse('https://api.example.test/root/'),
        actorAccess: _actorAccess,
        client: client,
      );

      final throttled = await transport.deliver(_event());
      eventStatus = 400;
      final invalid = await transport.deliver(_event(eventId: 'evt_2'));

      expect(transport.endpoint.path, '/root/v1/events');
      expect(throttled.disposition, EventDeliveryDisposition.retryableFailure);
      expect(invalid.disposition, EventDeliveryDisposition.rejected);
      expect(invalid.statusCode, 400);
    },
  );

  test('rejects event identity mismatch without network I/O', () async {
    var requested = false;
    final transport = HttpEventTransport(
      baseUri: Uri.parse('https://api.example.test/'),
      actorAccess: _actorAccess,
      client: MockClient((_) async {
        requested = true;
        return http.Response('{}', 201);
      }),
    );

    final result = await transport.deliver(_event(actorId: 'actor_other'));

    expect(result.disposition, EventDeliveryDisposition.rejected);
    expect(requested, isFalse);
  });

  test('requires HTTPS except explicit localhost development', () {
    expect(
      () => HttpEventTransport(
        baseUri: Uri.parse('http://example.test/'),
        actorAccess: _actorAccess,
      ),
      throwsArgumentError,
    );
    expect(
      () => HttpEventTransport(
        baseUri: Uri.parse('http://localhost:3000/'),
        actorAccess: _actorAccess,
        allowInsecureLocalhost: true,
      ),
      returnsNormally,
    );
    expect(
      () => HttpEventTransport(
        baseUri: Uri.parse('https://api.example.test/?token=bad'),
        actorAccess: _actorAccess,
      ),
      throwsArgumentError,
    );
  });

  test('actor access tokens are strict and secure generator matches wire shape', () {
    final token = secureActorAccessToken();
    expect(token, hasLength(43));
    expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token), isTrue);
    expect(
      actorAuthorizationHeaders(token, json: true),
      {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
    );
    expect(() => ActorAccessIdentity(actorId: 'a', accessToken: 'weak'), throwsArgumentError);
  });

  test('closed transport degrades to retryable failure', () async {
    final transport = HttpEventTransport(
      baseUri: Uri.parse('https://api.example.test/'),
      actorAccess: _actorAccess,
      client: MockClient((_) async => http.Response('{}', 201)),
    );
    await transport.close();

    final result = await transport.deliver(_event());
    expect(result.disposition, EventDeliveryDisposition.retryableFailure);
  });
}
