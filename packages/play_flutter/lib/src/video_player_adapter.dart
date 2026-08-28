import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'play_video_renderer.dart';

/// Production [PlayVideoController] backed by Flutter's first-party
/// `video_player` plugin.
///
/// Background playback is disabled and short feed clips never keep the display
/// awake on their own. Mosaic's shared media coordinator remains the authority
/// for foreground/offscreen ownership and release.
final class VideoPlayerPlayController implements PlayVideoController {
  VideoPlayerPlayController(PlayVideoAsset asset)
    : _controller = _controllerFor(asset.source);

  final VideoPlayerController _controller;
  var _initialized = false;
  var _released = false;

  @override
  Future<void> initialize() async {
    _assertNotReleased();
    if (_initialized) return;
    await _controller.initialize();
    _initialized = true;
  }

  @override
  Future<void> setMuted(bool muted) async {
    _assertReady();
    await _controller.setVolume(muted ? 0 : 1);
  }

  @override
  Future<void> play() async {
    _assertReady();
    try {
      await _controller.play();
    } on Object catch (error) {
      if (kIsWeb) {
        throw PlayVideoPlaybackRejected(error);
      }
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    if (_released || !_initialized) return;
    await _controller.pause();
  }

  @override
  Future<void> release() async {
    if (_released) return;
    await _controller.dispose();
    _released = true;
    _initialized = false;
  }

  @override
  Widget buildView(BuildContext context) {
    _assertReady();
    return _CoverVideoPlayer(controller: _controller);
  }

  void _assertNotReleased() {
    if (_released) {
      throw StateError('Video controller has already been released.');
    }
  }

  void _assertReady() {
    _assertNotReleased();
    if (!_initialized) {
      throw StateError('Video controller has not been initialized.');
    }
  }
}

VideoPlayerController _controllerFor(PlayVideoSource source) {
  final options = VideoPlayerOptions(
    mixWithOthers: false,
    allowBackgroundPlayback: false,
    preventsDisplaySleepDuringVideoPlayback: false,
  );

  return switch (source) {
    NetworkPlayVideoSource(:final uri, :final headers) => _networkController(
      uri,
      headers,
      options,
    ),
    BundlePlayVideoSource(:final assetName) => VideoPlayerController.asset(
      assetName,
      videoPlayerOptions: options,
    ),
  };
}

VideoPlayerController _networkController(
  Uri uri,
  Map<String, String>? headers,
  VideoPlayerOptions options,
) {
  if (kIsWeb && headers != null && headers.isNotEmpty) {
    throw UnsupportedError(
      'Authenticated video headers are not supported by video_player_web. '
      'Use a signed or cookie-compatible HTTPS media URL on web.',
    );
  }

  return VideoPlayerController.networkUrl(
    uri,
    httpHeaders: headers ?? const <String, String>{},
    videoPlayerOptions: options,
  );
}

final class _CoverVideoPlayer extends StatelessWidget {
  const _CoverVideoPlayer({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    if (size.width <= 0 || size.height <= 0) {
      return VideoPlayer(controller);
    }

    return SizedBox.expand(
      child: ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox.fromSize(size: size, child: VideoPlayer(controller)),
        ),
      ),
    );
  }
}
