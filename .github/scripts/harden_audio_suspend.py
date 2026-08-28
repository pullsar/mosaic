from pathlib import Path


path = Path('packages/play_flutter/lib/src/play_audio_renderer.dart')
text = path.read_text()

old = '''  Future<_AudioMediaHandle?> _loadHandle(int generation) async {
    final asset = widget.asset;
    final engine = widget.engine;
    final coordinator = widget.coordinator;
    final ownerId = _requireAudioText(widget.ownerId, 'ownerId');
    final handle = _AudioMediaHandle(engine, asset.id);

    _handle = handle;
    _handleCoordinator = coordinator;
    _handleOwnerId = ownerId;

    try {
      // Transfer coordinator ownership before loading. This guarantees a
      // predecessor using the same logical asset ID is fully stopped and
      // released before a shared engine creates/reuses the successor source.
      await coordinator.activate(ownerId, handle);
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return null;
      }

      await engine.load(asset.id, asset.uri);
    } on Object catch (error, stackTrace) {
      try {
        await _releaseCurrent();
      } on Object catch (cleanupError, cleanupStackTrace) {
        _reportError(asset, cleanupError, cleanupStackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    if (!_isCurrent(generation) || !widget.active) {
      await _releaseCurrent();
      return null;
    }
    return handle;
  }
'''
new = '''  Future<_AudioLoadResult?> _loadHandle(int generation) async {
    final asset = widget.asset;
    final engine = widget.engine;
    final coordinator = widget.coordinator;
    final ownerId = _requireAudioText(widget.ownerId, 'ownerId');
    final handle = _AudioMediaHandle(engine, asset.id);
    final userPauseEpoch = handle.pauseEpoch;

    _handle = handle;
    _handleCoordinator = coordinator;
    _handleOwnerId = ownerId;

    try {
      // Transfer coordinator ownership before loading. This guarantees a
      // predecessor using the same logical asset ID is fully stopped and
      // released before a shared engine creates/reuses the successor source.
      await coordinator.activate(ownerId, handle);
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return null;
      }

      await engine.load(asset.id, asset.uri);
    } on Object catch (error, stackTrace) {
      try {
        await _releaseCurrent();
      } on Object catch (cleanupError, cleanupStackTrace) {
        _reportError(asset, cleanupError, cleanupStackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    if (!_isCurrent(generation) || !widget.active) {
      await _releaseCurrent();
      return null;
    }
    return _AudioLoadResult(handle, userPauseEpoch);
  }
'''
if old not in text:
    raise SystemExit('loadHandle block changed unexpectedly')
text = text.replace(old, new, 1)

old = '''      var handle = _handle;
      if (handle == null || handle.released) {
        handle = await _loadHandle(generation);
        if (handle == null) return;
      }

      final coordinator = _handleCoordinator;
      final ownerId = _handleOwnerId;
      if (coordinator == null || ownerId == null) {
        throw StateError('Audio handle lost its media ownership context.');
      }

      await coordinator.activate(ownerId, handle);
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return;
      }

      if (_played) {
        await handle.pause();
        if (!_isCurrent(generation) || !widget.active) {
          await _releaseCurrent();
          return;
        }
      }

      await handle.engine.play(handle.assetId);
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return;
      }

      _publishPlayed(generation);
'''
new = '''      var handle = _handle;
      var userPauseEpoch = handle?.pauseEpoch;
      if (handle == null || handle.released) {
        final loaded = await _loadHandle(generation);
        if (loaded == null) return;
        handle = loaded.handle;
        userPauseEpoch = loaded.userPauseEpoch;
      }

      final coordinator = _handleCoordinator;
      final ownerId = _handleOwnerId;
      if (coordinator == null || ownerId == null) {
        throw StateError('Audio handle lost its media ownership context.');
      }

      await coordinator.activate(ownerId, handle);
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return;
      }

      if (_played && !handle.paused) {
        await handle.pause();
        userPauseEpoch = handle.pauseEpoch;
        if (!_isCurrent(generation) || !widget.active) {
          await _releaseCurrent();
          return;
        }
      }

      final played = await handle.playFromUserAction(
        userPauseEpoch ?? handle.pauseEpoch,
      );
      if (!played) {
        _publishIdle(generation);
        return;
      }
      if (!_isCurrent(generation) || !widget.active) {
        await _releaseCurrent();
        return;
      }

      _publishPlayed(generation);
'''
if old not in text:
    raise SystemExit('play block changed unexpectedly')
