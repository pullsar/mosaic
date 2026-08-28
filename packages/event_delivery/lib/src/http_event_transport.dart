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
  }) : _endpoint = _eventEndpoint(
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

  final Uri _endpoint;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  var _closed = false;

  Uri get endpoint => _endpoint;

  @override
  Future<EventDeliveryResult> deliver(MosaicEventEnvelope event) async {
    if (_closed) {
      return const EventDeliveryResult(
        EventDeliveryDisposition.retryableFailure,
      );
    }

    try {
      final response = await _client
          .post(
            _endpoint,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(event.toJson()),
          )
          .timeout(requestTimeout);
      final statusCode = response.statusCode;
      if (statusCode == 200 || statusCode == 202) {
        return EventDeliveryResult(
          EventDeliveryDisposition.accepted,
          statusCode: statusCode,
        );
      }
      if (statusCode == 408 ||
          statusCode == 425 ||
          statusCode == 429 ||
          statusCode >= 500) {
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
    if (_ownsClient) _client.close();
  }
}

Uri _eventEndpoint(Uri baseUri, {required bool allowInsecureLocalhost}) {
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
  return baseUri.replace(path: normalizedPath).resolve('v1/events');
}
