import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

final class _Resolver implements PlayVisualAssetResolver {
  _Resolver({
    required this.assets,
    this.failures = const <String>{},
  });

  final Map<String, PlayVisualAsset?> assets;
  final Set<String> failures;
  final List<String> calls = <String>[];

  @override
  Future<PlayVisualAsset?> resolve(String assetId) {
    calls.add(assetId);
    if (failures.contains(assetId)) {
      return Future<PlayVisualAsset?>.error(
        StateError('failed:$assetId'),
      );
    }
    return Future<PlayVisualAsset?>.value(assets[assetId]);
  }
}

void main() {
  test('decode dimensions and prefetch budgets must be positive', () {
    expect(
      () => PlayVisualAsset(
        id: 'visual_a',
        source: _source(),
        cacheWidth: 0,
      ),
      throwsRangeError,
    );
    expect(
      () => PlayVisualAsset(
        id: 'visual_a',
        source: _source(),
        cacheHeight: -1,
      ),
      throwsRangeError,
    );
    expect(
      () => PlayVisualPrefetchController(
        resolver: MapPlayVisualAssetResolver(const {}),
        maxAssets: 0,
      ),
      throwsRangeError,
    );
    expect(
      () => PlayVisualPrefetchController(
        resolver: MapPlayVisualAssetResolver(const {}),
        maxConcurrent: 0,
      ),
      throwsRangeError,
    );
  });

  test('decode hints wrap the source provider without mutating the source', () {
    final source = _source();
    final asset = PlayVisualAsset(
      id: 'visual_a',
      source: source,
      cacheWidth: 640,
      cacheHeight: 360,
    );

    expect(asset.cacheWidth, 640);
    expect(asset.cacheHeight, 360);
    expect(asset.createImageProvider(), isA<ResizeImage>());
    expect(source.createImageProvider(), isA<MemoryImage>());
  });

  testWidgets('deduplicates, caps and bounds concurrent warmups', (
    tester,
  ) async {
    final context = await _pumpContext(tester);
    final resolver = _Resolver(
      assets: {
        for (final id in const ['a', 'b', 'c', 'd']) id: _asset(id),
      },
    );
    final release = Completer<void>();
    final warmed = <String>[];
    var active = 0;
    var maximumActive = 0;
    final controller = PlayVisualPrefetchController(
      resolver: resolver,
      maxAssets: 3,
      maxConcurrent: 2,
      warmer: (context, asset) async {
        active += 1;
        if (active > maximumActive) maximumActive = active;
        await release.future;
        warmed.add(asset.id);
        active -= 1;
      },
    );

    final pending = controller.prefetch(
      context,
      const ['a', 'a', ' ', 'b', 'c', 'd'],
    );
    await tester.pump();

    expect(maximumActive, 2);
    expect(active, 2);
    release.complete();
    final report = await pending;

    expect(report.requested, 3);
    expect(report.warmed, 3);
    expect(report.missing, 0);
    expect(report.failed, 0);
    expect(report.completed, 3);
    expect(report.superseded, isFalse);
    expect(resolver.calls, ['a', 'b', 'c']);
    expect(warmed.toSet(), {'a', 'b', 'c'});
  });

  testWidgets('reports missing and failed assets while continuing the window', (
    tester,
  ) async {
    final context = await _pumpContext(tester);
    final resolver = _Resolver(
      assets: {
        'missing': null,
        'good': _asset('good'),
      },
      failures: const {'broken'},
    );
    final errors = <String>[];
    final warmed = <String>[];
    final controller = PlayVisualPrefetchController(
      resolver: resolver,
      warmer: (context, asset) async => warmed.add(asset.id),
      onError: (assetId, error, stackTrace) => errors.add(assetId),
    );

    final report = await controller.prefetch(
      context,
      const ['missing', 'broken', 'good'],
    );

    expect(report.requested, 3);
    expect(report.warmed, 1);
    expect(report.missing, 1);
    expect(report.failed, 1);
    expect(report.completed, 3);
    expect(report.superseded, isFalse);
    expect(warmed, ['good']);
    expect(errors, ['broken']);
  });

  testWidgets('a new feed window supersedes queued predecessor work', (
    tester,
  ) async {
    final context = await _pumpContext(tester);
    final resolver = _Resolver(
      assets: {
        for (final id in const ['a', 'b', 'c']) id: _asset(id),
      },
    );
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final started = <String>[];
    final controller = PlayVisualPrefetchController(
      resolver: resolver,
      maxConcurrent: 1,
      warmer: (context, asset) async {
        started.add(asset.id);
        if (asset.id == 'a') {
          firstStarted.complete();
          await releaseFirst.future;
        }
      },
    );

    final predecessor = controller.prefetch(context, const ['a', 'b']);
    await tester.pump();
    await firstStarted.future;

    final successor = controller.prefetch(context, const ['c']);
    await tester.pump();
    releaseFirst.complete();

    final predecessorReport = await predecessor;
    final successorReport = await successor;

    expect(predecessorReport.superseded, isTrue);
    expect(predecessorReport.warmed, 0);
    expect(successorReport.superseded, isFalse);
    expect(successorReport.warmed, 1);
    expect(started, containsAll(<String>['a', 'c']));
    expect(started, isNot(contains('b')));
  });

  testWidgets('explicit cancellation prevents queued successor warmups', (
    tester,
  ) async {
    final context = await _pumpContext(tester);
    final resolver = _Resolver(
      assets: {
        for (final id in const ['a', 'b']) id: _asset(id),
      },
    );
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final started = <String>[];
    final controller = PlayVisualPrefetchController(
      resolver: resolver,
      maxConcurrent: 1,
      warmer: (context, asset) async {
        started.add(asset.id);
        if (asset.id == 'a') {
          firstStarted.complete();
          await releaseFirst.future;
        }
      },
    );

    final pending = controller.prefetch(context, const ['a', 'b']);
    await tester.pump();
    await firstStarted.future;
    controller.cancel();
    releaseFirst.complete();

    final report = await pending;
    expect(report.superseded, isTrue);
    expect(report.warmed, 0);
    expect(started, ['a']);
  });
}

Future<BuildContext> _pumpContext(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (value) {
          context = value;
          return const SizedBox();
        },
      ),
    ),
  );
  return context;
}

PlayVisualAsset _asset(String id) => PlayVisualAsset(
  id: id,
  source: _source(),
  cacheWidth: 320,
  cacheHeight: 180,
);

MemoryPlayVisualSource _source() =>
    MemoryPlayVisualSource(Uint8List.fromList(<int>[1, 2, 3]));
