import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

PlayDocument _playFixture(String name) {
  final raw =
      jsonDecode(File('../play_schema/fixtures/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayDocument.fromJson(raw);
}

PlayCanvasAsset _canvasFixture(String name) {
  final raw =
      jsonDecode(File('fixtures/canvas/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayCanvasAsset.fromJson(raw);
}

void main() {
  test('Four-day getaway entry state leads with authored visual media', () {
    final play = _playFixture('four_day_getaway.json');
    final entry = play.states[play.entryState]!;

    expect(play.revisionId, 'rev_2');
    expect(play.assets, contains('getaway_mood_01'));
    expect(entry.presentation, isNotEmpty);
    expect(entry.presentation.first.type, 'canvas');
    expect(entry.presentation.first.role, 'media');
    expect(entry.presentation.first.assetId, 'getaway_mood_01');
    expect(entry.presentation.where((layer) => layer.type == 'text').length, 1);
  });

  testWidgets('Four-day getaway renders and transitions entirely from data', (
    tester,
  ) async {
    final play = _playFixture('four_day_getaway.json');
    final mood = _canvasFixture('getaway_mood_01.json');
    final media = PlayMediaLayerBuilder(
      ownerId: playMediaOwnerId(play),
      visualResolver: MapPlayVisualAssetResolver(const {}),
      videoResolver: MapPlayVideoAssetResolver(const {}),
      canvasResolver: MapPlayCanvasAssetResolver({mood.id: mood}),
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

    expect(
      find.bySemanticsLabel('Warm walkable city-break mood'),
      findsOneWidget,
    );
    expect(
      find.text('Four days. Cheap food. Warm nights. Lots of walking.'),
      findsOneWidget,
    );
    expect(find.text('Lisbon'), findsOneWidget);
    expect(find.text('Marrakech'), findsOneWidget);

    await tester.tap(find.text('Marrakech'));
    await tester.pump();

    expect(find.text('Marrakech'), findsWidgets);
    expect(find.text('Done'), findsOneWidget);
  });
}
