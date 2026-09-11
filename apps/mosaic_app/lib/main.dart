import 'dart:async';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'consumer_runtime.dart';
import 'consumer_search.dart';
import 'event_runtime_resources_factory.dart';
import 'game_attempt_controller.dart';
import 'game_sound_controller.dart';
import 'game_sound_preferences.dart';
import 'guest_engagement.dart';
import 'guest_home.dart';
import 'onboarding_localizations.dart';
import 'play_resolution_telemetry.dart';
import 'play_share.dart';
import 'saved_games.dart';

const _apiBaseUrl = String.fromEnvironment('MOSAIC_API_BASE_URL');
const _allowInsecureLocalApi = bool.fromEnvironment(
  'MOSAIC_ALLOW_INSECURE_LOCAL_API',
);
const _shareOriginValue = String.fromEnvironment(
  'MIXLI_SHARE_ORIGIN',
  defaultValue: 'https://mixli.app',
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
  const MosaicApp({
    this.eventRuntime,
    this.locale,
    this.shareGateway,
    this.shareOrigin,
    this.consumerApi,
    this.initialRoute,
    super.key,
  });

  final AppEventRuntime? eventRuntime;
  final Locale? locale;
  final ShareGateway? shareGateway;
  final Uri? shareOrigin;
  final ConsumerApiClient? consumerApi;
  final String? initialRoute;

  @override
  State<MosaicApp> createState() => _MosaicAppState();
}

final class _MosaicAppState extends State<MosaicApp> {
  final ActiveMediaCoordinator _mediaCoordinator = ActiveMediaCoordinator();
  final SoLoudAudioEngine _audioEngine = SoLoudAudioEngine();
  final ConsumerFeedController _feedController = ConsumerFeedController();
  late final AppEventRuntime _eventRuntime;
  late final ConsumerApiClient? _consumerApi;
  late final ShareGateway _shareGateway;
  late final Uri _shareOrigin;
  late final String _initialRoute;
  late final ConsumerActionController _actionController;
  late final AssetDeliveryClient? _assetDelivery;
  late final AssetMetadataWarmController? _metadataWarmer;
  late final ConsumerRuntime _consumerRuntime;
  late final GuestEngagementController _guestEngagement;
  late final GameSoundController? _gameSoundController;
  late final CachingPlayVisualAssetResolver _visualResolver;
  late final PlayVideoAssetResolver _videoResolver;
  late final PlayVideoPosterResolver? _videoPosterResolver;
  late final PlayAudioAssetResolver _audioResolver;
  late final PlayCanvasAssetResolver _canvasResolver;
  late final PlayVisualPrefetchController _visualPrefetch;
  late final FlutterLifecycleBridge _lifecycle;
  _ConsumerSearchScope? _searchScope;
  bool _directManipulationActive = false;
  String? _conversionPromptDeferredFor;
  var _semanticResumeEpoch = 0;

