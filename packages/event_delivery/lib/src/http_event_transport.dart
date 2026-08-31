import 'dart:async';
import 'dart:convert';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:http/http.dart' as http;

import 'api_http_policy.dart';
import 'event_delivery_core.dart';

final class HttpEventTransport implements EventTransport {
  HttpEventTransport({
    required Uri baseUri,
    required ActorAccessIdentity actorAccess,
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 10),
    bool allowInsecureLocalhost = false,
  }) : _policy = ApiHttpPolicy(
         baseUri: baseUri,
         requestTimeout: requestTimeout,
         allowInsecureLocalhost: allowInsecureLocalhost,
       ),
       _actorAccess = actorAccess,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final ApiHttpPolicy _policy;
  final ActorAccessIdentity _actorAccess;
  final http.Client _client;
  final bool _ownsClient;
  var _registered = false;
  var _closed = false;

  Duration get requestTimeout => _policy.requestTimeout;
  Uri get endpoint => _policy.resolve('v1/events');
  Uri get actorEndpoint => _policy.resolve('v1/actors');

  @override
  Future<EventDeliveryResult> deliver(MosaicEventEnvelope event) async {
    if (_closed) {
      return const EventDeliveryResult(
        EventDeliveryDisposition.retryableFailure,
      );
    }
    if (event.actorId != _actorAccess.actorId) {
      return const EventDeliveryResult(EventDeliveryDisposition.rejected);
    }

    final actorResult = await _ensureActor();
    if (actorResult.disposition != EventDeliveryDisposition.accepted) {
      return actorResult;
    }

    return _postJson(
      endpoint,
      event.toJson(),
      acceptedStatusCodes: const {200, 202},
    );
  }

  Future<EventDeliveryResult> _ensureActor() async {
    if (_registered) {
      return const EventDeliveryResult(EventDeliveryDisposition.accepted);
    }

    final result = await _policy.registerActor(
      client: _client,
      actorAccess: _actorAccess,
    );
    switch (result.disposition) {
      case ActorRegistrationDisposition.accepted:
        _registered = true;
        return EventDeliveryResult(
          EventDeliveryDisposition.accepted,
          statusCode: result.statusCode,
        );
      case ActorRegistrationDisposition.retryableFailure:
        return EventDeliveryResult(
          EventDeliveryDisposition.retryableFailure,
          statusCode: result.statusCode,
        );
      case ActorRegistrationDisposition.identityRecoveryRequired:
      case ActorRegistrationDisposition.rejected:
        return EventDeliveryResult(
          EventDeliveryDisposition.rejected,
          statusCode: result.statusCode,
        );
    }
  }

  Future<EventDeliveryResult> _postJson(
    Uri uri,
    Map<String, Object?> body, {
    required Set<int> acceptedStatusCodes,
  }) async {
    try {
      final response = await _client
          .post(
            uri,
            headers: actorAuthorizationHeaders(
              _actorAccess.accessToken,
              json: true,
            ),
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);
      final statusCode = response.statusCode;
      if (acceptedStatusCodes.contains(statusCode)) {
        return EventDeliveryResult(
          EventDeliveryDisposition.accepted,
          statusCode: statusCode,
        );
      }
      if (isRetryableHttpStatus(statusCode)) {
        return EventDeliveryResult(
          EventDeliveryDisposition.retryableFailure,
          statusCode: statusCode,
        );
      }
      return EventDeliveryResult(
        EventDeliveryDisposition.rejected,
        statusCode: statusCode,
      );
    } on Object {
      return const EventDeliveryResult(
        EventDeliveryDisposition.retryableFailure,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _registered = false;
    if (_ownsClient) _client.close();
  }
}
