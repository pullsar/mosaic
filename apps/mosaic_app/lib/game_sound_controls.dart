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
        return Padding(
          padding: const EdgeInsetsDirectional.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const ListTile(title: Text('Sound')),
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
            ],
          ),
        );
      },
    ),
  );
}
