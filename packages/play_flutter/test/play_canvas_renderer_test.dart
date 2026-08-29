import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

PlayCanvasAsset _fixture(String name) {
  final raw =
      jsonDecode(File('fixtures/canvas/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayCanvasAsset.fromJson(raw);
}

void main() {
  test('canvas asset decodes the versioned managed scene', () {
    final asset = _fixture('puzzle_match_01.json');

    expect(asset.id, 'puzzle_match_01');
    expect(asset.semanticLabel, contains('6 plus 4 equals 4'));
    expect(asset.elements, hasLength(17));
    expect(asset.elements.first, isA<PlayCanvasLine>());
  });

  test('canvas asset rejects unknown schema and element primitives', () {
    expect(
      () => PlayCanvasAsset.fromJson({
        'schemaVersion': 2,
        'id': 'future',
        'elements': [
          {'type': 'line', 'x1': 0, 'y1': 0, 'x2': 1, 'y2': 1},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => PlayCanvasAsset.fromJson({
        'schemaVersion': 1,
        'id': 'bad',
        'elements': [
          {'type': 'shader'},
        ],
      }),
      throwsFormatException,
    );
  });

  test('canvas constructors reject geometry outside normalized bounds', () {
    expect(
      () => PlayCanvasRect(rect: const Rect.fromLTWH(0.9, 0.2, 0.2, 0.2)),
      throwsArgumentError,
    );
    expect(
      () => PlayCanvasCircle(center: const Offset(0.05, 0.05), radius: 0.1),
      throwsArgumentError,
    );
  });

  testWidgets('resolved canvas paints and exposes one semantic image', (
    tester,
  ) async {
    final asset = _fixture('puzzle_match_01.json');

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 400,
          child: ResolvedPlayCanvas(
            assetId: asset.id,
            resolver: MapPlayCanvasAssetResolver({asset.id: asset}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CustomPaint), findsWidgets);
    expect(
      find.bySemanticsLabel('Matchstick equation: 6 plus 4 equals 4'),
      findsOneWidget,
    );
  });

  testWidgets('mismatched canvas asset identity fails closed', (tester) async {
    final wrong = PlayCanvasAsset(
      id: 'other',
      elements: [
        PlayCanvasLine(
          start: const Offset(0.1, 0.1),
          end: const Offset(0.9, 0.9),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayCanvas(
          assetId: 'requested',
          resolver: CallbackPlayCanvasAssetResolver((_) => wrong),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PlayCanvasUnavailable), findsOneWidget);
  });
}