text = text.replace(old, new, 1)

start = text.index('final class _AudioMediaHandle implements ManagedMediaHandle {')
end = text.index('\nfinal class PlayAudioUnavailable', start)
replacement = '''final class _AudioLoadResult {
  const _AudioLoadResult(this.handle, this.userPauseEpoch);

  final _AudioMediaHandle handle;
  final int userPauseEpoch;
}

final class _AudioMediaHandle implements ManagedMediaHandle {
  _AudioMediaHandle(this.engine, this.assetId);

  final AudioEngine engine;
  final String assetId;
  Future<void> _tail = Future<void>.value();
  int _pauseEpoch = 0;
  bool paused = false;
  bool released = false;

  int get pauseEpoch => _pauseEpoch;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<bool> playFromUserAction(int expectedPauseEpoch) =>
      _serialize(() async {
        if (released) {
          throw StateError('Audio handle has already been released.');
        }
        if (_pauseEpoch != expectedPauseEpoch) return false;

        await engine.play(assetId);
        if (released || _pauseEpoch != expectedPauseEpoch) return false;
        paused = false;
        return true;
      });

  @override
  Future<void> pause() {
    if (released) return Future<void>.value();
    _pauseEpoch += 1;
    paused = true;
    return _serialize(() async {
      if (released) return;
      await engine.stop(assetId);
    });
  }

  @override
  Future<void> release() {
    if (released) return Future<void>.value();
    _pauseEpoch += 1;
    paused = true;
    return _serialize(() async {
      if (released) return;
      await engine.release(assetId);
      released = true;
    });
  }
}
'''
text = text[:start] + replacement + text[end:]
path.write_text(text)

test = Path('packages/play_flutter/test/play_audio_renderer_test.dart')
tests = test.read_text()
if "import 'dart:async';" not in tests:
    tests = "import 'dart:async';\n\n" + tests
if '  Completer<void>? loadGate;\n' not in tests:
    tests = tests.replace(
        '  Object? releaseError;\n',
        '  Object? releaseError;\n  Completer<void>? loadGate;\n',
        1,
    )
old_load = "    events.add('load:$assetId');\n    final error = loadError;"
new_load = "    events.add('load:$assetId');\n    final gate = loadGate;\n    if (gate != null) await gate.future;\n    final error = loadError;"
if old_load in tests:
    tests = tests.replace(old_load, new_load, 1)
elif new_load not in tests:
    raise SystemExit('fake engine load block changed unexpectedly')

marker = "  testWidgets('Replay stops the prior voice and reuses the loaded handle', (\n"
regression = '''  testWidgets(
    'lifecycle suspension during load cancels that user playback intent',
    (tester) async {
      final gate = Completer<void>();
      final engine = _FakeAudioEngine()..loadGate = gate;
      final coordinator = ActiveMediaCoordinator();

      await _pumpAudio(
        tester,
        ownerId: 'play_a',
        asset: _asset('audio_a'),
        engine: engine,
        coordinator: coordinator,
      );
      await tester.tap(find.text('Hear'));
      await tester.pump();

      expect(engine.events, ['load:audio_a']);
      expect(coordinator.ownerId, 'play_a');

      await coordinator.suspend();
      expect(engine.events, ['load:audio_a', 'stop:audio_a']);

      gate.complete();
      await tester.pumpAndSettle();

      expect(engine.events, ['load:audio_a', 'stop:audio_a']);
      expect(find.text('Hear'), findsOneWidget);
      expect(coordinator.ownerId, 'play_a');

      await tester.tap(find.text('Hear'));
      await tester.pumpAndSettle();

      expect(engine.events, [
        'load:audio_a',
        'stop:audio_a',
        'play:audio_a',
      ]);
      expect(find.text('Replay'), findsOneWidget);
    },
  );

'''
if regression not in tests:
    if marker not in tests:
        raise SystemExit('audio regression insertion marker changed')
    tests = tests.replace(marker, regression + marker, 1)
test.write_text(tests)
