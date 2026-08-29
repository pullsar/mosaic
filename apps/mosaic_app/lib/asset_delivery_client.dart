import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:event_delivery/event_delivery.dart';
import 'package:http/http.dart' as http;
import 'package:play_flutter/play_flutter.dart';

const _maxAssetIdLength = 200;
const _maxDescriptorBytes = 64 * 1024;
const _maxCanvasBytes = 96 * 1024;

final class AssetDeliveryUnavailableException implements Exception {
  const AssetDeliveryUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'AssetDeliveryUnavailableException: $message';
}

final class AssetDeliveryFormatException implements Exception {
  const AssetDeliveryFormatException(this.message);

  final String message;

  @override
  String toString() => 'AssetDeliveryFormatException: $message';
}

enum ManagedAssetKind { image, video, audio }

final class ManagedAssetObject {
  const ManagedAssetObject({
    required this.variant,
    required this.url,
    required this.mimeType,
    required this.sizeBytes,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.container,
    required this.videoCodec,
    required this.videoProfile,
    required this.audioCodec,
    required this.colorSpace,
    required this.dynamicRange,
  });

  final String variant;
  final String url;
  final String mimeType;
  final int sizeBytes;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? container;
  final String? videoCodec;
  final String? videoProfile;
  final String? audioCodec;
  final String? colorSpace;
  final String? dynamicRange;

  factory ManagedAssetObject.fromJson(
    Map<String, Object?> json, {
    required String expectedVariant,
  }) {
    final variant = _requiredString(json, 'variant', 32);
    if (variant != expectedVariant) {
      throw AssetDeliveryFormatException(
        'Expected $expectedVariant asset variant, received $variant.',
      );
    }
    return ManagedAssetObject(
      variant: variant,
      url: _requiredString(json, 'url', 1024),
      mimeType: _requiredString(json, 'mimeType', 120),
      sizeBytes: _positiveInt(json['sizeBytes'], 'sizeBytes'),
      width: _nullablePositiveInt(json['width'], 'width'),
      height: _nullablePositiveInt(json['height'], 'height'),
      durationMs: _nullableNonNegativeInt(json['durationMs'], 'durationMs'),
      container: _nullableString(json['container'], 'container', 80),
      videoCodec: _nullableString(json['videoCodec'], 'videoCodec', 80),
      videoProfile: _nullableString(json['videoProfile'], 'videoProfile', 80),
      audioCodec: _nullableString(json['audioCodec'], 'audioCodec', 80),
      colorSpace: _nullableString(json['colorSpace'], 'colorSpace', 80),
      dynamicRange: _nullableString(json['dynamicRange'], 'dynamicRange', 16),
    );
  }
}

final class ManagedAssetDescriptor {
  const ManagedAssetDescriptor({
    required this.assetId,
    required this.kind,
    required this.primary,
    required this.poster,
    required this.captions,
  });

  final String assetId;
  final ManagedAssetKind kind;
  final ManagedAssetObject primary;
  final ManagedAssetObject? poster;
  final ManagedAssetObject? captions;

  factory ManagedAssetDescriptor.fromJson(
    Map<String, Object?> json, {
    required String expectedAssetId,
  }) {
    if (json['schemaVersion'] != 1) {
      throw const AssetDeliveryFormatException(
        'Unsupported managed asset descriptor schemaVersion.',
      );
    }
    final assetId = _requiredString(json, 'assetId', _maxAssetIdLength);
    if (assetId != expectedAssetId) {
      throw AssetDeliveryFormatException(
        'Descriptor returned $assetId while resolving $expectedAssetId.',
      );
    }
    final kind = switch (_requiredString(json, 'kind', 16)) {
      'image' => ManagedAssetKind.image,
      'video' => ManagedAssetKind.video,
      'audio' => ManagedAssetKind.audio,
      final value => throw AssetDeliveryFormatException(
        'Unsupported managed asset kind: $value.',
      ),
    };
    return ManagedAssetDescriptor(
      assetId: assetId,
      kind: kind,
      primary: ManagedAssetObject.fromJson(
        _jsonObject(json['primary'], 'primary'),
        expectedVariant: 'primary',
      ),
      poster: _nullableObject(
        json['poster'],
        'poster',
        expectedVariant: 'poster',
      ),
      captions: _nullableObject(
        json['captions'],
        'captions',
        expectedVariant: 'captions',
      ),
    );
  }
}

