import 'play_audio_renderer.dart';

/// Decoder for the renderer-facing managed audio asset envelope.
///
/// This intentionally does not define server persistence. It converts verified
/// asset-catalog metadata into the provider-neutral [PlayAudioAsset] consumed
/// by the Play renderer.
abstract final class PlayAudioAssetCodec {
  static PlayAudioAsset decode(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported audio asset schemaVersion.');
    }

    final id = json['id'];
    final uriRaw = json['uri'];
    final semanticLabel = json['semanticLabel'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('Audio asset requires a non-empty id.');
    }
    if (uriRaw is! String || uriRaw.trim().isEmpty) {
      throw const FormatException('Audio asset requires a non-empty uri.');
    }
    if (semanticLabel != null && semanticLabel is! String) {
      throw const FormatException('semanticLabel must be a string.');
    }

    final uri = Uri.tryParse(uriRaw.trim());
    if (uri == null) {
      throw const FormatException('Audio asset uri is malformed.');
    }

    return PlayAudioAsset(
      id: id,
      uri: uri,
      semanticLabel: semanticLabel as String?,
    );
  }
}
