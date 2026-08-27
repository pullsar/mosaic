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

/// User-initiated contexts that are allowed to request a platform permission.
enum PermissionUseCase { cameraCapture, microphoneRecording, notificationOptIn }

MosaicPermission permissionForUseCase(PermissionUseCase useCase) =>
    switch (useCase) {
      PermissionUseCase.cameraCapture => MosaicPermission.camera,
      PermissionUseCase.microphoneRecording => MosaicPermission.microphone,
      PermissionUseCase.notificationOptIn => MosaicPermission.notifications,
    };

/// Keeps permission requests contextual and deliberately exposes no eager
/// request-all/startup API. Call [requestFromUserAction] only from the
/// corresponding user gesture.
final class ContextualPermissionService {
  const ContextualPermissionService(this._gateway);

  final PermissionGateway _gateway;

  Future<MosaicPermissionState> check(PermissionUseCase useCase) =>
      _gateway.check(permissionForUseCase(useCase));

  Future<MosaicPermissionState> requestFromUserAction(
    PermissionUseCase useCase,
  ) => _gateway.request(permissionForUseCase(useCase));
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
///
/// [pause] and [release] must be safe to call more than once so lifecycle
/// recovery can retry after a platform failure.
abstract interface class ManagedMediaHandle {
  Future<void> pause();
  Future<void> release();
}

final class _SerializedOperations {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

/// Enforces the feed invariant that only one Play owns active native media.
///
/// All transitions are serialized. Rapid viewport/lifecycle changes cannot
/// observe the same previous handle and accidentally leave a newer handle
/// outside coordinator ownership.
final class ActiveMediaCoordinator {
  final _operations = _SerializedOperations();
  String? _ownerId;
  ManagedMediaHandle? _active;

  String? get ownerId => _ownerId;
  bool get hasActiveMedia => _active != null;

  Future<void> activate(String ownerId, ManagedMediaHandle handle) =>
      _operations.run(() async {
        if (identical(_active, handle)) {
          _ownerId = ownerId;
          return;
        }

        final previous = _active;
        if (previous != null) {
          await previous.pause();
          await previous.release();
        }
        _ownerId = ownerId;
        _active = handle;
      });

  Future<void> suspend() => _operations.run(() async {
    await _active?.pause();
  });

  Future<void> release(String ownerId) => _operations.run(() async {
    if (_ownerId != ownerId) return;
    final current = _active;
    if (current != null) {
      await current.pause();
      await current.release();
    }
    _ownerId = null;
    _active = null;
  });

  Future<void> releaseAll() => _operations.run(() async {
    final current = _active;
    if (current != null) {
      await current.pause();
      await current.release();
    }
    _ownerId = null;
    _active = null;
  });
}

abstract final class MosaicSettingsRoute {
  static const privacy = '/settings/privacy';
  static const support = '/settings/support';
  static const deleteAccount = '/settings/account/delete';
}
