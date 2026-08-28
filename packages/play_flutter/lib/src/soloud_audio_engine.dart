import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:platform_contracts/platform_contracts.dart';

/// Production low-latency [AudioEngine] backed by `flutter_soloud`.
///
/// Mosaic keeps one engine for the app process because SoLoud itself is a
/// singleton. Sources are loaded into memory for the short piano/rhythm assets
/// used by Plays, while individual playing instances remain owned by SoLoud's
/// source handle set.
final class SoLoudAudioEngine implements AudioEngine {
  factory SoLoudAudioEngine() => _instance;

  SoLoudAudioEngine._();

  static final SoLoudAudioEngine _instance = SoLoudAudioEngine._();
  static const int _sampleRate = 44100;
  static const int _bufferSize = 1024;

  final SoLoud _soloud = SoLoud.instance;
  final Map<String, AudioSource> _sources = <String, AudioSource>{};
  final Map<String, Uri> _sourceUris = <String, Uri>{};
  final Map<String, Future<AudioSource>> _pendingLoads =
      <String, Future<AudioSource>>{};
  Future<void>? _initialization;

  @override
  Future<void> load(String assetId, Uri uri) async {
    final id = _assetId(assetId);
    _requireHttps(uri);

    final knownUri = _sourceUris[id];
    if (knownUri != null && knownUri != uri) {
      throw StateError('Audio asset $id was already bound to another URI.');
    }
    if (_sources.containsKey(id)) return;

    final pending = _pendingLoads[id];
    if (pending != null) {
      await pending;
      return;
    }

    await _ensureInitialized();
    _sourceUris[id] = uri;
    final loading = _soloud.loadUrl(
      uri.toString(),
      mode: LoadMode.memory,
      autoDispose: false,
    );
    _pendingLoads[id] = loading;

    try {
      final source = await loading;
      _sources[id] = source;
    } catch (_) {
      if (_sourceUris[id] == uri) {
        _sourceUris.remove(id);
      }
      rethrow;
    } finally {
      if (identical(_pendingLoads[id], loading)) {
        _pendingLoads.remove(id)?.ignore();
      }
    }
  }

  @override
  Future<void> play(String assetId) async {
    final source = _source(assetId);
    _soloud.play(source);
  }

  @override
  Future<void> schedule(String assetId, Duration offset) async {
    if (offset.isNegative) {
      throw ArgumentError.value(offset, 'offset', 'must not be negative');
    }
    final source = _source(assetId);
    final atTime = _soloud.getEngineTime() + offset;
    _soloud.playScheduled(source, atTime);
  }

  @override
  Future<void> stop(String assetId) async {
    final source = _sources[_assetId(assetId)];
    if (source == null) return;
    final handles = source.handles.toList(growable: false);
    if (handles.isEmpty) return;
    await Future.wait(handles.map(_soloud.stop));
  }

  @override
  Future<void> release(String assetId) async {
    final id = _assetId(assetId);
    final pending = _pendingLoads[id];
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        _sourceUris.remove(id);
        return;
      }
    }

    final source = _sources[id];
    if (source == null) {
      _sourceUris.remove(id);
      return;
    }

    await _soloud.disposeSource(source);
    if (identical(_sources[id], source)) {
      _sources.remove(id);
      _sourceUris.remove(id);
    }
  }

  @override
  Map<String, num> get latencyMetrics => const <String, num>{
    'sampleRateHz': _sampleRate,
    'bufferFrames': _bufferSize,
    'estimatedBufferMs': _bufferSize * 1000 / _sampleRate,
  };

  /// Releases every loaded source and shuts the native audio device down.
  ///
  /// The singleton may be initialized again later if a new app lifecycle owns
  /// it; `deinitAsync` avoids blocking the UI isolate during device teardown.
  Future<void> dispose() async {
    final initializing = _initialization;
    if (initializing != null) {
      try {
        await initializing;
      } catch (_) {
        // Failed initialization owns no running audio device.
      }
    }

    final pending = _pendingLoads.values.toList(growable: false);
    for (final load in pending) {
      try {
        await load;
      } catch (_) {
        // Failed loads own no usable source and need no further cleanup here.
      }
    }

    if (_soloud.isInitialized) {
      await _soloud.deinitAsync();
    }
    _sources.clear();
    _sourceUris.clear();
    _pendingLoads.clear();
    _initialization = null;
  }

  Future<void> _ensureInitialized() {
    if (_soloud.isInitialized) return Future<void>.value();
    final pending = _initialization;
    if (pending != null) return pending;

    final initializing = _soloud.init(
      automaticCleanup: false,
      sampleRate: _sampleRate,
      bufferSize: _bufferSize,
      channels: Channels.stereo,
      lowLatency: true,
    );
    _initialization = initializing;
    return initializing.whenComplete(() {
      if (identical(_initialization, initializing)) {
        _initialization = null;
      }
    });
  }

  AudioSource _source(String assetId) {
    final id = _assetId(assetId);
    final source = _sources[id];
    if (source == null) {
      throw StateError('Audio asset $id has not been loaded.');
    }
    return source;
  }
}

String _assetId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, 'assetId', 'must not be empty');
  }
  return normalized;
}

void _requireHttps(Uri uri) {
  if (!uri.isAbsolute || uri.scheme != 'https' || uri.host.isEmpty) {
    throw ArgumentError.value(uri, 'uri', 'must be an absolute HTTPS URI');
  }
}
