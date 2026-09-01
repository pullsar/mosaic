import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/app_event_runtime.dart';
import 'package:mosaic_app/consumer_action_controller.dart';
import 'package:mosaic_app/consumer_action_controls.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_feed.dart';
import 'package:mosaic_app/guest_engagement.dart';
import 'package:mosaic_app/guest_home.dart';
import 'package:mosaic_app/main.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

const _goldenBoundary = ValueKey<String>('guest-composition-golden');
final _fixedNow = DateTime.utc(2026, 9, 1, 12);

typedef _Fixture = ({Map<String, Object?> json, PlayDocument play});

final class _GoldenAudioEngine implements AudioEngine {
  @override
  Map<String, num> get latencyMetrics => const <String, num>{};

  @override
  Future<void> load(String assetId, Uri uri) async {}

  @override
  Future<void> play(String assetId) async {}

  @override
  Future<void> release(String assetId) async {}

  @override
  Future<void> schedule(String assetId, Duration offset) async {}

  @override
  Future<void> stop(String assetId) async {}
}

final class _PendingCanvasResolver implements PlayCanvasAssetResolver {
  final Completer<PlayCanvasAsset?> _pending = Completer<PlayCanvasAsset?>();

  @override
  Future<PlayCanvasAsset?> resolve(String assetId) => _pending.future;

  void release() {
    if (!_pending.isCompleted) _pending.complete(null);
  }
}

final class _GoldenHarness {
  _GoldenHarness({
    required PlayDocument play,
    required PlayCanvasAssetResolver canvasResolver,
  }) {
    runtime = AppEventRuntime.disabled();
    actions = ConsumerActionController(
      eventRuntime: runtime,
      localState: runtime.resources.consumerLocalState,
      clock: () => _fixedNow,
      eventIdFactory: () => 'golden_event_${_eventId++}',
    );
    engagement = GuestEngagementController(
      store: MemoryGuestEngagementStore(),
      clock: () => _fixedNow,
    );
    media = PlayMediaLayerBuilder(
      ownerId: playMediaOwnerId(play),
      visualResolver: MapPlayVisualAssetResolver(const {}),
      videoResolver: MapPlayVideoAssetResolver(const {}),
      audioResolver: MapPlayAudioAssetResolver(const {}),
      audioEngine: _GoldenAudioEngine(),
      canvasResolver: canvasResolver,
      mediaCoordinator: mediaCoordinator,
      videoControllerFactory: (_) => throw StateError(
        'Composition goldens must not initialize video plugins.',
      ),
    );
  }

  final ActiveMediaCoordinator mediaCoordinator = ActiveMediaCoordinator();
  late final AppEventRuntime runtime;
  late final ConsumerActionController actions;
  late final GuestEngagementController engagement;
  late final PlayMediaLayerBuilder media;
  var _eventId = 0;

  Future<void> close() async {
    actions.dispose();
    engagement.dispose();
    await mediaCoordinator.releaseAll();
    await runtime.close();
  }
}

final class _ScenarioHandle {
  _ScenarioHandle({required this.harness, required this.pendingCanvas});

  final _GoldenHarness harness;
  final _PendingCanvasResolver? pendingCanvas;
  bool _closed = false;

  Future<void> close(WidgetTester tester) async {
    if (_closed) return;
    _closed = true;
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      pendingCanvas?.release();
      try {
        await harness.close();
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    }
  }
}

final class _Scenario {
  const _Scenario({
    required this.name,
    required this.golden,
    required this.size,
    required this.safeInsets,
    required this.playFixture,
    required this.canvasFixtures,
    this.brightness = Brightness.dark,
    this.textScale = 1,
    this.direction = TextDirection.ltr,
    this.disableAnimations = false,
    this.pendingCanvas = false,
    this.reveal = false,
    this.openMore = false,
    this.eligiblePrompt = false,
    this.activeSearchLabel,
  });

  final String name;
  final String golden;
  final Size size;
  final EdgeInsets safeInsets;
  final String playFixture;
  final List<String> canvasFixtures;
  final Brightness brightness;
  final double textScale;
  final TextDirection direction;
  final bool disableAnimations;
  final bool pendingCanvas;
  final bool reveal;
  final bool openMore;
  final bool eligiblePrompt;
  final String? activeSearchLabel;
}

