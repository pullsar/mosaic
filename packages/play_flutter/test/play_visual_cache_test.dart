import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

final class _ControllableResolver implements PlayVisualAssetResolver {
  int calls = 0;
  final Queue<Completer<PlayVisualAsset?>> requests =
      Queue<Completer<PlayVisualAsset?>>();

  @override
  Future<PlayVisualAsset?> resolve(String assetId) {
    calls += 1;
    final request = Completer<PlayVisualAsset?>();
    requests.add(request);
    return request.future;
  }
}

final class _CountingResolver implements PlayVisualAssetResolver {
  _CountingResolver(this.assets);

  final Map<String, PlayVisualAsset?> assets;
  final Map<String, int> calls = <String, int>{};

  @override
  Future<PlayVisualAsset?> resolve(String assetId) async {
    calls.update(assetId, (value) => value + 1, ifAbsent: () => 1);
    return assets[assetId];
  }
}

void main() {
  test('capacity must be positive', () {
    expect(
      () => CachingPlayVisualAssetResolver(
        MapPlayVisualAssetResolver(const {}),
        capacity: 0,
      ),
      throwsRangeError,
    );
  });

  test('coalesces concurrent requests for the same asset', () async {
    final delegate = _ControllableResolver();
    final resolver = CachingPlayVisualAssetResolver(delegate);

    final first = resolver.resolve('visual_a');
    final second = resolver.resolve('visual_a');

    expect(identical(first, second), isTrue);
    expect(delegate.calls, 1);
    expect(resolver.inFlightCount, 1);

    final asset = _asset('visual_a');
    delegate.requests.removeFirst().complete(asset);
    expect(await first, same(asset));
    expect(await second, same(asset));
    expect(resolver.inFlightCount, 0);
    expect(resolver.cacheSize, 1);
  });

  test('uses least-recently-used eviction', () async {
    final delegate = _CountingResolver({
      'visual_a': _asset('visual_a'),
      'visual_b': _asset('visual_b'),
      'visual_c': _asset('visual_c'),
    });
    final resolver = CachingPlayVisualAssetResolver(delegate, capacity: 2);

    await resolver.resolve('visual_a');
    await resolver.resolve('visual_b');
    await resolver.resolve('visual_a');
    await resolver.resolve('visual_c');
    await resolver.resolve('visual_b');

    expect(delegate.calls['visual_a'], 1);
    expect(delegate.calls['visual_b'], 2);
    expect(delegate.calls['visual_c'], 1);
    expect(resolver.cacheSize, 2);
  });

  test('caches missing assets but never caches failures', () async {
    final missing = _CountingResolver({'missing': null});
    final resolver = CachingPlayVisualAssetResolver(missing);

    expect(await resolver.resolve('missing'), isNull);
    expect(await resolver.resolve('missing'), isNull);
    expect(missing.calls['missing'], 1);

    var failures = 0;
    final failing = CachingPlayVisualAssetResolver(
      CallbackPlayVisualAssetResolver((_) {
        failures += 1;
        throw StateError('load failed');
      }),
    );
    await expectLater(failing.resolve('broken'), throwsStateError);
    await expectLater(failing.resolve('broken'), throwsStateError);
    expect(failures, 2);
  });

  test(
    'invalidation prevents stale completion from repopulating cache',
    () async {
      final delegate = _ControllableResolver();
      final resolver = CachingPlayVisualAssetResolver(delegate);

      final stale = resolver.resolve('visual_a');
      resolver.invalidate('visual_a');
      final fresh = resolver.resolve('visual_a');
      expect(delegate.calls, 2);

      final staleAsset = _asset('visual_a', label: 'stale');
      final freshAsset = _asset('visual_a', label: 'fresh');
      delegate.requests.removeFirst().complete(staleAsset);
      delegate.requests.removeFirst().complete(freshAsset);

      expect(await stale, same(staleAsset));
      expect(await fresh, same(freshAsset));
      expect(await resolver.resolve('visual_a'), same(freshAsset));
      expect(delegate.calls, 2);
    },
  );

  test('clear detaches every in-flight request and cache entry', () async {
    final delegate = _ControllableResolver();
    final resolver = CachingPlayVisualAssetResolver(delegate);

    final stale = resolver.resolve('visual_a');
    resolver.clear();
    final fresh = resolver.resolve('visual_a');
    expect(delegate.calls, 2);

    delegate.requests.removeFirst().complete(_asset('visual_a'));
    final freshAsset = _asset('visual_a', label: 'fresh');
    delegate.requests.removeFirst().complete(freshAsset);
    await stale;
    expect(await fresh, same(freshAsset));
    expect(await resolver.resolve('visual_a'), same(freshAsset));
  });

  test('rejects a mismatched delegated asset and does not cache it', () async {
    var calls = 0;
    final resolver = CachingPlayVisualAssetResolver(
      CallbackPlayVisualAssetResolver((_) {
        calls += 1;
        return _asset('wrong_id');
      }),
    );

    await expectLater(resolver.resolve('expected'), throwsStateError);
    await expectLater(resolver.resolve('expected'), throwsStateError);
    expect(calls, 2);
  });
}

PlayVisualAsset _asset(String id, {String? label}) => PlayVisualAsset(
  id: id,
  semanticLabel: label,
  source: MemoryPlayVisualSource(Uint8List.fromList(<int>[1, 2, 3])),
);
