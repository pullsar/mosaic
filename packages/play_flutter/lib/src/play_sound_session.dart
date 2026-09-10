import 'package:platform_contracts/platform_contracts.dart';

/// Bounded, silent-safe owner for optional Play voices.
final class PlaySoundSession {
  PlaySoundSession(this._engine, {this.maxVoices = 8});

  final VoiceAudioEngine _engine;
  final int maxVoices;
  final Set<AudioVoice> _voices = <AudioVoice>{};
  bool _released = false;

  Future<void> play(String assetId, {double gain = 1}) async {
    if (_released ||
        _voices.length >= maxVoices ||
        !gain.isFinite ||
        gain < 0 ||
        gain > 1)
      return;
    final voice = await _engine.startVoice(assetId, gain: gain);
    if (_released) {
      await _engine.stopVoice(voice);
      return;
    }
    _voices.add(voice);
  }

  Future<void> stopAll() async {
    final voices = _voices.toList(growable: false);
    _voices.clear();
    for (final voice in voices) {
      await _engine.stopVoice(voice);
    }
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await stopAll();
  }
}