final class _CacheEntry<T> {
  const _CacheEntry(this.value, this.expiresAt);

  final T value;
  final DateTime expiresAt;
}

final class _RequestEpoch {
  const _RequestEpoch(this.global, this.asset);

  final int global;
  final int asset;
}

final class AssetDeliveryClient {
  AssetDeliveryClient({
    required Uri baseUri,
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration successTtl = const Duration(seconds: 30),
    Duration missingTtl = const Duration(seconds: 5),
    int capacity = 32,
    bool allowInsecureLocalhost = false,
    DateTime Function()? now,
  }) : _policy = ApiHttpPolicy(
         baseUri: baseUri,
         requestTimeout: requestTimeout,
         allowInsecureLocalhost: allowInsecureLocalhost,
       ),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _successTtl = _positiveDuration(successTtl, 'successTtl'),
       _missingTtl = _positiveDuration(missingTtl, 'missingTtl'),
       _capacity = _positiveCapacity(capacity),
       _now = now ?? DateTime.now;

  final ApiHttpPolicy _policy;
  final http.Client _client;
  final bool _ownsClient;
  final Duration _successTtl;
  final Duration _missingTtl;
  final int _capacity;
  final DateTime Function() _now;
  final LinkedHashMap<String, _CacheEntry<ManagedAssetDescriptor?>>
  _descriptorCache = LinkedHashMap();
  final LinkedHashMap<String, _CacheEntry<PlayCanvasAsset?>> _canvasCache =
      LinkedHashMap();
  final Map<String, Future<ManagedAssetDescriptor?>> _descriptorInFlight = {};
  final Map<String, Future<PlayCanvasAsset?>> _canvasInFlight = {};
  final Map<String, int> _assetEpochs = {};
  int _globalEpoch = 0;
  bool _closed = false;

  bool get supportsBinaryNetworkAssets => _policy.baseUri.scheme == 'https';

  int get descriptorCacheSize => _descriptorCache.length;
  int get canvasCacheSize => _canvasCache.length;
  int get inFlightCount => _descriptorInFlight.length + _canvasInFlight.length;

  Future<ManagedAssetDescriptor?> describe(String assetId) {
    final id = _assetId(assetId);
    final cached = _cached(_descriptorCache, id);
    if (cached.$1) return Future.value(cached.$2);
    final existing = _descriptorInFlight[id];
    if (existing != null) return existing;

    final epoch = _requestEpoch(id);
    late final Future<ManagedAssetDescriptor?> request;
    request = _fetchDescriptor(id, epoch).whenComplete(() {
      _removeCurrent(_descriptorInFlight, id, request);
    });
    _descriptorInFlight[id] = request;
    return request;
  }

  Future<PlayCanvasAsset?> resolveCanvas(String assetId) {
    final id = _assetId(assetId);
    final cached = _cached(_canvasCache, id);
    if (cached.$1) return Future.value(cached.$2);
    final existing = _canvasInFlight[id];
    if (existing != null) return existing;

    final epoch = _requestEpoch(id);
    late final Future<PlayCanvasAsset?> request;
    request = _fetchCanvas(id, epoch).whenComplete(() {
      _removeCurrent(_canvasInFlight, id, request);
    });
    _canvasInFlight[id] = request;
    return request;
  }

  Uri contentUri(ManagedAssetObject object) {
    final raw = Uri.tryParse(object.url);
    if (raw == null || raw.hasQuery || raw.hasFragment) {
      throw const AssetDeliveryFormatException(
        'Managed content URL is malformed.',
      );
    }
    final resolved = raw.isAbsolute ? raw : _policy.baseUri.resolveUri(raw);
    if (!_sameOrigin(resolved, _policy.baseUri)) {
      throw const AssetDeliveryFormatException(
        'Managed content URL must remain on the configured API origin.',
      );
    }
    if (resolved.scheme != 'https') {
      throw const AssetDeliveryFormatException(
        'Managed binary content requires HTTPS.',
      );
    }
    return resolved;
  }