const _scenarios = <_Scenario>[
  _Scenario(
    name: 'small phone keeps a composed loading-safe entry',
    golden: 'guest_loading_320x640.png',
    size: Size(320, 640),
    safeInsets: EdgeInsets.only(top: 24, bottom: 16),
    playFixture: 'four_day_getaway.json',
    canvasFixtures: <String>['getaway_mood_01.json'],
    pendingCanvas: true,
  ),
  _Scenario(
    name: 'portrait keeps real content legible with More disclosed',
    golden: 'guest_entry_more_390x844.png',
    size: Size(390, 844),
    safeInsets: EdgeInsets.only(top: 47, bottom: 34),
    playFixture: 'four_day_getaway.json',
    canvasFixtures: <String>['getaway_mood_01.json'],
    textScale: 1.6,
    openMore: true,
  ),
  _Scenario(
    name: 'modern phone keeps active search at 200 percent RTL',
    golden: 'guest_search_rtl_large_text_412x915.png',
    size: Size(412, 915),
    safeInsets: EdgeInsets.only(top: 47, bottom: 34),
    playFixture: 'move_one_match.json',
    canvasFixtures: <String>[
      'puzzle_match_01.json',
      'puzzle_match_01_solved.json',
    ],
    textScale: 2,
    direction: TextDirection.rtl,
    activeSearchLabel: 'Puzzles',
  ),
  _Scenario(
    name: 'landscape reveal preserves a dominant solved object',
    golden: 'guest_reveal_reduced_motion_844x390.png',
    size: Size(844, 390),
    safeInsets: EdgeInsets.fromLTRB(44, 0, 44, 21),
    playFixture: 'move_one_match.json',
    canvasFixtures: <String>[
      'puzzle_match_01.json',
      'puzzle_match_01_solved.json',
    ],
    disableAnimations: true,
    reveal: true,
  ),
  _Scenario(
    name: 'tablet keeps the eligible conversion truthful and contextual',
    golden: 'guest_conversion_prompt_768x1024.png',
    size: Size(768, 1024),
    safeInsets: EdgeInsets.only(top: 24, bottom: 20),
    playFixture: 'four_day_getaway.json',
    canvasFixtures: <String>['getaway_mood_01.json'],
    eligiblePrompt: true,
  ),
  _Scenario(
    name: 'desktop remains content-led in the light theme',
    golden: 'guest_entry_desktop_1440x900.png',
    size: Size(1440, 900),
    safeInsets: EdgeInsets.fromLTRB(16, 12, 16, 12),
    playFixture: 'four_day_getaway.json',
    canvasFixtures: <String>['getaway_mood_01.json'],
    brightness: Brightness.light,
  ),
];

