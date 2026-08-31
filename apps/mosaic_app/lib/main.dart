import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:platform_flutter/platform_flutter.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

import 'app_event_runtime.dart';
import 'asset_delivery_client.dart';
import 'asset_delivery_warm.dart';
import 'consumer_action_controller.dart';
import 'consumer_action_controls.dart';
import 'consumer_api_client.dart';
import 'consumer_feed.dart';
import 'consumer_onboarding.dart';
import 'consumer_runtime.dart';
import 'event_runtime_resources_factory.dart';
import 'onboarding_localizations.dart';
import 'play_resolution_telemetry.dart';

const _apiBaseUrl = String.fromEnvironment('MOSAIC_API_BASE_URL');
const _allowInsecureLocalApi = bool.fromEnvironment(
  'MOSAIC_ALLOW_INSECURE_LOCAL_API',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final resources = await openAppEventResources(
    onError: (error, stackTrace) => _reportEventRuntimeError(
      error,
      stackTrace,
      operation: 'event_storage_open',
    ),
  );
  final eventRuntime = AppEventRuntime.create(
    resources: resources,
    apiBaseUrl: _apiBaseUrl,
    allowInsecureLocalhost: _allowInsecureLocalApi,
    onError: _reportEventRuntimeError,
  );
  eventRuntime.requestDrain();
  runApp(ProviderScope(child: MosaicApp(eventRuntime: eventRuntime)));
}

final class MosaicApp extends StatefulWidget {
  const MosaicApp({this.eventRuntime, super.key});

  final AppEventRuntime? eventRuntime;

  @override
  State<MosaicApp> createState() => _MosaicAppState();
}

final class _MosaicAppState extends State<MosaicApp> {
  final ActiveMediaCoordinator _mediaCoordinator = ActiveMediaCoordinator();
  final SoLoudAudioEngine _audioEngine = SoLoudAudioEngine();
  final ConsumerFeedController _feedController = ConsumerFeedController();
  late final AppEventRuntime _eventRuntime;
  late final ConsumerApiClient? _consumerApi;
  late final ConsumerActionController _actionController;
  late final AssetDeliveryClient? _assetDelivery;
  late final AssetMetadataWarmController? _metadataWarmer;
  late final ConsumerRuntime _consumerRuntime;
  late final CachingPlayVisualAssetResolver _visualResolver;
  late final PlayVideoAssetResolver _videoResolver;
  late final PlayVideoPosterResolver? _videoPosterResolver;
  late final PlayAudioAssetResolver _audioResolver;
  late final PlayCanvasAssetResolver _canvasResolver;
  late final PlayVisualPrefetchController _visualPrefetch;
  late final FlutterLifecycleBridge _lifecycle;
  var _semanticResumeEpoch = 0;

  @override
  void initState() {
    super.initState();
    _eventRuntime = widget.eventRuntime ?? AppEventRuntime.disabled();
    _assetDelivery = _createAssetDeliveryClient();
    final binaryDelivery = _assetDelivery?.supportsBinaryNetworkAssets ?? false;
    final assetDelivery = _assetDelivery;

    _visualResolver = CachingPlayVisualAssetResolver(
      binaryDelivery && assetDelivery != null
          ? ManagedVisualAssetResolver(assetDelivery)
          : MapPlayVisualAssetResolver(const {}),
      capacity: 24,
    );
    _videoResolver = binaryDelivery && assetDelivery != null
        ? ManagedVideoAssetResolver(assetDelivery)
        : MapPlayVideoAssetResolver(const {});
    _videoPosterResolver = binaryDelivery && assetDelivery != null
        ? ManagedVideoPosterResolver(assetDelivery)
        : null;
    _audioResolver = binaryDelivery && assetDelivery != null
        ? ManagedAudioAssetResolver(assetDelivery)
        : MapPlayAudioAssetResolver(const {});
    _canvasResolver = assetDelivery == null
        ? MapPlayCanvasAssetResolver(const {})
        : ManagedCanvasAssetResolver(assetDelivery);
    _metadataWarmer = assetDelivery == null
        ? null
        : AssetMetadataWarmController(
            client: assetDelivery,
            onError: (assetId, error, stackTrace) => _reportEventRuntimeError(
              error,
              stackTrace,
              operation: 'feed_asset_warm:$assetId',
            ),
          );

    _consumerApi = _createConsumerApi(_eventRuntime);
    _actionController = ConsumerActionController(
      eventRuntime: _eventRuntime,
      localState: _eventRuntime.resources.consumerLocalState,
      api: _consumerApi,
      onError: _reportEventRuntimeError,
    );
    _consumerRuntime = ConsumerRuntime(
      api: _consumerApi,
      localState: _eventRuntime.resources.consumerLocalState,
      capabilities: consumerCapabilitiesForAssetDelivery(_assetDelivery),
      onError: _reportEventRuntimeError,
    );
    _visualPrefetch = PlayVisualPrefetchController(
      resolver: _visualResolver,
      maxAssets: 4,
      maxConcurrent: 2,
      onError: (assetId, error, stackTrace) => _reportEventRuntimeError(
        error,
        stackTrace,
        operation: 'feed_visual_prefetch:$assetId',
      ),
    );
    _eventRuntime.requestDrain();
    _lifecycle = FlutterLifecycleBridge(
      mediaCoordinator: _mediaCoordinator,
      onSemanticResume: _resumeSemanticMedia,
      onError: _reportPlatformError,
    );
  }