  void invalidate(String assetId) {
    final id = _assetId(assetId);
    _assetEpochs[id] = (_assetEpochs[id] ?? 0) + 1;
    _descriptorCache.remove(id);
    _canvasCache.remove(id);
    _detach(_descriptorInFlight, id);
    _detach(_canvasInFlight, id);
  }

  void clear() {
    _globalEpoch += 1;
    _descriptorCache.clear();
    _canvasCache.clear();
    _detachAll(_descriptorInFlight);
    _detachAll(_canvasInFlight);
    _assetEpochs.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    clear();
    if (_ownsClient) _client.close();
  }

  Future<ManagedAssetDescriptor?> _fetchDescriptor(
    String id,
    _RequestEpoch epoch,
  ) async {
    final response = await _get(
      _policy.resolve('v1/assets/${Uri.encodeComponent(id)}'),
    );
    if (response.statusCode == 404) {
      if (_isCurrent(id, epoch)) {
        _remember(_descriptorCache, id, null, _missingTtl);
      }
      return null;
    }
    if (response.statusCode != 200) {
      throw AssetDeliveryUnavailableException(
        'Descriptor request failed with HTTP ${response.statusCode}.',
      );
    }
    if (response.bodyBytes.length > _maxDescriptorBytes) {
      throw const AssetDeliveryFormatException(
        'Managed descriptor is too large.',
      );
    }
    final descriptor = ManagedAssetDescriptor.fromJson(
      _decodeObject(response.bodyBytes, 'managed asset descriptor'),
      expectedAssetId: id,
    );
    if (_isCurrent(id, epoch)) {
      _remember(_descriptorCache, id, descriptor, _successTtl);
    }
    return descriptor;
  }

  Future<PlayCanvasAsset?> _fetchCanvas(String id, _RequestEpoch epoch) async {
    final response = await _get(
      _policy.resolve('v1/canvas-assets/${Uri.encodeComponent(id)}'),
    );
    if (response.statusCode == 404) {
      if (_isCurrent(id, epoch)) {
        _remember(_canvasCache, id, null, _missingTtl);
      }
      return null;
    }
    if (response.statusCode != 200) {
      throw AssetDeliveryUnavailableException(
        'Canvas request failed with HTTP ${response.statusCode}.',
      );
    }
    if (response.bodyBytes.length > _maxCanvasBytes) {
      throw const AssetDeliveryFormatException('Canvas asset is too large.');
    }
    final canvas = PlayCanvasAsset.fromJson(
      _decodeObject(response.bodyBytes, 'canvas asset'),
    );
    if (canvas.id != id) {
      throw AssetDeliveryFormatException(
        'Canvas returned ${canvas.id} while resolving $id.',
      );
    }
    if (_isCurrent(id, epoch)) {
      _remember(_canvasCache, id, canvas, _successTtl);
    }
    return canvas;
  }

  Future<http.Response> _get(Uri uri) async {
    if (_closed) {
      throw const AssetDeliveryUnavailableException(
        'Asset delivery is closed.',
      );
    }
    try {
      return await _client.get(uri).timeout(_policy.requestTimeout);
    } on Object catch (error) {
      throw AssetDeliveryUnavailableException('Asset request failed: $error');
    }
  }

  _RequestEpoch _requestEpoch(String id) =>
      _RequestEpoch(_globalEpoch, _assetEpochs[id] ?? 0);

  bool _isCurrent(String id, _RequestEpoch epoch) =>
      !_closed &&
      epoch.global == _globalEpoch &&
      epoch.asset == (_assetEpochs[id] ?? 0);