  @override
  void initState() {
    super.initState();
    _eventRuntime = widget.eventRuntime ?? AppEventRuntime.disabled();
    _shareGateway = widget.shareGateway ?? SharePlusGateway();
    _shareOrigin = widget.shareOrigin ?? Uri.parse(_shareOriginValue);
    _initialRoute =
        widget.initialRoute ??
        WidgetsBinding.instance.platformDispatcher.defaultRouteName;
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

    _consumerApi = widget.consumerApi ?? _createConsumerApi(_eventRuntime);
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
    final localState = _eventRuntime.resources.consumerLocalState;
    _guestEngagement = GuestEngagementController(
      store: localState is GuestEngagementStore
          ? localState as GuestEngagementStore
          : MemoryGuestEngagementStore(),
      onError: (error, stackTrace) => _reportEventRuntimeError(
        error,
        stackTrace,
        operation: 'guest_engagement_storage',
      ),
    );
    _gameSoundController = localState is GameSoundPreferencesStore
        ? GameSoundController(
            store: localState as GameSoundPreferencesStore,
            onError: (error, stackTrace) => _reportEventRuntimeError(
              error,
              stackTrace,
              operation: 'game_sound_preferences',
            ),
          )
        : null;
    _gameSoundController?.addListener(_onGameSoundChanged);
    unawaited(_gameSoundController?.initialize() ?? Future<void>.value());
    unawaited(_guestEngagement.initialize());
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

  void _onGameSoundChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _cancelWarmWindow();
    _lifecycle.dispose();
    _actionController.dispose();
    _guestEngagement.dispose();
    _gameSoundController?.removeListener(_onGameSoundChanged);
    _gameSoundController?.dispose();
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

  Widget _buildPlaySurface(
    BuildContext context, {
    required String playId,
    required String revisionId,
    required PlayDocument play,
    required Telemetry telemetry,
    required bool active,
    required ValueChanged<bool> onDirectManipulationChanged,
    VoidCallback? onMeaningfulInteraction,
  }) {
    return GameAttemptHost(
      key: ValueKey<String>('attempt:$playId:$revisionId'),
      play: play,
      builder: (context, attempt) {
        final videoDiagnostics = PlayVideoDiagnosticObserver(
          telemetry: telemetry,
          runtimeDiagnostics: const FlutterRuntimeDiagnostics(),
        );
        final media = PlayMediaLayerBuilder(
          ownerId: playMediaOwnerIdForAttempt(
            playId,
            revisionId,
            attempt.attemptId,
          ),
          visualResolver: _visualResolver,
          videoResolver: _videoResolver,
          videoPosterResolver: _videoPosterResolver,
          audioResolver: _audioResolver,
          audioEngine: _audioEngine,
          canvasResolver: _canvasResolver,
          mediaCoordinator: _mediaCoordinator,
          videoControllerFactory: VideoPlayerPlayController.new,
          active: active,
          soundEnabled: _gameSoundController?.preferences.masterMuted != true,
          semanticResumeEpoch: _semanticResumeEpoch,
          onVideoPlaybackEvent: videoDiagnostics.call,
        );
        return MixliAuthoredPlayDirection(
          child: PlaySurface.controlled(
            key: ValueKey<String>(
              'play:$playId:$revisionId:${attempt.attemptId}',
            ),
            session: attempt.session,
            onAction: attempt.captureActionHandler(
              onResolved: (resolution) {
                onMeaningfulInteraction?.call();
                recordPlayResolutionTelemetry(
                  telemetry,
                  playId: playId,
                  outcome: resolution.outcome,
                  attempts: resolution.session.attempts,
                  completed: resolution.session.ended,
                  correct: resolution.wasCorrect,
                  attemptId: attempt.attemptId,
                  attemptMode: attempt.mode.wireName,
                );
              },
            ),
            mediaBuilder: media.call,
            terminal: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 8),
                child: FilledButton.icon(
                  onPressed: attempt.replay,
                  icon: const Icon(Icons.replay_rounded),
                  label: const Text('Replay'),
                ),
              ),
            ),
            onDirectManipulationChanged: onDirectManipulationChanged,
          ),
        );
      },
    );
  }

  void _recordMeaningfulInteraction(String playId, String revisionId) {
    final identity = '$playId\u0000$revisionId';
    if (_conversionPromptDeferredFor != identity && mounted) {
      setState(() => _conversionPromptDeferredFor = identity);
    }
    unawaited(_guestEngagement.recordMeaningfulInteraction());
  }

  void _releaseConversionPromptBlock(String playId, String revisionId) {
    final deferredFor = _conversionPromptDeferredFor;
    if (deferredFor == null ||
        deferredFor == '$playId\u0000$revisionId' ||
        !mounted) {
      return;
    }
    setState(() => _conversionPromptDeferredFor = null);
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
    final surface = _buildPlaySurface(
      context,
      playId: item.playId,
      revisionId: item.revisionId,
      play: item.play,
      telemetry: telemetry,
      active: active,
      onDirectManipulationChanged: onDirectManipulationChanged,
      onMeaningfulInteraction: () =>
          _recordMeaningfulInteraction(item.playId, item.revisionId),
    );
    return ConsumerActionControls(
      child: surface,
      item: item,
      feedRequestId: feedRequestId,
      controller: _actionController,
      onAdvance: _feedController.advance,
      onShare: _sharePlay,
      soundController: _gameSoundController,
      active: active,
    );
  }

  Future<void> _sharePlay(
    ConsumerFeedItem item,
    BuildContext actionContext,
  ) async {
    final link = PlayShareLink.build(
      origin: _shareOrigin,
      playId: item.playId,
      revisionId: item.revisionId,
    );
    ShareDisposition disposition;
    try {
      disposition = await _shareGateway.share(link);
    } on Object catch (error, stackTrace) {
      _reportEventRuntimeError(error, stackTrace, operation: 'play_share');
      disposition = ShareDisposition.unavailable;
    }
    if (!mounted) return;
    if (disposition == ShareDisposition.dismissed) return;
    if (disposition == ShareDisposition.unavailable) {
      try {
        await Clipboard.setData(ClipboardData(text: link.toString()));
      } on Object catch (error, stackTrace) {
        _reportEventRuntimeError(
          error,
          stackTrace,
          operation: 'play_share_copy',
        );
        return;
      }
      if (!mounted) return;
      _showShareFeedback(actionContext, 'Link copied');
      return;
    }
    _showShareFeedback(actionContext, 'Shared');
  }

  void _showShareFeedback(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openSearch(BuildContext context) async {
    final selection = await Navigator.of(context).push<ConsumerSearchSelection>(
      MaterialPageRoute<ConsumerSearchSelection>(
        fullscreenDialog: true,
        builder: (_) => ConsumerDiscoverySearch(
          runtime: _consumerRuntime,
          telemetry: _eventRuntime.telemetry,
        ),
      ),
    );
    if (!mounted || selection == null) return;
    switch (selection) {
      case ConsumerTopicSearchSelection():
        setState(() {
          _searchScope = _ConsumerSearchScope(
            intent: ConsumerFeedSearchIntent(
              intent: selection.intent,
              topicId: selection.topicId,
            ),
            label: selection.label,
          );
        });
      case ConsumerPlaySearchSelection():
        await _openPlay(
          context,
          playId: selection.result.playId,
          revisionId: selection.result.revisionId,
          play: selection.result.play,
        );
    }
  }

  Future<void> _openPlay(
    BuildContext context, {
    required String playId,
    required String revisionId,
    required PlayDocument play,
  }) {
    final telemetry = _eventRuntime.telemetryForStandalonePlay(
      playRevisionId: revisionId,
    );
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => Scaffold(
          backgroundColor: Theme.of(routeContext).scaffoldBackgroundColor,
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _buildPlaySurface(
                routeContext,
                playId: playId,
                revisionId: revisionId,
                play: play,
                telemetry: telemetry,
                active: true,
                onDirectManipulationChanged: (_) {},
              ),
              SafeArea(
                minimum: const EdgeInsets.all(12),
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  child: IconButton.filledTonal(
                    tooltip: MaterialLocalizations.of(
                      routeContext,
                    ).backButtonTooltip,
                    onPressed: () => Navigator.of(routeContext).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<List<SavedGameEntry>> _loadSavedGames() async {
    final recovered = await _consumerRuntime.recoverRecentFeed();
    if (recovered == null) return const <SavedGameEntry>[];
    final entries = <SavedGameEntry>[];
    for (final item in recovered.items) {
      final state = await _actionController.load(
        playId: item.playId,
        revisionId: item.revisionId,
      );
      if (state.saved && state.savedRevisionId == item.revisionId) {
        entries.add(SavedGameEntry(item: item, updatedAt: state.updatedAt));
      }
    }
    entries.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return List<SavedGameEntry>.unmodifiable(entries);
  }

  Future<void> _openSaved(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (routeContext) => SavedGamesPage(
        loadEntries: _loadSavedGames,
        onUnsave: (entry) => _actionController.toggleSave(
          playId: entry.item.playId,
          revisionId: entry.item.revisionId,
          feedRequestId: 'saved:${entry.item.revisionId}',
        ),
        onOpen: (item) => _openPlay(
          routeContext,
          playId: item.playId,
          revisionId: item.revisionId,
          play: item.play,
        ),
      ),
    ),
  );

  void _recordFeedEvent(
    String event, {
    required String feedRequestId,
    required String playRevisionId,
    required Map<String, Object?> payload,
  }) {
    if (event == MosaicEventName.playVisible) {
      final playId = payload['playId'];
      if (playId is String && playId.trim().isNotEmpty) {
        _releaseConversionPromptBlock(playId, playRevisionId);
        unawaited(
          _guestEngagement.recordVisible(
            playId: playId,
            revisionId: playRevisionId,
          ),
        );
      }
    }
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

  Future<ConsumerApiResult<ConsumerPublicPlay>> _loadSharedPlay(
    PlayShareTarget target,
  ) {
    final api = _consumerApi;
    if (api == null) {
      return Future<ConsumerApiResult<ConsumerPublicPlay>>.value(
        const ConsumerApiFailure(ConsumerApiFailureKind.rejected),
      );
    }
    return api.fetchPublicPlay(
      playId: target.playId,
      revisionId: target.revisionId,
      capabilities: consumerCapabilitiesForAssetDelivery(_assetDelivery),
    );
  }

  Route<dynamic>? _sharedPlayRoute(RouteSettings settings) {
    final target = PlayShareLink.parsePath(settings.name ?? '');
    if (target == null) return null;
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (routeContext) => _SharedPlayPage(
        load: () => _loadSharedPlay(target),
        onClose: () => _replaceWithHome(routeContext),
        surfaceBuilder: (context, shared) => _buildPlaySurface(
          context,
          playId: shared.playId,
          revisionId: shared.revisionId,
          play: shared.play,
          telemetry: _eventRuntime.telemetryForStandalonePlay(
            playRevisionId: shared.revisionId,
          ),
          active: true,
          onDirectManipulationChanged: (_) {},
        ),
      ),
    );
  }

  List<Route<dynamic>> _initialRoutes(String initialRoute) {
    final shared = _sharedPlayRoute(RouteSettings(name: initialRoute));
    if (shared != null) return <Route<dynamic>>[shared];
    return <Route<dynamic>>[
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/'),
        builder: (_) => _buildHome(),
      ),
    ];
  }

  void _replaceWithHome(BuildContext context) {
    unawaited(
      Navigator.of(context).pushAndRemoveUntil<void>(
        MaterialPageRoute<void>(builder: (_) => _buildHome()),
        (route) => false,
      ),
    );
  }

  Widget _buildHome() {
    final scope = _searchScope;
    final conversionPromptBlocked = _conversionPromptDeferredFor != null;
    final feedKey = scope == null
        ? 'consumer-feed:default'
        : 'consumer-feed:${scope.intent.intent.wireName}:${scope.intent.topicId}';
    return Builder(
      builder: (homeContext) => GuestHome(
        engagement: _guestEngagement,
        directManipulationActive:
            _directManipulationActive || conversionPromptBlocked,
        onSearch: () => unawaited(_openSearch(homeContext)),
        onSaved: () => unawaited(_openSaved(homeContext)),
        activeSearchLabel: scope?.label,
        onClearSearch: scope == null
            ? null
            : () => setState(() => _searchScope = null),
        child: ConsumerFeed(
          key: ValueKey<String>(feedKey),
          runtime: _consumerRuntime,
          itemBuilder: _buildFeedPlay,
          controller: _feedController,
          searchIntent: scope?.intent,
          persistRecovery: scope == null,
          onEvent: _recordFeedEvent,
          onWarmWindow: _warmFeedWindow,
          onCancelWarmWindow: _cancelWarmWindow,
          onDirectManipulationChanged: (active) {
            if (_directManipulationActive == active) return;
            setState(() => _directManipulationActive = active);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mixli',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      locale: widget.locale,
      supportedLocales: MosaicOnboardingStrings.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        MosaicOnboardingStrings.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      darkTheme: mixliTheme(Brightness.dark),
      theme: mixliTheme(Brightness.light),
      initialRoute: _initialRoute,
      onGenerateInitialRoutes: _initialRoutes,
      onGenerateRoute: _sharedPlayRoute,
      routes: {
        MosaicSettingsRoute.privacy: (_) =>
            const _ReservedSettingsPage('Privacy'),
        MosaicSettingsRoute.support: (_) =>
            const _ReservedSettingsPage('Support'),
        MosaicSettingsRoute.deleteAccount: (_) =>
            const _ReservedSettingsPage('Delete account'),
      },
    );
  }
}

typedef _SharedPlaySurfaceBuilder =
    Widget Function(BuildContext context, ConsumerPublicPlay shared);

final class _SharedPlayPage extends StatefulWidget {
  const _SharedPlayPage({
    required this.load,
    required this.surfaceBuilder,
    required this.onClose,
  });

  final Future<ConsumerApiResult<ConsumerPublicPlay>> Function() load;
  final _SharedPlaySurfaceBuilder surfaceBuilder;
  final VoidCallback onClose;

  @override
  State<_SharedPlayPage> createState() => _SharedPlayPageState();
}

final class _SharedPlayPageState extends State<_SharedPlayPage> {
  late final Future<ConsumerApiResult<ConsumerPublicPlay>> _shared = widget
      .load();

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const ValueKey<String>('shared-play'),
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    body: FutureBuilder<ConsumerApiResult<ConsumerPublicPlay>>(
      future: _shared,
      builder: (context, snapshot) {
        final result = snapshot.data;
        if (result is ConsumerApiSuccess<ConsumerPublicPlay>) {
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              widget.surfaceBuilder(context, result.value),
              SafeArea(
                minimum: const EdgeInsets.all(12),
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  child: IconButton.filledTonal(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ),
            ],
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: Semantics(
              label: 'Loading',
              child: const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return Center(
          child: FilledButton(
            onPressed: widget.onClose,
            child: const Text('Play'),
          ),
        );
      },
    ),
  );
}

/// Keeps today's English-authored Plays independent from surrounding app chrome.
///
/// Published Play documents do not yet carry an authored locale or direction.
/// Replace this fixed policy with schema-owned direction when that contract lands.
final class MixliAuthoredPlayDirection extends StatelessWidget {
  const MixliAuthoredPlayDirection({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Directionality(textDirection: TextDirection.ltr, child: child);
}

ThemeData mixliTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = ThemeData(
    brightness: brightness,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: dark
        ? MosaicVisualTokens.surface
        : const Color(0xFFFAFAF8),
    colorScheme: dark
        ? const ColorScheme.dark(
            primary: MosaicVisualTokens.foreground,
            onPrimary: MosaicVisualTokens.surface,
            surface: MosaicVisualTokens.surface,
            onSurface: MosaicVisualTokens.foreground,
          )
        : const ColorScheme.light(
            primary: Color(0xFF171717),
            onPrimary: Color(0xFFFFFFFF),
            surface: Color(0xFFFAFAF8),
            onSurface: Color(0xFF171717),
          ),
  );
  final text = base.textTheme;
  return base.copyWith(
    textTheme: text.copyWith(
      displayLarge: text.displayLarge?.copyWith(fontWeight: FontWeight.w600),
      displayMedium: text.displayMedium?.copyWith(fontWeight: FontWeight.w600),
      displaySmall: text.displaySmall?.copyWith(fontWeight: FontWeight.w600),
      headlineLarge: text.headlineLarge?.copyWith(fontWeight: FontWeight.w600),
      headlineMedium: text.headlineMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w500),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w500),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w500),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
      labelMedium: text.labelMedium?.copyWith(fontWeight: FontWeight.w500),
      labelSmall: text.labelSmall?.copyWith(fontWeight: FontWeight.w500),
      bodyLarge: text.bodyLarge?.copyWith(fontWeight: FontWeight.w400),
      bodyMedium: text.bodyMedium?.copyWith(fontWeight: FontWeight.w400),
      bodySmall: text.bodySmall?.copyWith(fontWeight: FontWeight.w400),
    ),
  );
}

final class _ConsumerSearchScope {
  const _ConsumerSearchScope({required this.intent, required this.label});

  final ConsumerFeedSearchIntent intent;
  final String label;
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
