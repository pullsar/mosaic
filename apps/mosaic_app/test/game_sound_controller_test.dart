import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/game_sound_controller.dart';
import 'package:mosaic_app/game_sound_preferences.dart';

final class _MemorySoundPreferencesStore implements GameSoundPreferencesStore {
  _MemorySoundPreferencesStore(this.preferences);

  GameSoundPreferences preferences;
  final List<GameSoundPreferences> writes = <GameSoundPreferences>[];
  Completer<GameSoundPreferences>? readGate;
  Completer<void>? writeGate;

  @override
  Future<GameSoundPreferences> readGameSoundPreferences() async =>
      await readGate?.future ?? preferences;

  @override
  Future<void> writeGameSoundPreferences(GameSoundPreferences value) async {
    final gate = writeGate;
    if (gate != null) await gate.future;
    preferences = value;
    writes.add(value);
  }
}

void main() {
  test(
    'loads quiet sound preferences and persists immediate changes in order',
    () async {
      final store = _MemorySoundPreferencesStore(GameSoundPreferences());
      final controller = GameSoundController(store: store);
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.preferences.musicEnabled, isFalse);

      final first = controller.setMusicEnabled(true);
      final second = controller.setEffectsEnabled(true);
      await Future.wait([first, second]);

      expect(store.writes, hasLength(2));
      expect(store.writes.first.musicEnabled, isTrue);
      expect(store.writes.first.effectsEnabled, isFalse);
      expect(store.preferences.musicEnabled, isTrue);
      expect(store.preferences.effectsEnabled, isTrue);
    },
  );

  test('does not notify or write after disposal', () async {
    final store = _MemorySoundPreferencesStore(
      GameSoundPreferences(musicEnabled: true),
    );
    final controller = GameSoundController(store: store);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    await controller.initialize();
    controller.dispose();
    await controller.setMasterMuted(true);

    expect(notifications, 1);
    expect(store.writes, isEmpty);
  });

  test(
    'queues a sound change until persisted preferences finish loading',
    () async {
      final store = _MemorySoundPreferencesStore(GameSoundPreferences())
        ..readGate = Completer<GameSoundPreferences>();
      final controller = GameSoundController(store: store);
      addTearDown(controller.dispose);

      final load = controller.initialize();
      final change = controller.setMasterMuted(true);
      store.readGate!.complete(
        GameSoundPreferences(musicEnabled: true, effectsEnabled: true),
      );
      await Future.wait([load, change]);

      expect(controller.preferences.masterMuted, isTrue);
      expect(controller.preferences.musicEnabled, isTrue);
      expect(controller.preferences.effectsEnabled, isTrue);
      expect(store.writes.single.masterMuted, isTrue);
    },
  );
}