  void _resumeSemanticMedia() {
    _eventRuntime.requestDrain();
    if (!mounted) return;
    setState(() => _semanticResumeEpoch += 1);
  }

  @override
  void dispose() {
    _cancelWarmWindow();
    _lifecycle.dispose();
    _actionController.dispose();
    _consumerRuntime.close();
    _assetDelivery?.close();
    unawaited(_disposeResources());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    try {
      await _mediaCoordinator.releaseAll();
    } catch (error, stackTrace) {
      _reportPlatformError(error, stackTrace);
    }

    try {
      await _audioEngine.dispose();
    } catch (error, stackTrace) {
      _reportPlatformError(error, stackTrace);
    }

    try {
      await _eventRuntime.close();
    } catch (error, stackTrace) {
      _reportEventRuntimeError(
        error,
        stackTrace,
        operation: 'event_runtime_close',
      );
    }
  }

  void _reportPlatformError(Object error, StackTrace stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'mosaic_app',
        context: ErrorDescription('while releasing platform media'),
      ),
    );
  }

  Widget _buildFeedPlay(
    BuildContext context,
    ConsumerFeedItem item, {
    required String feedRequestId,
    required bool active,
    required ValueChanged<bool> onDirectManipulationChanged,
  }) {
    final telemetry = _eventRuntime.telemetryForPlay(
      feedRequestId: feedRequestId,
      playRevisionId: item.revisionId,
    );
    final videoDiagnostics = PlayVideoDiagnosticObserver(
      telemetry: telemetry,
      runtimeDiagnostics: const FlutterRuntimeDiagnostics(),
    );
    final media = PlayMediaLayerBuilder(
      ownerId: playMediaOwnerId(item.play),
      visualResolver: _visualResolver,
      videoResolver: _videoResolver,
      videoPosterResolver: _videoPosterResolver,
      audioResolver: _audioResolver,
      audioEngine: _audioEngine,
      canvasResolver: _canvasResolver,
      mediaCoordinator: _mediaCoordinator,
      videoControllerFactory: VideoPlayerPlayController.new,
      active: active,
      semanticResumeEpoch: _semanticResumeEpoch,
      onVideoPlaybackEvent: videoDiagnostics.call,
    );
    final surface = PlaySurface(
      key: ValueKey<String>('play:${item.playId}:${item.revisionId}'),
      play: item.play,
      mediaBuilder: media.call,
      onResolved: (resolution) => recordPlayResolutionTelemetry(
        telemetry,
        playId: item.playId,
        outcome: resolution.outcome,
        attempts: resolution.session.attempts,
        completed: resolution.session.ended,
        correct: resolution.wasCorrect,
      ),
      onDirectManipulationChanged: onDirectManipulationChanged,
    );
    return ConsumerActionControls(
      child: surface,
      item: item,
      feedRequestId: feedRequestId,
      controller: _actionController,
      onAdvance: _feedController.advance,
      active: active,
    );
  }

  void _recordFeedEvent(
    String event, {
    required String feedRequestId,
    required String playRevisionId,
    required Map<String, Object?> payload,
  }) {
    _eventRuntime
        .telemetryForPlay(
          feedRequestId: feedRequestId,
          playRevisionId: playRevisionId,
        )
        .event(event, payload);
  }

  Future<void> _warmFeedWindow(
    BuildContext context,
    List<ConsumerFeedItem> items,
  ) async {
    final plan = buildAssetWarmPlan(items.map((item) => item.play));
    final metadataWarm = _metadataWarmer?.warm(plan) ?? Future<void>.value();
    await Future.wait<void>([
      _visualPrefetch.prefetch(context, plan.visualAssetIds).then((_) {}),
      metadataWarm,
    ]);
  }

  void _cancelWarmWindow() {
    _metadataWarmer?.cancel();
    _visualPrefetch.cancel();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Mixli',
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.system,
    supportedLocales: MosaicOnboardingStrings.supportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<Object>>[
      MosaicOnboardingStrings.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    darkTheme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: MosaicVisualTokens.surface,
      colorScheme: const ColorScheme.dark(
        primary: MosaicVisualTokens.foreground,
        onPrimary: MosaicVisualTokens.surface,
        surface: MosaicVisualTokens.surface,
        onSurface: MosaicVisualTokens.foreground,
      ),
    ),
    theme: ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFFAFAF8),
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF171717),
        onPrimary: Color(0xFFFFFFFF),
        surface: Color(0xFFFAFAF8),
        onSurface: Color(0xFF171717),
      ),
    ),
    routes: {
      MosaicSettingsRoute.privacy: (_) =>
          const _ReservedSettingsPage('Privacy'),
      MosaicSettingsRoute.support: (_) =>
          const _ReservedSettingsPage('Support'),
      MosaicSettingsRoute.deleteAccount: (_) =>
          const _ReservedSettingsPage('Delete account'),
    },
    home: ConsumerOnboardingGate(
      runtime: _consumerRuntime,
      child: ConsumerFeed(
        runtime: _consumerRuntime,
        itemBuilder: _buildFeedPlay,
        controller: _feedController,
        onEvent: _recordFeedEvent,
        onWarmWindow: _warmFeedWindow,
        onCancelWarmWindow: _cancelWarmWindow,
      ),
    ),
  );
}

