import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

final class _Layer {
  const _Layer(this.assetId);

  final String? assetId;
}

void main() {
  testWidgets('binds a selected layer asset to the real image renderer', (
    tester,
  ) async {
    final asset = PlayVisualAsset(
      id: 'visual_a',
      semanticLabel: 'Coastal city',
      source: MemoryPlayVisualSource(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      ),
    );
    final builder = PlayVisualMediaBuilder<_Layer>(
      resolver: MapPlayVisualAssetResolver({'visual_a': asset}),
      assetIdOf: (layer) => layer.assetId,
      repaintBoundaryKey: const ValueKey('visual-boundary'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) =>
              builder.call(context, const _Layer('  visual_a  ')),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(ResolvedPlayVisual), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.semanticLabel, 'Coastal city');
    expect(find.byKey(const ValueKey('visual-boundary')), findsOneWidget);
  });

  testWidgets('uses the layer fallback when no asset ID is available', (
    tester,
  ) async {
    final builder = PlayVisualMediaBuilder<_Layer>(
      resolver: MapPlayVisualAssetResolver(const {}),
      assetIdOf: (layer) => layer.assetId,
      fallbackBuilder: (context, layer) =>
          Text('fallback:${layer.assetId ?? 'none'}'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => builder.call(context, const _Layer(null)),
        ),
      ),
    );

    expect(find.text('fallback:none'), findsOneWidget);
    expect(find.byType(ResolvedPlayVisual), findsNothing);
  });

  testWidgets('can opt out of the renderer repaint boundary', (tester) async {
    final builder = PlayVisualMediaBuilder<_Layer>(
      resolver: MapPlayVisualAssetResolver(const {}),
      assetIdOf: (layer) => layer.assetId,
      useRepaintBoundary: false,
      repaintBoundaryKey: const ValueKey('disabled-boundary'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => builder.call(context, const _Layer(null)),
        ),
      ),
    );

    expect(find.byType(PlayVisualUnavailable), findsOneWidget);
    expect(find.byKey(const ValueKey('disabled-boundary')), findsNothing);
  });
}
