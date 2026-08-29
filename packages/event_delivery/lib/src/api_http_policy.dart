import 'dart:convert';

import 'package:http/http.dart' as http;

import 'event_delivery_core.dart';

enum ActorRegistrationDisposition {
  accepted,
  retryableFailure,
  identityRecoveryRequired,
  rejected,
}

final class ActorRegistrationResult {
  const ActorRegistrationResult(this.disposition, {this.statusCode});

  final ActorRegistrationDisposition disposition;
  final int? statusCode;
}

/// Shared HTTP policy for Mosaic API clients.
///
/// Keeping URI validation, retry classification and anonymous actor
/// registration in one place prevents consumer/runtime clients from drifting
/// away from the event-delivery security contract.
final class ApiHttpPolicy {
  ApiHttpPolicy({
    required Uri baseUri,
    this.requestTimeout = const Duration(seconds: 10),
    bool allowInsecureLocalhost = false,
  }) : baseUri = validateApiBaseUri(
         baseUri,
         allowInsecureLocalhost: allowInsecureLocalhost,
       ) {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be positive',
      );
    }
  }

  final Uri baseUri;
  final Duration requestTimeout;

  Uri resolve(String relativePath) => baseUri.resolve(relativePath);

  Future<ActorRegistrationResult> registerActor({
    required http.Client client,
    required ActorAccessIdentity actorAccess,
  }) async {
    try {
      final response = await client
          .post(
            resolve('v1/actors'),
            headers: actorAuthorizationHeaders(
              actorAccess.accessToken,
              json: true,
            ),
            body: jsonEncode(<String, Object?>{
              'actorId': actorAccess.actorId,
            }),
          )
          .timeout(requestTimeout);
      final statusCode = response.statusCode;
      if (statusCode == 200 || statusCode == 201) {
        return ActorRegistrationResult(
          ActorRegistrationDisposition.accepted,
          statusCode: statusCode,
        );
      }
      if (statusCode == 401 || statusCode == 403 || statusCode == 409) {
        return ActorRegistrationResult(
          ActorRegistrationDisposition.identityRecoveryRequired,
          statusCode: statusCode,
        );
      }
      if (isRetryableHttpStatus(statusCode)) {
        return ActorRegistrationResult(
          ActorRegistrationDisposition.retryableFailure,
          statusCode: statusCode,
        );
      }
      return ActorRegistrationResult(
        ActorRegistrationDisposition.rejected,
        statusCode: statusCode,
      );
    } on Object {
      return const ActorRegistrationResult(
        ActorRegistrationDisposition.retryableFailure,
      );
    }
  }
}

bool isRetryableHttpStatus(int statusCode) =>
    statusCode == 408 ||
    statusCode == 425 ||
    statusCode == 429 ||
    statusCode >= 500;

Uri validateApiBaseUri(
  Uri baseUri, {
  required bool allowInsecureLocalhost,
}) {
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
