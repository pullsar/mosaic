import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';

final class _PosterVideoController implements PlayVideoController {
  _PosterVideoController({this.initializeGate, this.initializeError});

  final Completer<void>? initializeGate;
  final Object? initializeError;
  var releaseCount = 0;

  @override
  Future<void> initialize() async {
    await initializeGate?.future;
    final error = initializeError;
    if (error != null) throw error;
  }

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> release() async => releaseCount += 1;

  @override
  Widget buildView(BuildContext context) => const ColoredBox(
    color: Colors.black,
    child: Center(child: Text('video-frame')),
  );
}

PlayVideoAsset _video() => PlayVideoAsset(
  id: 'clip',
  source: NetworkPlayVideoSource(Uri.parse('https://cdn.example.com/clip.mp4')),
  semanticLabel: 'Travel clip',
);

PlayVisualAsset _poster() => PlayVisualAsset(
  id: 'clip_poster',
  semanticLabel: 'Travel clip poster',
  source: MemoryPlayVisualSource(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('managed poster is shown while video initialization is pending', (
    tester,
  ) async {
    final gate = Completer<void>();
    final controller = _PosterVideoController(initializeGate: gate);

    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVideo(
          ownerId: 'play',
          assetId: 'clip',
          resolver: MapPlayVideoAssetResolver({'clip': _video()}),
          posterResolver: MapPlayVideoPosterResolver({'clip': _poster()}),
          coordinator: ActiveMediaCoordinator(),
          controllerFactory: (_) => controller,
        ),
      ),
    );
    await _settle(tester);

    expect(find.bySemanticsLabel('Travel clip poster'), findsOneWidget);
    expect(find.text('video-frame'), findsNothing);

    gate.complete();
    await _settle(tester);

    expect(find.text('video-frame'), findsOneWidget);
  });

  testWidgets(
    'hard video initialization failure releases media and keeps poster visible',
    (tester) async {
      final controller = _PosterVideoController(
        initializeError: StateError('decoder failed'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ResolvedPlayVideo(
            ownerId: 'play',
            assetId: 'clip',
            resolver: MapPlayVideoAssetResolver({'clip': _video()}),
            posterResolver: MapPlayVideoPosterResolver({'clip': _poster()}),
            coordinator: ActiveMediaCoordinator(),
            controllerFactory: (_) => controller,
          ),
        ),
      );
      await _settle(tester);

      expect(controller.releaseCount, 1);
      expect(find.bySemanticsLabel('Travel clip poster'), findsOneWidget);
      expect(find.byType(PlayVideoUnavailable), findsNothing);
    },
  );

  testWidgets('missing poster falls back to the existing unavailable state', (
    tester,
  ) async {
    final controller = _PosterVideoController(
      initializeError: StateError('decoder failed'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVideo(
          ownerId: 'play',
          assetId: 'clip',
          resolver: MapPlayVideoAssetResolver({'clip': _video()}),
          posterResolver: MapPlayVideoPosterResolver(const {}),
          coordinator: ActiveMediaCoordinator(),
          controllerFactory: (_) => controller,
        ),
      ),
    );
    await _settle(tester);

    expect(find.byType(PlayVideoUnavailable), findsOneWidget);
  });

  testWidgets('poster resolver failure never prevents video playback', (
    tester,
  ) async {
    final controller = _PosterVideoController();
    final posterResolver = CallbackPlayVideoPosterResolver((_) {
      throw StateError('poster lookup failed');
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVideo(
          ownerId: 'play',
          assetId: 'clip',
          resolver: MapPlayVideoAssetResolver({'clip': _video()}),
          posterResolver: posterResolver,
          coordinator: ActiveMediaCoordinator(),
          controllerFactory: (_) => controller,
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('video-frame'), findsOneWidget);
  });
}