  (bool, T?) _cached<T>(
    LinkedHashMap<String, _CacheEntry<T>> cache,
    String id,
  ) {
    final entry = cache.remove(id);
    if (entry == null) return (false, null);
    if (!entry.expiresAt.isAfter(_now())) return (false, null);
    cache[id] = entry;
    return (true, entry.value);
  }

  void _remember<T>(
    LinkedHashMap<String, _CacheEntry<T>> cache,
    String id,
    T value,
    Duration ttl,
  ) {
    cache.remove(id);
    cache[id] = _CacheEntry(value, _now().add(ttl));
    while (cache.length > _capacity) {
      cache.remove(cache.keys.first);
    }
  }

  void _removeCurrent<T>(
    Map<String, Future<T>> map,
    String id,
    Future<T> current,
  ) {
    final stored = map[id];
    if (identical(stored, current)) {
      final removed = map.remove(id);
      assert(identical(removed, current));
    }
  }

  void _detach<T>(Map<String, Future<T>> map, String id) {
    final detached = map.remove(id);
    if (detached != null)
      unawaited(detached.then<void>((_) {}, onError: (_, __) {}));
  }

  void _detachAll<T>(Map<String, Future<T>> map) {
    final detached = map.values.toList(growable: false);
    map.clear();
    for (final future in detached) {
      unawaited(future.then<void>((_) {}, onError: (_, __) {}));
    }
  }
}

final class ManagedVisualAssetResolver implements PlayVisualAssetResolver {
  const ManagedVisualAssetResolver(this.client);

  final AssetDeliveryClient client;

  @override
  Future<PlayVisualAsset?> resolve(String assetId) async {
    if (!client.supportsBinaryNetworkAssets) return null;
    final descriptor = await client.describe(assetId);
    if (descriptor == null) return null;
    _requireKind(descriptor, ManagedAssetKind.image);
    _requireMime(descriptor.primary, 'image/jpeg');
    return PlayVisualAsset(
      id: descriptor.assetId,
      source: NetworkPlayVisualSource(client.contentUri(descriptor.primary)),
    );
  }
}

final class ManagedVideoAssetResolver implements PlayVideoAssetResolver {
  const ManagedVideoAssetResolver(this.client);

  final AssetDeliveryClient client;

  @override
  Future<PlayVideoAsset?> resolve(String assetId) async {
    if (!client.supportsBinaryNetworkAssets) return null;
    final descriptor = await client.describe(assetId);
    if (descriptor == null) return null;
    _requireKind(descriptor, ManagedAssetKind.video);
    final primary = descriptor.primary;
    _requireMime(primary, 'video/mp4');
    final format = _videoFormat(primary);
    return PlayVideoAsset(
      id: descriptor.assetId,
      source: NetworkPlayVideoSource(client.contentUri(primary)),
      autoplay: true,
      muted: true,
      format: format,
    );
  }
}

final class ManagedVideoPosterResolver implements PlayVideoPosterResolver {
  const ManagedVideoPosterResolver(this.client);

  final AssetDeliveryClient client;

  @override
  Future<PlayVisualAsset?> resolvePoster(String videoAssetId) async {
    if (!client.supportsBinaryNetworkAssets) return null;
    final descriptor = await client.describe(videoAssetId);
    if (descriptor == null) return null;
    _requireKind(descriptor, ManagedAssetKind.video);
    final poster = descriptor.poster;
    if (poster == null) return null;
    _requireMime(poster, 'image/jpeg');
    return PlayVisualAsset(
      id: '${descriptor.assetId}:poster',
      source: NetworkPlayVisualSource(client.contentUri(poster)),
    );
  }
}

final class ManagedAudioAssetResolver implements PlayAudioAssetResolver {
  const ManagedAudioAssetResolver(this.client);

  final AssetDeliveryClient client;

  @override
  Future<PlayAudioAsset?> resolve(String assetId) async {
    if (!client.supportsBinaryNetworkAssets) return null;
    final descriptor = await client.describe(assetId);
    if (descriptor == null) return null;
    _requireKind(descriptor, ManagedAssetKind.audio);
    _requireMime(descriptor.primary, 'audio/mp4');
    return PlayAudioAsset(
      id: descriptor.assetId,
      uri: client.contentUri(descriptor.primary),
    );
  }
}

