import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/game_sound_controller.dart';
import 'package:mosaic_app/game_sound_controls.dart';
import 'package:mosaic_app/game_sound_preferences.dart';

final class _SoundStore implements GameSoundPreferencesStore {
  GameSoundPreferences preferences = GameSoundPreferences();

  @override
  Future<GameSoundPreferences> readGameSoundPreferences() async => preferences;

  @override
  Future<void> writeGameSoundPreferences(GameSoundPreferences value) async =>
      preferences = value;
}

void main() {
  testWidgets('sound control changes the persisted mute preference', (
    tester,
  ) async {
    final store = _SoundStore();
    final controller = GameSoundController(store: store);
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GameSoundControl(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('game-sound-control')));
    await tester.pumpAndSettle();

    expect(find.text('Sound'), findsOneWidget);
    await tester.tap(find.text('Mute'));
    await tester.pump();

    expect(controller.preferences.masterMuted, isTrue);
    expect(store.preferences.masterMuted, isTrue);
  });

  testWidgets('sound control persists music, effects, and a curated theme', (
    tester,
  ) async {
    final store = _SoundStore();
    final controller = GameSoundController(store: store);
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GameSoundControl(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('game-sound-control')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Music'));
    await tester.tap(find.text('Effects'));
    await tester.tap(find.text('Orbital'));
    await tester.pump();

    expect(controller.preferences.musicEnabled, isTrue);
    expect(controller.preferences.effectsEnabled, isTrue);
    expect(controller.preferences.themeId, 'orbital');
    expect(store.preferences.toJson(), controller.preferences.toJson());
  });
}
