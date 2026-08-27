import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

void main() => runApp(const ProviderScope(child: MosaicApp()));

final class MosaicApp extends StatelessWidget {
  const MosaicApp({super.key});

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
        home: PlaySurface(
          play: _demoPlay,
          mediaBuilder: (context, layer) => const _VisualPlaceholder(),
        ),
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
