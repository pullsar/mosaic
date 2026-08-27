import 'dart:async';

abstract interface class AudioEngine {
  Future<void> load(String assetId, Uri uri);
  Future<void> play(String assetId);
  Future<void> schedule(String assetId, Duration offset);
  Future<void> stop(String assetId);
  Future<void> release(String assetId);
  Map<String, num> get latencyMetrics;
}

abstract interface class FeatureFlags {
  bool isEnabled(String key, {bool fallback = false});
  Object? value(String key);
}

abstract interface class ShareGateway {
  Future<void> share(Uri canonicalPlayUri, {String? message});
}

abstract interface class UploadSession {
  String get id;
  double get progress;
  Future<void> resume();
  Future<void> pause();
  Future<void> cancel();
  Future<Uri> complete();
}

abstract interface class ActorIdentityStore {
  Future<String> getOrCreateActorId();
  Future<void> bindActorToUser(String actorId, String userId);
}

abstract interface class Telemetry {
  void event(String name, Map<String, Object?> payload);
  void error(Object error, StackTrace stackTrace, {String? operation});
  FutureOr<T> trace<T>(String operation, FutureOr<T> Function() body);
}
