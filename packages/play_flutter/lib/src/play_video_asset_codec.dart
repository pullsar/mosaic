import 'play_video_renderer.dart';

/// Decoder for renderer-facing managed video metadata.
abstract final class PlayVideoAssetCodec {
  static PlayVideoAsset decode(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported video asset schemaVersion.');
    }
    final id = json['id'];
    final sourceRaw = json['source'];
    final semanticLabel = json['semanticLabel'];
    final autoplayRaw = json['autoplay'];
    final mutedRaw = json['muted'];
    final formatRaw = json['format'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('Video asset requires a non-empty id.');
    }
    if (sourceRaw is! Map) {
      throw const FormatException('Video asset requires a source object.');
    }
    if (semanticLabel != null && semanticLabel is! String) {
      throw const FormatException('semanticLabel must be a string.');
    }
    if (autoplayRaw != null && autoplayRaw is! bool) {
      throw const FormatException('autoplay must be a boolean.');
    }
    if (mutedRaw != null && mutedRaw is! bool) {
      throw const FormatException('muted must be a boolean.');
    }

    final autoplay = autoplayRaw as bool? ?? true;
    final muted = mutedRaw as bool? ?? true;
    if (autoplay && !muted) {
      throw const FormatException('Autoplay video assets must be muted.');
    }

    final source = _source(Map<String, Object?>.from(sourceRaw));
    return PlayVideoAsset(
      id: id,
      source: source,
      semanticLabel: semanticLabel as String?,
      autoplay: autoplay,
      muted: muted,
      format: _format(formatRaw),
    );
  }

  static PlayVideoFormatMetadata? _format(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw const FormatException('Video format metadata must be an object.');
    }
    final json = Map<String, Object?>.from(raw);
    String? stringValue(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('Video format $key must be a string.');
      }
      return value;
    }

    try {
      return PlayVideoFormatMetadata(
        container: stringValue('container'),
        videoCodec: stringValue('videoCodec'),
        videoProfile: stringValue('videoProfile'),
        audioCodec: stringValue('audioCodec'),
      );
    } on ArgumentError catch (error) {
      throw FormatException(
        error.message?.toString() ?? 'Invalid video format.',
      );
    }
  }

  static PlayVideoSource _source(Map<String, Object?> json) {
    final type = json['type'];
    if (type == 'network') {
      final uriRaw = json['uri'];
      if (uriRaw is! String || uriRaw.trim().isEmpty) {
        throw const FormatException('Network video source requires a uri.');
      }
      final uri = Uri.tryParse(uriRaw.trim());
      if (uri == null) {
        throw const FormatException('Network video uri is malformed.');
      }
      final headersRaw = json['headers'];
      Map<String, String>? headers;
      if (headersRaw != null) {
        if (headersRaw is! Map) {
          throw const FormatException('Video headers must be an object.');
        }
        final parsed = <String, String>{};
        for (final entry in headersRaw.entries) {
          if (entry.key is! String || entry.value is! String) {
            throw const FormatException('Video headers must contain strings.');
          }
          parsed[entry.key as String] = entry.value as String;
        }
        headers = Map<String, String>.unmodifiable(parsed);
      }
      return NetworkPlayVideoSource(uri, headers: headers);
    }
    if (type == 'bundle') {
      final assetName = json['assetName'];
      if (assetName is! String || assetName.trim().isEmpty) {
        throw const FormatException('Bundle video source requires assetName.');
      }
      return BundlePlayVideoSource(assetName);
    }
    throw FormatException('Unsupported video source type: $type');
  }
}
