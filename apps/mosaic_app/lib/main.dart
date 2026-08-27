import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:platform_flutter/platform_flutter.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

void main() => runApp(const ProviderScope(child: MosaicApp()));

final class MosaicApp extends StatefulWidget {
  const MosaicApp({super.key});

  @override
  State<MosaicApp> createState() => _MosaicAppState();
}

final class _MosaicAppState extends State<MosaicApp> {
  final ActiveMediaCoordinator _mediaCoordinator = ActiveMediaCoordinator();
  late final FlutterLifecycleBridge _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = FlutterLifecycleBridge(
      mediaCoordinator: _mediaCoordinator,
      onError: _reportPlatformError,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(
      _mediaCoordinator.releaseAll().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _reportPlatformError(error, stackTrace);
      }),
    );
    super.dispose();
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
  Widget build(BuildContext context) => MaterialApp(
    title: 'Mosaic',
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.system,
    darkTheme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: MosaicVisualTokens.surface,
      colorScheme: const ColorScheme.dark(
        surface: MosaicVisualTokens.surface,
        onSurface: MosaicVisualTokens.foreground,
      ),
    ),
    theme: ThemeData(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF262626)),
    ),
    routes: {
      MosaicSettingsRoute.privacy: (_) =>
          const _ReservedSettingsPage('Privacy'),
      MosaicSettingsRoute.support: (_) =>
          const _ReservedSettingsPage('Support'),
      MosaicSettingsRoute.deleteAccount: (_) =>
          const _ReservedSettingsPage('Delete account'),
    },
    home: PlaySurface(
      play: _demoPlay,
      mediaBuilder: (context, layer) => const _VisualPlaceholder(),
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

final class _VisualPlaceholder extends StatelessWidget {
  const _VisualPlaceholder();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF113044), Color(0xFF8D5B3E)],
      ),
    ),
  );
}

final _demoPlay = PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'demo_where_is_this',
  'revisionId': 'rev_1',
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
          {'type': 'image', 'role': 'media', 'assetId': 'demo_visual'},
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
