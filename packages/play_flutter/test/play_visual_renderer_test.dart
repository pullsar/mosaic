import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

final class _DeferredResolver implements PlayVisualAssetResolver {
  final Map<String, Completer<PlayVisualAsset?>> requests =
      <String, Completer<PlayVisualAsset?>>{};

  @override
  Future<PlayVisualAsset?> resolve(String assetId) {
    final request = Completer<PlayVisualAsset?>();
    requests[assetId] = request;
    return request.future;
  }
}

Uint8List _pixel() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

void main() {
  test('network visuals require immutable absolute HTTPS sources', () {
    final headers = <String, String>{'Authorization': 'Bearer original'};
    final source = NetworkPlayVisualSource(
      Uri.parse('https://cdn.example.com/visual.png'),
      headers: headers,
    );
    headers['Authorization'] = 'Bearer mutated';

    final provider = source.createImageProvider() as NetworkImage;
    expect(provider.url, 'https://cdn.example.com/visual.png');
    expect(provider.headers?['Authorization'], 'Bearer original');
    expect(
      () => NetworkPlayVisualSource(Uri.parse('http://example.com/a.png')),
      throwsArgumentError,
    );
    expect(
      () => NetworkPlayVisualSource(Uri.parse('/relative.png')),
      throwsArgumentError,
    );
  });

  test('memory visuals defensively own their bytes', () {
    final bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final source = MemoryPlayVisualSource(bytes);
    bytes[0] = 9;

    expect(source.bytes, <int>[1, 2, 3]);
    expect(() => MemoryPlayVisualSource(Uint8List(0)), throwsArgumentError);
  });

  test('visual asset validates positive decode-size hints', () {
    expect(
      () => PlayVisualAsset(
        id: 'visual',
        source: MemoryPlayVisualSource(_pixel()),
        cacheWidth: 0,
      ),
      throwsRangeError,
    );
  });

  testWidgets('resolved memory visual keeps its semantic label', (
    tester,
  ) async {
    final asset = PlayVisualAsset(
      id: 'visual_a',
      semanticLabel: 'Coastal city',
      source: MemoryPlayVisualSource(_pixel()),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVisual(
          assetId: 'visual_a',
          resolver: MapPlayVisualAssetResolver({'visual_a': asset}),
        ),
      ),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.semanticLabel, 'Coastal city');
    expect(image.image, isA<MemoryImage>());
  });

  testWidgets('stale resolution cannot replace the newer visual', (
    tester,
  ) async {
    final resolver = _DeferredResolver();
    final key = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVisual(key: key, assetId: 'old', resolver: resolver),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVisual(key: key, assetId: 'new', resolver: resolver),
      ),
    );

    resolver.requests['new']!.complete(
      PlayVisualAsset(
        id: 'new',
        semanticLabel: 'new visual',
        source: MemoryPlayVisualSource(_pixel()),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<Image>(find.byType(Image)).semanticLabel,
      'new visual',
    );

    resolver.requests['old']!.complete(
      PlayVisualAsset(
        id: 'old',
        semanticLabel: 'old visual',
        source: MemoryPlayVisualSource(_pixel()),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<Image>(find.byType(Image)).semanticLabel,
      'new visual',
    );
  });

  testWidgets('mismatched resolver identity fails closed', (tester) async {
    final resolver = CallbackPlayVisualAssetResolver(
      (_) => PlayVisualAsset(
        id: 'other',
        source: MemoryPlayVisualSource(_pixel()),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVisual(assetId: 'expected', resolver: resolver),
      ),
    );
    await tester.pump();

    expect(find.byType(PlayVisualUnavailable), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
