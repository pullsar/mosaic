import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

const _authoredPalette = <String, Object?>{
  'background': '#102030',
  'foreground': '#F0F0F0',
  'accent': '#FFCC00',
  'muted': '#8090A0',
  'surface': '#405060',
};

const _toneSamplePoints = <String, Offset>{
  'foreground': Offset(0.2, 0.2),
  'muted': Offset(0.8, 0.2),
  'accent': Offset(0.2, 0.8),
  'surface': Offset(0.8, 0.8),
  'background': Offset(0.5, 0.5),
};

typedef _CanvasViewportCase = ({String name, Size viewport});

const _canvasViewportCases = <_CanvasViewportCase>[
  (name: 'phone portrait', viewport: Size(390, 844)),
  (name: 'phone landscape', viewport: Size(844, 390)),
  (name: 'desktop landscape', viewport: Size(1440, 900)),
];

PlayCanvasAsset _fixture(String name) {
  final raw =
      jsonDecode(File('fixtures/canvas/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayCanvasAsset.fromJson(raw);
}

Map<String, Object?> _toneDocument() => {
  'schemaVersion': 1,
  'id': 'tone_canvas',
  'elements': [
    {
      'type': 'rect',
      'x': 0.05,
      'y': 0.05,
      'width': 0.3,
      'height': 0.3,
      'fill': true,
      'tone': 'foreground',
    },
    {
      'type': 'rect',
      'x': 0.65,
      'y': 0.05,
      'width': 0.3,
      'height': 0.3,
      'fill': true,
      'tone': 'muted',
    },
    {
      'type': 'rect',
      'x': 0.05,
      'y': 0.65,
      'width': 0.3,
      'height': 0.3,
      'fill': true,
      'tone': 'accent',
    },
    {
      'type': 'rect',
      'x': 0.65,
      'y': 0.65,
      'width': 0.3,
      'height': 0.3,
      'fill': true,
      'tone': 'surface',
    },
  ],
};

Future<Map<String, Color>> _renderTonePixels(
  WidgetTester tester, {
  required PlayCanvasAsset asset,
  required ThemeData theme,
}) async {
  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Center(
        child: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox.square(
            dimension: 400,
            child: PlayCanvas(asset: asset),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  final paintFinder = find.descendant(
    of: find.byType(PlayCanvas),
    matching: find.byType(CustomPaint),
  );
  expect(paintFinder, findsOneWidget);
  final boundaryRect = tester.getRect(find.byKey(boundaryKey));
  final paintRect = tester.getRect(paintFinder);
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  final capture = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) {
        throw StateError('Canvas image capture returned no pixel data.');
      }
      return (bytes: bytes, height: image.height, width: image.width);
    } finally {
      image.dispose();
    }
  });
  if (capture == null) {
    throw StateError('Canvas image capture did not complete.');
  }
  final colors = <String, Color>{};
  for (final sample in _toneSamplePoints.entries) {
    final globalPoint =
        paintRect.topLeft +
        Offset(
          paintRect.width * sample.value.dx,
          paintRect.height * sample.value.dy,
        );
    final localPoint = globalPoint - boundaryRect.topLeft;
    final x = localPoint.dx.floor().clamp(0, capture.width - 1).toInt();
    final y = localPoint.dy.floor().clamp(0, capture.height - 1).toInt();
    final offset = (y * capture.width + x) * 4;
    colors[sample.key] = Color.fromARGB(
      capture.bytes.getUint8(offset + 3),
      capture.bytes.getUint8(offset),
      capture.bytes.getUint8(offset + 1),
      capture.bytes.getUint8(offset + 2),
    );
  }
  return colors;
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

  group('canvas asset palette validation', () {
    final invalidCases = <({String name, Object? palette})>[
      (name: 'null palette', palette: null),
      (name: 'string palette', palette: '#102030'),
      (name: 'list palette', palette: <Object?>[]),
      (
        name: 'missing role',
        palette: {
          'background': '#102030',
          'foreground': '#F0F0F0',
          'accent': '#FFCC00',
          'muted': '#8090A0',
        },
      ),
      (
        name: 'unknown role',
        palette: {..._authoredPalette, 'highlight': '#FFFFFF'},
      ),
      (
        name: 'short background color',
        palette: {..._authoredPalette, 'background': '#FFF'},
      ),
      (
        name: 'lowercase foreground color',
        palette: {..._authoredPalette, 'foreground': '#abcdef'},
      ),
      (
        name: 'alpha accent color',
        palette: {..._authoredPalette, 'accent': '#FFFFFFFF'},
      ),
      (
        name: 'muted color without hash',
        palette: {..._authoredPalette, 'muted': 'FFFFFF'},
      ),
      (
        name: 'malformed surface color',
        palette: {..._authoredPalette, 'surface': '#GGGGGG'},
      ),
      (
        name: 'identical foreground and background',
        palette: {
          ..._authoredPalette,
          'background': '#FFFFFF',
          'foreground': '#FFFFFF',
          'accent': '#000000',
        },
      ),
      (
        name: 'foreground contrast below 4.5 to 1',
        palette: {
          ..._authoredPalette,
          'background': '#FFFFFF',
          'foreground': '#777777',
          'accent': '#000000',
        },
      ),
      (
        name: 'accent contrast below 3 to 1',
        palette: {
          ..._authoredPalette,
          'background': '#FFFFFF',
          'foreground': '#000000',
          'accent': '#A0A0A0',
        },
      ),
    ];

    for (final invalidCase in invalidCases) {
      test('rejects ${invalidCase.name}', () {
        expect(
          () => PlayCanvasAsset.fromJson({
            ..._toneDocument(),
            'palette': invalidCase.palette,
          }),
          throwsFormatException,
        );
      });
    }
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

  testWidgets('authored palette paints the background and every tone role', (
    tester,
  ) async {
    final sourcePalette = <String, Object?>{..._authoredPalette};
    final asset = PlayCanvasAsset.fromJson({
      ..._toneDocument(),
      'palette': sourcePalette,
    });
    sourcePalette
      ..['background'] = '#FFFFFF'
      ..['foreground'] = '#000000'
      ..['accent'] = '#000000'
      ..['muted'] = '#000000'
      ..['surface'] = '#000000';
    final pixels = await _renderTonePixels(
      tester,
      asset: asset,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFAA00AA)),
      ),
    );

    expect(pixels['background'], const Color(0xFF102030));
    expect(pixels['foreground'], const Color(0xFFF0F0F0));
    expect(pixels['accent'], const Color(0xFFFFCC00));
    expect(pixels['muted'], const Color(0xFF8090A0));
    expect(pixels['surface'], const Color(0xFF405060));
  });

  testWidgets('legacy canvas tones continue to fall back to the theme', (
    tester,
  ) async {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFFAA00AA))
        .copyWith(
          onSurface: const Color(0xFFE0E0E0),
          onSurfaceVariant: const Color(0xFF707080),
          primary: const Color(0xFF00AAFF),
          surfaceContainerHighest: const Color(0xFF303040),
        );
    final pixels = await _renderTonePixels(
      tester,
      asset: PlayCanvasAsset.fromJson(_toneDocument()),
      theme: ThemeData(colorScheme: scheme),
    );

    expect(pixels['foreground'], scheme.onSurface);
    expect(pixels['muted'], scheme.onSurfaceVariant);
    expect(pixels['accent'], scheme.primary);
    expect(pixels['surface'], scheme.surfaceContainerHighest);
  });

  for (final viewportCase in _canvasViewportCases) {
    testWidgets(
      '${viewportCase.name} centers one aspect-stable bounded canvas stage',
      (tester) async {
        tester.view
          ..physicalSize = viewportCase.viewport
          ..devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: PlayCanvas(asset: PlayCanvasAsset.fromJson(_toneDocument())),
          ),
        );

        final paintFinder = find.descendant(
          of: find.byType(PlayCanvas),
          matching: find.byType(CustomPaint),
        );
        expect(paintFinder, findsOneWidget);
        final stageRect = tester.getRect(paintFinder);
        final viewportRect = Offset.zero & viewportCase.viewport;

        expect(stageRect.center.dx, closeTo(viewportRect.center.dx, 0.001));
        expect(stageRect.center.dy, closeTo(viewportRect.center.dy, 0.001));
        expect(stageRect.left, greaterThanOrEqualTo(viewportRect.left));
        expect(stageRect.top, greaterThanOrEqualTo(viewportRect.top));
        expect(stageRect.right, lessThanOrEqualTo(viewportRect.right));
        expect(stageRect.bottom, lessThanOrEqualTo(viewportRect.bottom));
        final maximumWidth = viewportCase.viewport.width < 720
            ? viewportCase.viewport.width
            : 720.0;
        expect(stageRect.width, lessThanOrEqualTo(maximumWidth));
        expect(stageRect.width / stageRect.height, closeTo(4 / 5, 0.000001));
        expect(
          (stageRect.width - maximumWidth).abs() < 0.001 ||
              (stageRect.height - viewportCase.viewport.height).abs() < 0.001,
          isTrue,
          reason: 'the stage must saturate its limiting viewport dimension',
        );
      },
    );
  }

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
