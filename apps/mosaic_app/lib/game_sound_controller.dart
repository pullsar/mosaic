import 'package:flutter/foundation.dart';

import 'game_sound_preferences.dart';

typedef GameSoundErrorReporter = void Function(Object error, StackTrace stack);

/// Owns the local, user-selected sound policy for Plays.
///
/// This controller never starts playback. Renderers consult its current policy
/// only after a user has explicitly started a sound-bearing interaction.
final class GameSoundController extends ChangeNotifier {
  GameSoundController({required GameSoundPreferencesStore store, this.onError})
    : _store = store;

  final GameSoundPreferencesStore _store;
  final GameSoundErrorReporter? onError;
  GameSoundPreferences _preferences = GameSoundPreferences();
  Future<void>? _initializing;
  Future<void> _writes = Future<void>.value();
  bool _initialized = false;
  bool _disposed = false;

  GameSoundPreferences get preferences => _preferences;
  bool get initialized => _initialized;

  Future<void> initialize() {
    if (_initialized || _disposed) return Future<void>.value();
    return _initializing ??= _load();
  }

  Future<void> _load() async {
    try {
      final restored = await _store.readGameSoundPreferences();
      if (_disposed) return;
      _preferences = restored;
    } catch (error, stackTrace) {
      onError?.call(error, stackTrace);
    } finally {
      if (_disposed) return;
      _initialized = true;
      notifyListeners();
    }
  }

  Future<void> setMasterMuted(bool value) => _update(
    GameSoundPreferences(
      masterMuted: value,
      musicEnabled: _preferences.musicEnabled,
      effectsEnabled: _preferences.effectsEnabled,
      themeId: _preferences.themeId,
    ),
  );

  Future<void> setMusicEnabled(bool value) => _update(
    GameSoundPreferences(
      masterMuted: _preferences.masterMuted,
      musicEnabled: value,
      effectsEnabled: _preferences.effectsEnabled,
      themeId: _preferences.themeId,
    ),
  );

  Future<void> setEffectsEnabled(bool value) => _update(
    GameSoundPreferences(
      masterMuted: _preferences.masterMuted,
      musicEnabled: _preferences.musicEnabled,
      effectsEnabled: value,
      themeId: _preferences.themeId,
    ),
  );

  Future<void> setThemeId(String? value) => _update(
    GameSoundPreferences(
      masterMuted: _preferences.masterMuted,
      musicEnabled: _preferences.musicEnabled,
      effectsEnabled: _preferences.effectsEnabled,
      themeId: value,
    ),
  );

  Future<void> _update(GameSoundPreferences next) {
    if (_disposed) return Future<void>.value();
    _preferences = next;
    notifyListeners();
    final write = _writes.then((_) => _store.writeGameSoundPreferences(next));
    _writes = write.catchError((Object error, StackTrace stackTrace) {
      onError?.call(error, stackTrace);
    });
    return _writes;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
