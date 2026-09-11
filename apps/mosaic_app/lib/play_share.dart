/// An exact published Play identity carried by a public Mixli link.
final class PlayShareTarget {
  const PlayShareTarget({required this.playId, required this.revisionId});

  final String playId;
  final String revisionId;

  @override
  bool operator ==(Object other) =>
      other is PlayShareTarget &&
      other.playId == playId &&
      other.revisionId == revisionId;

  @override
  int get hashCode => Object.hash(playId, revisionId);
}

/// Builds and parses the single public route for an immutable Play revision.
///
/// The route deliberately has no caller-provided query or return destination.
/// That keeps an external share focused on one published game.
abstract final class PlayShareLink {
  static Uri build({
    required Uri origin,
    required String playId,
    required String revisionId,
  }) {
    final canonicalOrigin = _canonicalOrigin(origin);
    return canonicalOrigin.replace(
      pathSegments: <String>[
        'p',
        _identifier(playId, 'playId'),
        _identifier(revisionId, 'revisionId'),
      ],
    );
  }

  static PlayShareTarget? parse(Uri value, {required Uri origin}) {
    final canonicalOrigin = _canonicalOrigin(origin);
    if (!_sameOrigin(value, canonicalOrigin) ||
        value.hasQuery ||
        value.fragment.isNotEmpty ||
        value.userInfo.isNotEmpty) {
      return null;
    }
    return _parseSegments(value.pathSegments);
  }

  /// Parses a platform-delivered route name, which intentionally has no host.
  static PlayShareTarget? parsePath(String value) {
    final route = Uri.tryParse(value);
    if (route == null ||
        route.scheme.isNotEmpty ||
        route.host.isNotEmpty ||
        route.userInfo.isNotEmpty ||
        route.hasQuery ||
        route.fragment.isNotEmpty) {
      return null;
    }
    return _parseSegments(route.pathSegments);
  }

  static PlayShareTarget? _parseSegments(List<String> segments) {
    if (segments.length != 3 || segments[0] != 'p') return null;
    try {
      return PlayShareTarget(
        playId: _identifier(segments[1], 'playId'),
        revisionId: _identifier(segments[2], 'revisionId'),
      );
    } on FormatException {
      return null;
    }
  }

  static Uri _canonicalOrigin(Uri value) {
    if (value.scheme != 'https' ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.fragment.isNotEmpty ||
        (value.path.isNotEmpty && value.path != '/')) {
      throw ArgumentError.value(value, 'origin', 'must be an HTTPS origin');
    }
    return value.replace(path: '/', query: null, fragment: null);
  }

  static bool _sameOrigin(Uri value, Uri origin) =>
      value.scheme == origin.scheme &&
      value.host == origin.host &&
      value.port == origin.port;
}

String _identifier(String value, String field) {
  final normalized = value.trim();
  if (!RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(normalized)) {
    throw FormatException('$field must be a bounded canonical identifier.');
  }
  return normalized;
}
