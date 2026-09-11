import 'dart:async';

import 'package:flutter/material.dart';

import 'game_sound_controller.dart';

/// A compact, accessible control for the optional Play sound policy.
final class GameSoundControl extends StatelessWidget {
  const GameSoundControl({required this.controller, super.key});

  final GameSoundController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final muted = controller.preferences.masterMuted;
      return IconButton(
        key: const ValueKey<String>('game-sound-control'),
        tooltip: muted ? 'Sound off' : 'Sound',
        onPressed: () => showGameSoundControls(context, controller),
        icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
      );
    },
  );
}

Future<void> showGameSoundControls(
  BuildContext context,
  GameSoundController controller,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _GameSoundSheet(controller: controller),
);

final class _GameSoundSheet extends StatelessWidget {
  const _GameSoundSheet({required this.controller});

  final GameSoundController controller;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final preferences = controller.preferences;
        return SingleChildScrollView(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Padding(
                padding: EdgeInsetsDirectional.only(start: 4, bottom: 4),
                child: Text('Sound'),
              ),
              SwitchListTile.adaptive(
                key: const ValueKey<String>('game-sound-master'),
                title: const Text('Mute'),
                secondary: Icon(
                  preferences.masterMuted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                ),
                value: !preferences.masterMuted,
                onChanged: (value) =>
                    unawaited(controller.setMasterMuted(!value)),
              ),
              SwitchListTile.adaptive(
                key: const ValueKey<String>('game-sound-music'),
                title: const Text('Music'),
                secondary: const Icon(Icons.music_note_rounded),
                value: preferences.musicEnabled,
                onChanged: (value) =>
                    unawaited(controller.setMusicEnabled(value)),
              ),
              SwitchListTile.adaptive(
                key: const ValueKey<String>('game-sound-effects'),
                title: const Text('Effects'),
                secondary: const Icon(Icons.auto_awesome_rounded),
                value: preferences.effectsEnabled,
                onChanged: (value) =>
                    unawaited(controller.setEffectsEnabled(value)),
              ),
              const SizedBox(height: 12),
              Text('Theme', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final theme in _curatedThemes)
                    ChoiceChip(
                      key: ValueKey<String>(
                        'game-theme:${theme.id ?? 'random'}',
                      ),
                      label: Text(theme.label),
                      selected: preferences.themeId == theme.id,
                      onSelected: (_) =>
                          unawaited(controller.setThemeId(theme.id)),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
}

final class _CuratedTheme {
  const _CuratedTheme({required this.id, required this.label});

  final String? id;
  final String label;
}

const _curatedThemes = <_CuratedTheme>[
  _CuratedTheme(id: null, label: 'Random'),
  _CuratedTheme(id: 'paper-studio', label: 'Paper Studio'),
  _CuratedTheme(id: 'night-museum', label: 'Night Museum'),
  _CuratedTheme(id: 'glass-garden', label: 'Glass Garden'),
  _CuratedTheme(id: 'orbital', label: 'Orbital'),
];
