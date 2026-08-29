import 'dart:async';

import 'package:event_delivery/event_delivery.dart';
import 'package:platform_contracts/platform_contracts.dart';

import 'event_runtime_resources.dart';

typedef AppEventRuntimeErrorReporter =
    void Function(Object error, StackTrace stackTrace, {String? operation});

final class AppEventRuntime {
  AppEventRuntime._({
    required this.resources,
    required this.telemetry,
    required this.sessionId,
    required EventDrainController? drainController,
    required EventTransport? transport,
    required AppEventRuntimeErrorReporter? onError,
  }) : _drainController = drainController,
       _transport = transport,
       _onError = onError;

  factory AppEventRuntime.create({
    required AppEventResources resources,
    String apiBaseUrl = '',
    bool allowInsecureLocalhost = false,
    AppEventRuntimeErrorReporter? onError,
  }) {
    final sessionId = secureUuidV4();
    EventTransport? transport;
    EventDrainController? drainController;

    final configuredApi = apiBaseUrl.trim();
    if (configuredApi.isNotEmpty) {
      try {
        transport = HttpEventTransport(
          baseUri: Uri.parse(configuredApi),
          actorAccess: resources.actorAccess,
          allowInsecureLocalhost: allowInsecureLocalhost,
        );
        drainController = EventDrainController(
          outbox: resources.outbox,
          transport: transport,
        );
      } on Object catch (error, stackTrace) {
        onError?.call(error, stackTrace, operation: 'event_transport_config');
      }
    }

    final controller = drainController;
    final onQueued = controller == null
        ? null
        : () => _drainSafely(controller, onError);
    final telemetry = MosaicEventTelemetry(
      outbox: resources.outbox,
      contextProvider: () =>
          EventContext(actorId: resources.actorId, sessionId: sessionId),
      onQueued: onQueued,
      onInternalError: onError,
    );

    return AppEventRuntime._(
      resources: resources,
      telemetry: telemetry,
      sessionId: sessionId,
      drainController: drainController,
      transport: transport,
      onError: onError,
    );
  }

  factory AppEventRuntime.disabled() =>
      AppEventRuntime.create(resources: AppEventResources.disabled());

  final AppEventResources resources;
  final Telemetry telemetry;
  final String sessionId;
  final EventDrainController? _drainController;
  final EventTransport? _transport;
  final AppEventRuntimeErrorReporter? _onError;
  var _closed = false;

  bool get deliveryConfigured => _drainController != null;

  Telemetry telemetryForPlay({
    required String feedRequestId,
    required String playRevisionId,
  }) {
    if (_closed) {
      throw StateError('App event runtime is closed.');
    }
    final controller = _drainController;
    return MosaicEventTelemetry(
      outbox: resources.outbox,
      contextProvider: () => EventContext(
        actorId: resources.actorId,
        sessionId: sessionId,
        feedRequestId: feedRequestId,
        playRevisionId: playRevisionId,
      ),
      onQueued: controller == null
          ? null
          : () => _drainSafely(controller, _onError),
      onInternalError: _onError,
    );
  }

  void requestDrain() {
    if (_closed) return;
    final controller = _drainController;
    if (controller == null) return;
    unawaited(_drainSafely(controller, _onError));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport?.close();
    await resources.close();
  }
}

Future<void> _drainSafely(
  EventDrainController controller,
  AppEventRuntimeErrorReporter? onError,
) async {
  try {
    await controller.drain();
  } on Object catch (error, stackTrace) {
    onError?.call(error, stackTrace, operation: 'event_drain');
  }
}
