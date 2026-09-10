import 'dart:collection';

final class GameSoundPreferences {
  GameSoundPreferences({
    this.masterMuted = false,
    this.musicEnabled = false,
    this.effectsEnabled = false,
    String? themeId,
  }) : themeId = themeId == null ? null : _themeId(themeId);

  final bool masterMuted;
  final bool musicEnabled;
  final bool effectsEnabled;
  final String? themeId;

  factory GameSoundPreferences.fromJson(Map<String, Object?> json) {
    final masterMuted = json['masterMuted'];
    final musicEnabled = json['musicEnabled'];
    final effectsEnabled = json['effectsEnabled'];
    final themeId = json['themeId'];
    if (masterMuted != null && masterMuted is! bool ||
        musicEnabled != null && musicEnabled is! bool ||
        effectsEnabled != null && effectsEnabled is! bool ||
        themeId != null && themeId is! String) {
      throw const FormatException('Sound preferences are malformed.');
    }
    return GameSoundPreferences(
      masterMuted: masterMuted as bool? ?? false,
      musicEnabled: musicEnabled as bool? ?? false,
      effectsEnabled: effectsEnabled as bool? ?? false,
      themeId: themeId as String?,
    );
  }

  Map<String, Object?> toJson() => UnmodifiableMapView(<String, Object?>{
    'masterMuted': masterMuted,
    'musicEnabled': musicEnabled,
    'effectsEnabled': effectsEnabled,
    'themeId': themeId,
  });
}

abstract interface class GameSoundPreferencesStore {
  Future<GameSoundPreferences> readGameSoundPreferences();
  Future<void> writeGameSoundPreferences(GameSoundPreferences preferences);
}

String _themeId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 200) {
    throw const FormatException('themeId must be 1 to 200 characters.');
  }
  return normalized;
}