void main() {
  setUpAll(_loadInterWhenPresent);

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  testWidgets('actual light and dark app themes resolve Inter', (tester) async {
    for (final brightness in Brightness.values) {
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          brightness;
      final runtime = AppEventRuntime.disabled();
      await tester.pumpWidget(
        ProviderScope(child: MosaicApp(eventRuntime: runtime)),
      );
      await tester.pumpAndSettle();

      final theme = Theme.of(
        tester.element(find.byKey(const ValueKey<String>('guest-home'))),
      );
      expect(theme.brightness, brightness);
      expect(theme.textTheme.headlineSmall?.fontFamily, 'Inter');
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Inter');
      expect(theme.textTheme.labelLarge?.fontFamily, 'Inter');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  for (final scenario in _scenarios) {
    testWidgets(scenario.name, (tester) async {
      final handle = await _pumpScenario(tester, scenario);
      try {
        _expectCompositionGeometry(tester, scenario);

        await expectLater(
          find.byKey(_goldenBoundary),
          matchesGoldenFile('goldens/${scenario.golden}'),
        );
      } finally {
        await handle.close(tester);
      }
    });
  }
}

Future<void> _loadInterWhenPresent() async {
  final font = File('assets/fonts/Inter-VariableFont_opsz,wght.ttf');
  if (!font.existsSync()) return;
  final bytes = await font.readAsBytes();
  final loader = FontLoader('Inter')
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}

Future<_ScenarioHandle> _pumpScenario(
  WidgetTester tester,
  _Scenario scenario,
) async {
  tester.view
    ..physicalSize = scenario.size
    ..devicePixelRatio = 1;

  final fixture = _playFixture(scenario.playFixture);
  final canvases = <String, PlayCanvasAsset>{};
  for (final name in scenario.canvasFixtures) {
    final canvas = _canvasFixture(name);
    canvases[canvas.id] = canvas;
  }
  final pendingCanvas = scenario.pendingCanvas
      ? _PendingCanvasResolver()
      : null;
  final canvasResolver = pendingCanvas ?? MapPlayCanvasAssetResolver(canvases);
  final harness = _GoldenHarness(
    play: fixture.play,
    canvasResolver: canvasResolver,
  );
  final handle = _ScenarioHandle(
    harness: harness,
    pendingCanvas: pendingCanvas,
  );
  addTearDown(() => handle.close(tester));
  await harness.engagement.initialize();
  if (scenario.eligiblePrompt) {
    for (var index = 0; index < 8; index += 1) {
      await harness.engagement.recordVisible(
        playId: 'golden_seen_$index',
        revisionId: 'golden_revision_$index',
      );
    }
  }

  final item = ConsumerFeedItem.fromJson(
    <String, Object?>{
      'playId': fixture.play.id,
      'revisionId': fixture.play.revisionId,
      'sourceBucket': 'known',
      'document': fixture.json,
    },
    compatibilityChecker: const PlayCompatibilityChecker(),
    capabilities: PlayCapabilityEnvelope.m1(),
  );

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _goldenTheme(Brightness.light),
      darkTheme: _goldenTheme(Brightness.dark),
      themeMode: scenario.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) => RepaintBoundary(
        key: _goldenBoundary,
        child: child ?? const SizedBox.shrink(),
      ),
      home: MediaQuery(
        data: MediaQueryData(
          size: scenario.size,
          padding: scenario.safeInsets,
          textScaler: TextScaler.linear(scenario.textScale),
          disableAnimations: scenario.disableAnimations,
        ),
        child: Directionality(
          textDirection: scenario.direction,
          child: GuestHome(
            engagement: harness.engagement,
            onSearch: () {},
            activeSearchLabel: scenario.activeSearchLabel,
            onClearSearch: scenario.activeSearchLabel == null ? null : () {},
            child: ConsumerActionControls(
              item: item,
              feedRequestId: 'golden_feed',
              controller: harness.actions,
              onAdvance: (_) async => true,
              onShare: (_) {},
              child: PlaySurface(
                play: fixture.play,
                mediaBuilder: harness.media.call,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  if (scenario.pendingCanvas) {
    await tester.pump();
  } else {
    await tester.pumpAndSettle();
  }

  if (scenario.reveal) {
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);
    tester.semantics.tap(find.semantics.byLabel('Move match'));
    await tester.pumpAndSettle();
    expect(find.text('8 − 4 = 4'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Solved matchstick equation: 8 minus 4 equals 4'),
      findsOneWidget,
    );
  }
  if (scenario.openMore) {
    await tester.tap(find.byKey(const ValueKey<String>('play-action-more')));
    await tester.pumpAndSettle();
    expect(find.text('More like this'), findsOneWidget);
  }
  if (scenario.eligiblePrompt) {
    expect(find.text('Get early access'), findsOneWidget);
    expect(find.text('Join Mixli'), findsNothing);
  }
  if (scenario.activeSearchLabel != null) {
    expect(find.text(scenario.activeSearchLabel!), findsOneWidget);
    expect(find.text('For You'), findsNothing);
  }
  if (scenario.pendingCanvas) {
    expect(
      find.bySemanticsLabel('Loading interactive graphic'),
      findsOneWidget,
    );
  }
  return handle;
}

void _expectCompositionGeometry(WidgetTester tester, _Scenario scenario) {
  expect(tester.takeException(), isNull);
  expect(find.text('mixli'), findsNothing);
  expect(find.byType(PlayViewportScope), findsOneWidget);
  expect(find.byType(ResolvedPlayCanvas), findsOneWidget);
  if (!scenario.pendingCanvas) expect(find.byType(PlayCanvas), findsOneWidget);

  final composition = tester
      .widget<PlayViewportScope>(find.byType(PlayViewportScope))
      .composition;
  final expected = PlayViewportComposition.fromConstraints(
    BoxConstraints.tight(scenario.size),
    safeInsets: scenario.safeInsets,
    textScaler: TextScaler.linear(scenario.textScale),
  );
  expect(composition.viewportRect, expected.viewportRect);
  expect(composition.safeRect, expected.safeRect);
  expect(composition.chromeRect, expected.chromeRect);
  expect(composition.promptRect, expected.promptRect);
  expect(composition.stageRect, expected.stageRect);
  expect(composition.inputRect, expected.inputRect);
  expect(composition.utilityRect, expected.utilityRect);
  expect(composition.navigationRect, expected.navigationRect);
  expect(composition.utilityPlacement, expected.utilityPlacement);

  final prompt = tester.getRect(
    find.byKey(const ValueKey<String>('play-prompt')),
  );
  final stage = tester.getRect(
    find.byKey(const ValueKey<String>('play-stage')),
  );
  final input = tester.getRect(
    find.byKey(const ValueKey<String>('play-input')),
  );
  final utilities = tester.getRect(
    find.byKey(const ValueKey<String>('play-utilities-region')),
  );
  _expectContained(composition.promptRect, prompt);
  _expectContained(composition.stageRect, stage);
  _expectContained(composition.inputRect, input);
  _expectContained(composition.utilityRect, utilities);
  expect(prompt.overlaps(stage), isFalse);
  expect(stage.overlaps(input), isFalse);
  expect(input.overlaps(utilities), isFalse);
  expect(utilities.overlaps(composition.navigationRect), isFalse);

  final dominantObject = tester.getRect(find.byType(ResolvedPlayCanvas));
  _expectContained(composition.stageRect, dominantObject);
  _expectContained(
    composition.chromeRect,
    tester.getRect(find.byKey(const ValueKey<String>('open-search'))),
  );

  for (final action in const <String>['save', 'share', 'more']) {
    final finder = find.byKey(ValueKey<String>('play-action-$action'));
    expect(finder, findsOneWidget);
    _expectContained(composition.utilityRect, tester.getRect(finder));
  }
  for (final destination in const <String>['play', 'saved', 'create', 'me']) {
    final finder = find.byKey(ValueKey<String>('guest-nav-$destination'));
    expect(finder, findsOneWidget);
    _expectContained(composition.navigationRect, tester.getRect(finder));
  }
  expect(find.bySemanticsLabel('Search Mixli'), findsOneWidget);
  expect(find.byTooltip('Save'), findsOneWidget);
  expect(find.byTooltip('Share'), findsOneWidget);
  expect(find.byTooltip('More'), findsOneWidget);
}

void _expectContained(Rect outer, Rect inner) {
  expect(inner.left, greaterThanOrEqualTo(outer.left));
  expect(inner.top, greaterThanOrEqualTo(outer.top));
  expect(inner.right, lessThanOrEqualTo(outer.right));
  expect(inner.bottom, lessThanOrEqualTo(outer.bottom));
}

ThemeData _goldenTheme(Brightness brightness) => ThemeData(
  brightness: brightness,
  fontFamily: 'Inter',
  scaffoldBackgroundColor: brightness == Brightness.dark
      ? MosaicVisualTokens.surface
      : const Color(0xFFFAFAF8),
  colorScheme: brightness == Brightness.dark
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

_Fixture _playFixture(String name) {
  final raw =
      jsonDecode(
            File(
              '../../packages/play_schema/fixtures/$name',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  return (json: raw, play: PlayDocument.fromJson(raw));
}

PlayCanvasAsset _canvasFixture(String name) {
  final raw =
      jsonDecode(
            File(
              '../../packages/play_flutter/fixtures/canvas/$name',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  return PlayCanvasAsset.fromJson(raw);
}
