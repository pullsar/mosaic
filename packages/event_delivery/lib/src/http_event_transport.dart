import 'dart:async';
import 'dart:convert';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:http/http.dart' as http;

import 'event_delivery_core.dart';

final class HttpEventTransport implements EventTransport {
  HttpEventTransport({
    required Uri baseUri,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
    bool allowInsecureLocalhost = false,
  }) : _baseUri = _validatedBaseUri(
         baseUri,
         allowInsecureLocalhost: allowInsecureLocalhost,
       ),
       _client = client ?? http.Client(),
       _ownsClient = client == null {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be positive',
      );
    }
  }

  final Uri _baseUri;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  final Set<String> _registeredActors = <String>{};
  var _closed = false;

  Uri get endpoint => _baseUri.resolve('v1/events');
  Uri get actorEndpoint => _baseUri.resolve('v1/actors');

  @override
  Future<EventDeliveryResult> deliver(MosaicEventEnvelope event) async {
    if (_closed) {
      return const EventDeliveryResult(
        EventDeliveryDisposition.retryableFailure,
      );
    }

    final actorResult = await _ensureActor(event.actorId);
    if (actorResult.disposition != EventDeliveryDisposition.accepted) {
      return actorResult;
    }

    return _postJson(
      endpoint,
      event.toJson(),
      acceptedStatusCodes: const {200, 202},
    );
  }

  Future<EventDeliveryResult> _ensureActor(String actorId) async {
    if (_registeredActors.contains(actorId)) {
      return const EventDeliveryResult(EventDeliveryDisposition.accepted);
    }

    final result = await _postJson(
      actorEndpoint,
      <String, Object?>{'actorId': actorId},
      acceptedStatusCodes: const {200, 201, 204},
    );
    if (result.disposition == EventDeliveryDisposition.accepted) {
      _registeredActors.add(actorId);
    }
    return result;
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
            headers: const {'content-type': 'application/json'},
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
      if (_isRetryableStatus(statusCode)) {
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
    _registeredActors.clear();
    if (_ownsClient) _client.close();
  }
}

bool _isRetryableStatus(int statusCode) =>
    statusCode == 408 ||
    statusCode == 425 ||
    statusCode == 429 ||
    statusCode >= 500;

Uri _validatedBaseUri(Uri baseUri, {required bool allowInsecureLocalhost}) {
  if (!baseUri.isAbsolute || baseUri.host.isEmpty) {
    throw ArgumentError.value(baseUri, 'baseUri', 'must be an absolute URI');
  }
  if (baseUri.hasQuery || baseUri.hasFragment) {
    throw ArgumentError.value(
      baseUri,
      'baseUri',
      'must not contain query or fragment components',
    );
  }

  final secure = baseUri.scheme == 'https';
  final localHttp =
      allowInsecureLocalhost &&
      baseUri.scheme == 'http' &&
      (baseUri.host == 'localhost' ||
          baseUri.host == '127.0.0.1' ||
          baseUri.host == '::1');
  if (!secure && !localHttp) {
    throw ArgumentError.value(
      baseUri,
      'baseUri',
      'must use HTTPS outside explicit localhost development',
    );
  }

  final normalizedPath = baseUri.path.endsWith('/')
      ? baseUri.path
      : '${baseUri.path}/';
  return baseUri.replace(path: normalizedPath);
}
