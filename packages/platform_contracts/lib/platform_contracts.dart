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

enum AppRuntimeState { resumed, inactive, paused, hidden, detached }

enum MosaicPermission { camera, microphone, notifications }

enum MosaicPermissionState {
  granted,
  denied,
  restricted,
  permanentlyDenied,
  unsupported,
}

abstract interface class PermissionGateway {
  Future<MosaicPermissionState> check(MosaicPermission permission);
  Future<MosaicPermissionState> request(MosaicPermission permission);
}

enum PickedMediaKind { image, video }

final class PickedMedia {
  const PickedMedia({
    required this.path,
    required this.kind,
    this.name,
    this.mimeType,
  });

  final String path;
  final PickedMediaKind kind;
  final String? name;
  final String? mimeType;
}

abstract interface class MediaPickerGateway {
  Future<PickedMedia?> pickExistingImage();
  Future<PickedMedia?> pickExistingVideo();
  Future<List<PickedMedia>> recoverLostMedia();
}

/// A currently active native media resource owned by one visible Play.
abstract interface class ManagedMediaHandle {
  Future<void> pause();
  Future<void> release();
}

/// Enforces the feed invariant that only one Play owns active native media.
final class ActiveMediaCoordinator {
  String? _ownerId;
  ManagedMediaHandle? _active;

  String? get ownerId => _ownerId;
  bool get hasActiveMedia => _active != null;

  Future<void> activate(String ownerId, ManagedMediaHandle handle) async {
    if (identical(_active, handle) && _ownerId == ownerId) return;
    final previous = _active;
    if (previous != null) {
      await previous.pause();
      await previous.release();
    }
    _ownerId = ownerId;
    _active = handle;
  }

  Future<void> suspend() async {
    await _active?.pause();
  }

  Future<void> release(String ownerId) async {
    if (_ownerId != ownerId) return;
    final current = _active;
    _ownerId = null;
    _active = null;
    await current?.release();
  }

  Future<void> releaseAll() async {
    final current = _active;
    _ownerId = null;
    _active = null;
    if (current != null) {
      await current.pause();
      await current.release();
    }
  }
}

abstract final class MosaicSettingsRoute {
  static const privacy = '/settings/privacy';
  static const support = '/settings/support';
  static const deleteAccount = '/settings/account/delete';
}
