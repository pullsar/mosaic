import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

void main() {
  test('network visuals require absolute HTTPS URIs', () {
    expect(
      () => NetworkPlayVisualSource(Uri.parse('http://example.com/a')),
      throwsArgumentError,
    );
    expect(
      () => NetworkPlayVisualSource(Uri.parse('/relative/a')),
      throwsArgumentError,
    );
    expect(
      NetworkPlayVisualSource(Uri.parse('https://example.com/a')).uri,
      Uri.parse('https://example.com/a'),
    );
  });

  test('memory visuals defensively copy bytes', () {
    final input = Uint8List.fromList([1, 2, 3]);
    final source = MemoryPlayVisualSource(input);
    input[0] = 9;

    final provider = source.createImageProvider() as MemoryImage;
    expect(provider.bytes, orderedEquals([1, 2, 3]));
  });

  test('map resolver validates keys and returns exact assets', () async {
    final asset = _asset('visual_a', 'Coast');
    expect(
      () => MapPlayVisualAssetResolver({'wrong_key': asset}),
      throwsArgumentError,
    );

    final resolver = MapPlayVisualAssetResolver({'visual_a': asset});
    expect(await resolver.resolve('visual_a'), same(asset));
    expect(await resolver.resolve('visual_b'), isNull);
  });

  testWidgets('resolved memory visual preserves semantic meaning', (
    tester,
  ) async {
    final asset = _asset('visual_a', 'Atlantic coast');
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 100,
          child: ResolvedPlayVisual(
            assetId: 'visual_a',
            resolver: MapPlayVisualAssetResolver({'visual_a': asset}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.semanticLabel, 'Atlantic coast');
    expect(image.fit, BoxFit.cover);
  });

  testWidgets('a stale resolution cannot replace a newer asset', (
    tester,
  ) async {
    final first = Completer<PlayVisualAsset?>();
    final second = Completer<PlayVisualAsset?>();
    final resolver = CallbackPlayVisualAssetResolver(
      (id) => id == 'visual_a' ? first.future : second.future,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVisual(
          key: const ValueKey('visual'),
          assetId: 'visual_a',
          resolver: resolver,
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVisual(
          key: const ValueKey('visual'),
          assetId: 'visual_b',
          resolver: resolver,
        ),
      ),
    );
    first.complete(_asset('visual_a', 'Old visual'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    second.complete(_asset('visual_b', 'Current visual'));
    await tester.pumpAndSettle();
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.semanticLabel, 'Current visual');
  });

  testWidgets('missing or mismatched assets fail closed', (tester) async {
    final resolver = CallbackPlayVisualAssetResolver(
      (_) => _asset('different_id', 'Wrong visual'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ResolvedPlayVisual(
          assetId: 'requested_id',
          resolver: resolver,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('reduced-motion loading state is static', (tester) async {
    final pending = Completer<PlayVisualAsset?>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: ResolvedPlayVisual(
            assetId: 'visual_a',
            resolver: CallbackPlayVisualAssetResolver((_) => pending.future),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

PlayVisualAsset _asset(String id, String label) => PlayVisualAsset(
  id: id,
  semanticLabel: label,
  source: MemoryPlayVisualSource(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  ),
);
