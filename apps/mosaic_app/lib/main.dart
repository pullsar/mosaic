import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:platform_flutter/platform_flutter.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

import 'app_event_runtime.dart';
import 'consumer_api_client.dart';
import 'consumer_onboarding.dart';
import 'consumer_runtime.dart';
import 'event_runtime_resources_factory.dart';
import 'onboarding_localizations.dart';

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
  late final AppEventRuntime _eventRuntime;
  late final ConsumerRuntime _consumerRuntime;
  late final Telemetry _demoPlayTelemetry;
  late final FlutterLifecycleBridge _lifecycle;
  late final PlayCanvasAssetResolver _canvasResolver;
  var _semanticResumeEpoch = 0;

  @override
  void initState() {
    super.initState();
    _eventRuntime = widget.eventRuntime ?? AppEventRuntime.disabled();
    _consumerRuntime = ConsumerRuntime(
      api: _createConsumerApi(_eventRuntime),
      localState: _eventRuntime.resources.consumerLocalState,
      capabilities: PlayCapabilityEnvelope.m1(),
      onError: _reportEventRuntimeError,
    );
    _demoPlayTelemetry = _eventRuntime.telemetryForPlay(
      feedRequestId: 'demo_feed_request',
      playRevisionId: _demoPlay.revisionId,
    );
    _eventRuntime.requestDrain();
    _canvasResolver = MapPlayCanvasAssetResolver({_demoCanvas.id: _demoCanvas});
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
    _lifecycle.dispose();
    _consumerRuntime.close();
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

  @override
  Widget build(BuildContext context) {
    final videoDiagnostics = PlayVideoDiagnosticObserver(
      telemetry: _demoPlayTelemetry,
      runtimeDiagnostics: const FlutterRuntimeDiagnostics(),
    );
    final media = PlayMediaLayerBuilder(
      ownerId: playMediaOwnerId(_demoPlay),
      visualResolver: MapPlayVisualAssetResolver(const {}),
      videoResolver: MapPlayVideoAssetResolver(const {}),
      audioResolver: MapPlayAudioAssetResolver(const {}),
      audioEngine: _audioEngine,
      canvasResolver: _canvasResolver,
      mediaCoordinator: _mediaCoordinator,
      videoControllerFactory: VideoPlayerPlayController.new,
      semanticResumeEpoch: _semanticResumeEpoch,
      onVideoPlaybackEvent: videoDiagnostics.call,
    );

    return MaterialApp(
      title: 'Mosaic',
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
        child: PlaySurface(play: _demoPlay, mediaBuilder: media.call),
      ),
    );
  }
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

final _demoCanvas = PlayCanvasAsset(
  id: 'demo_visual',
  semanticLabel: 'Warm walkable city scene',
  elements: [
    PlayCanvasRect(
      rect: const Rect.fromLTWH(0.04, 0.08, 0.92, 0.72),
      fill: true,
      tone: PlayCanvasTone.surface,
    ),
    PlayCanvasCircle(
      center: const Offset(0.79, 0.23),
      radius: 0.08,
      fill: true,
      tone: PlayCanvasTone.accent,
    ),
    PlayCanvasRect(
      rect: const Rect.fromLTWH(0.12, 0.44, 0.18, 0.24),
      fill: true,
      tone: PlayCanvasTone.muted,
    ),
    PlayCanvasRect(
      rect: const Rect.fromLTWH(0.34, 0.36, 0.19, 0.32),
      fill: true,
      tone: PlayCanvasTone.foreground,
    ),
    PlayCanvasRect(
      rect: const Rect.fromLTWH(0.57, 0.48, 0.15, 0.20),
      fill: true,
      tone: PlayCanvasTone.muted,
    ),
    PlayCanvasLine(
      start: const Offset(0.10, 0.73),
      end: const Offset(0.90, 0.73),
      width: 0.018,
      tone: PlayCanvasTone.accent,
    ),
  ],
);

final _demoPlay = PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'demo_where_is_this',
  'revisionId': 'rev_2',
  'format': 'guess',
  'classification': 'challenge',
  'topics': ['travel'],
  'learningTopics': ['geography'],
  'estimatedDurationSec': 12,
  'assets': ['demo_visual'],
  'sources': <Object>[],
  'entryState': 'guess',
  'states': {
    'guess': {
      'presentation': {
        'layers': [
          {'type': 'canvas', 'role': 'media', 'assetId': 'demo_visual'},
          {'type': 'text', 'role': 'prompt', 'value': 'Where is this?'},
        ],
      },
      'input': {
        'type': 'single_choice',
        'options': [
          {'id': 'lisbon', 'label': 'Lisbon'},
          {'id': 'marrakech', 'label': 'Marrakech'},
        ],
      },
      'validation': {'type': 'equals', 'value': 'lisbon'},
      'transition': {'correct': 'reveal', 'incorrect': 'reveal'},
    },
    'reveal': {
      'presentation': {
        'layers': [
          {'type': 'text', 'role': 'reveal_title', 'value': 'Lisbon'},
        ],
      },
      'input': {'type': 'tap', 'label': 'Done'},
      'validation': {'type': 'none'},
      'transition': {'default': r'$end'},
    },
  },
});