final class ManagedCanvasAssetResolver implements PlayCanvasAssetResolver {
  const ManagedCanvasAssetResolver(this.client);

  final AssetDeliveryClient client;

  @override
  Future<PlayCanvasAsset?> resolve(String assetId) =>
      client.resolveCanvas(assetId);
}

PlayVideoFormatMetadata? _videoFormat(ManagedAssetObject object) {
  if (object.container == null &&
      object.videoCodec == null &&
      object.videoProfile == null &&
      object.audioCodec == null) {
    return null;
  }
  return PlayVideoFormatMetadata(
    container: object.container,
    videoCodec: object.videoCodec,
    videoProfile: object.videoProfile,
    audioCodec: object.audioCodec,
  );
}

void _requireKind(
  ManagedAssetDescriptor descriptor,
  ManagedAssetKind expected,
) {
  if (descriptor.kind != expected) {
    throw AssetDeliveryFormatException(
      'Asset ${descriptor.assetId} is ${descriptor.kind.name}, not ${expected.name}.',
    );
  }
}

void _requireMime(ManagedAssetObject object, String expected) {
  if (object.mimeType != expected) {
    throw AssetDeliveryFormatException(
      'Managed ${object.variant} MIME ${object.mimeType} does not match $expected.',
    );
  }
}

ManagedAssetObject? _nullableObject(
  Object? value,
  String field, {
  required String expectedVariant,
}) {
  if (value == null) return null;
  return ManagedAssetObject.fromJson(
    _jsonObject(value, field),
    expectedVariant: expectedVariant,
  );
}

Map<String, Object?> _decodeObject(List<int> bytes, String field) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    return _jsonObject(decoded, field);
  } on AssetDeliveryFormatException {
    rethrow;
  } on Object catch (error) {
    throw AssetDeliveryFormatException('$field is invalid JSON: $error');
  }
}

Map<String, Object?> _jsonObject(Object? value, String field) {
  if (value is! Map) {
    throw AssetDeliveryFormatException('$field must be an object.');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw AssetDeliveryFormatException('$field must contain string keys.');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _requiredString(Map<String, Object?> json, String key, int maxLength) {
  final value = json[key];
  if (value is! String) {
    throw AssetDeliveryFormatException('$key must be a string.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) {
    throw AssetDeliveryFormatException(
      '$key must be between 1 and $maxLength characters.',
    );
  }
  return normalized;
}

String? _nullableString(Object? value, String field, int maxLength) {
  if (value == null) return null;
  if (value is! String) {
    throw AssetDeliveryFormatException('$field must be a string or null.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) {
    throw AssetDeliveryFormatException(
      '$field must be between 1 and $maxLength characters when present.',
    );
  }
  return normalized;
}

int _positiveInt(Object? value, String field) {
  if (value is! int || value < 1) {
    throw AssetDeliveryFormatException('$field must be a positive integer.');
  }
  return value;
}

int? _nullablePositiveInt(Object? value, String field) {
  if (value == null) return null;
  return _positiveInt(value, field);
}

int? _nullableNonNegativeInt(Object? value, String field) {
  if (value == null) return null;
  if (value is! int || value < 0) {
    throw AssetDeliveryFormatException(
      '$field must be a non-negative integer or null.',
    );
  }
  return value;
}

String _assetId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > _maxAssetIdLength) {
    throw ArgumentError.value(
      value,
      'assetId',
      'must be 1 to $_maxAssetIdLength characters',
    );
  }
  return normalized;
}

Duration _positiveDuration(Duration value, String field) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, field, 'must be positive');
  }
  return value;
}

int _positiveCapacity(int value) {
  if (value < 1 || value > 256) {
    throw RangeError.range(value, 1, 256, 'capacity');
  }
  return value;
}

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme == right.scheme &&
    left.host == right.host &&
    left.port == right.port;
