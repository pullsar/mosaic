import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

final class _ReferenceVideoController implements PlayVideoController {
  final List<String> events = <String>[];
  final List<bool> muteValues = <bool>[];

  @override
  Future<void> initialize() async => events.add('initialize');

  @override
  Future<void> setMuted(bool muted) async {
    muteValues.add(muted);
    events.add('muted:$muted');
  }

  @override
  Future<void> play() async => events.add('play');

  @override
  Future<void> pause() async => events.add('pause');

  @override
  Future<void> release() async => events.add('release');

  @override
  Widget buildView(BuildContext context) => const ColoredBox(
    color: Colors.black,
    child: Center(child: Text('video-frame')),
  );
}

PlayDocument _playFixture(String name) {
  final raw =
      jsonDecode(File('../play_schema/fixtures/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayDocument.fromJson(raw);
}

PlayVideoAsset _videoFixture(String name) {
  final raw =
      jsonDecode(File('fixtures/video/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayVideoAssetCodec.decode(raw);
}

void main() {
  testWidgets('Where is this renders managed muted video from authored data', (
    tester,
  ) async {
    final play = _playFixture('where_is_this.json');
    final video = _videoFixture('clip_dubrovnik.json');
    final controller = _ReferenceVideoController();
    final media = PlayMediaLayerBuilder(
      ownerId: playMediaOwnerId(play),
      visualResolver: MapPlayVisualAssetResolver(const {}),
      videoResolver: MapPlayVideoAssetResolver({video.id: video}),
      mediaCoordinator: ActiveMediaCoordinator(),
      videoControllerFactory: (_) => controller,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaySurface(play: play, mediaBuilder: media.call),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('Where is this?'), findsOneWidget);
    expect(find.text('video-frame'), findsOneWidget);
    expect(controller.muteValues, [true]);
    expect(controller.events, ['initialize', 'muted:true', 'play']);

    await tester.tap(find.text('Dubrovnik'));
    await tester.pump();
    expect(find.text('Medieval walls wrap the old city.'), findsOneWidget);
  });

  testWidgets('Which century renders managed image bytes from authored data', (
    tester,
  ) async {
    final play = _playFixture('which_century.json');
    final bytes = File('fixtures/images/artwork_01.png').readAsBytesSync();
    final visual = PlayVisualAsset(
      id: 'artwork_01',
      source: MemoryPlayVisualSource(bytes),
      semanticLabel: 'Artwork detail',
      fit: BoxFit.contain,
    );
    final media = PlayMediaLayerBuilder(
      ownerId: playMediaOwnerId(play),
      visualResolver: MapPlayVisualAssetResolver({visual.id: visual}),
      videoResolver: MapPlayVideoAssetResolver(const {}),
      mediaCoordinator: ActiveMediaCoordinator(),
      videoControllerFactory: (_) =>
          throw StateError('Video controller should not be requested.'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaySurface(play: play, mediaBuilder: media.call),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Which century?'), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.semanticLabel, 'Artwork detail');
    expect(image.excludeFromSemantics, isFalse);
    expect(find.byType(PlayVisualUnavailable), findsNothing);

    await tester.tap(find.text('18th'));
    await tester.pump();
    expect(find.text('18th century'), findsOneWidget);
  });

  test('video codec rejects audible autoplay metadata', () {
    expect(
      () => PlayVideoAssetCodec.decode({
        'schemaVersion': 1,
        'id': 'unsafe',
        'autoplay': true,
        'muted': false,
        'source': {
          'type': 'network',
          'uri': 'https://cdn.example.com/unsafe.mp4',
        },
      }),
      throwsFormatException,
    );
  });
}