PlayCapabilityEnvelope consumerCapabilitiesForAssetDelivery(
  AssetDeliveryClient? assetDelivery,
) {
  final presentationTypes = <String>{'text'};
  if (assetDelivery != null) {
    presentationTypes.add('canvas');
    if (assetDelivery.supportsBinaryNetworkAssets) {
      presentationTypes.addAll(const {'image', 'video_clip', 'audio'});
    }
  }
  return PlayCapabilityEnvelope(
    schemaVersions: const {1},
    presentationTypes: Set.unmodifiable(presentationTypes),
    inputTypes: const {'tap', 'single_choice', 'piano_key', 'drag'},
    validatorTypes: const {
      'none',
      'equals',
      'ordered_sequence',
      'target_region',
    },
  );
}

ConsumerApiClient? _createConsumerApi(AppEventRuntime eventRuntime) {
  final configuredApi = _apiBaseUrl.trim();
  if (configuredApi.isEmpty) return null;
  try {
    return ConsumerApiClient(
      baseUri: Uri.parse(configuredApi),
      actorAccess: eventRuntime.resources.actorAccess,
      allowInsecureLocalhost: _allowInsecureLocalApi,
    );
  } on Object catch (error, stackTrace) {
    _reportEventRuntimeError(
      error,
      stackTrace,
      operation: 'consumer_transport_config',
    );
    return null;
  }
}

AssetDeliveryClient? _createAssetDeliveryClient() {
  final configuredApi = _apiBaseUrl.trim();
  if (configuredApi.isEmpty) return null;
  try {
    return AssetDeliveryClient(
      baseUri: Uri.parse(configuredApi),
      allowInsecureLocalhost: _allowInsecureLocalApi,
    );
  } on Object catch (error, stackTrace) {
    _reportEventRuntimeError(
      error,
      stackTrace,
      operation: 'asset_delivery_config',
    );
    return null;
  }
}

void _reportEventRuntimeError(
  Object error,
  StackTrace stackTrace, {
  String? operation,
}) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'mosaic_app.events',
      context: ErrorDescription(
        operation ?? 'while processing event telemetry',
      ),
    ),
  );
}

final class _ReservedSettingsPage extends StatelessWidget {
  const _ReservedSettingsPage(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: Text(label))),
  );
}
