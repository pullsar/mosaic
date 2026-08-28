enum PlayFormat { guess, choose, solve, play, discover }

enum PlayClassification { fact, opinion, preference, fantasy, challenge }

enum PlayInputType {
  tap,
  singleChoice,
  multipleChoice,
  drag,
  order,
  hotspot,
  textShort,
  draw,
  rhythmTap,
  pianoKey,
  mapPoint,
  recordAudio,
}

enum PlayValidatorType {
  none,
  equals,
  setEquality,
  orderedSequence,
  numericRange,
  coordinateRadius,
  targetRegion,
  scoreThreshold,
  patternComparator,
}

T _enumFromWire<T extends Enum>(List<T> values, Object? raw, String field) {
  if (raw is! String) {
    throw FormatException('$field must be a string');
  }
  final normalized = raw.replaceAll('_', '').toLowerCase();
  for (final value in values) {
    if (value.name.toLowerCase() == normalized) return value;
  }
  throw FormatException('Unsupported $field: $raw');
}

String _wireName(Enum value) {
  final name = value.name;
  final buffer = StringBuffer();
  for (var index = 0; index < name.length; index += 1) {
    final char = name[index];
    if (char.toUpperCase() == char && char.toLowerCase() != char) {
      buffer.write('_');
    }
    buffer.write(char.toLowerCase());
  }
  return buffer.toString();
}

Map<String, Object?> _map(Object? raw, String field) {
  if (raw is! Map) throw FormatException('$field must be an object');
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

List<String> _strings(Object? raw, String field) {
  if (raw == null) return const [];
  if (raw is! List) throw FormatException('$field must be an array');
  return raw
      .map((value) {
        if (value is! String) {
          throw FormatException('$field must contain strings');
        }
        return value;
      })
      .toList(growable: false);
}

Object? _freezeJsonValue(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map(
        (key, nested) => MapEntry(key.toString(), _freezeJsonValue(nested)),
      ),
    );
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeJsonValue));
  }
  return value;
}

Map<String, Object?> _freezeJsonMap(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable(
      value.map((key, nested) => MapEntry(key, _freezeJsonValue(nested))),
    );

Map<String, Map<String, Object?>> _freezeResponseMap(
  Map<String, Map<String, Object?>> value,
) => Map<String, Map<String, Object?>>.unmodifiable(
  value.map(
    (key, response) => MapEntry(key, _freezeJsonMap(response)),
  ),
);

final class PlayOption {
  const PlayOption({required this.id, required this.label, this.assetId});

  final String id;
  final String label;
  final String? assetId;

  factory PlayOption.fromJson(Map<String, Object?> json) => PlayOption(
    id: json['id'] as String,
    label: json['label'] as String,
    assetId: json['assetId'] as String?,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (assetId != null) 'assetId': assetId,
  };
}

final class PresentationLayer {
  PresentationLayer({
    required this.type,
    this.role,
    this.value,
    this.assetId,
    Map<String, Object?> properties = const {},
  }) : properties = _freezeJsonMap(properties);

  final String type;
  final String? role;
  final String? value;
  final String? assetId;
  final Map<String, Object?> properties;

  factory PresentationLayer.fromJson(Map<String, Object?> json) {
    final properties = Map<String, Object?>.from(json)
      ..remove('type')
      ..remove('role')
      ..remove('value')
      ..remove('assetId');
    return PresentationLayer(
      type: json['type'] as String,
      role: json['role'] as String?,
      value: json['value'] as String?,
      assetId: json['assetId'] as String?,
      properties: properties,
    );
  }

  Map<String, Object?> toJson() => {
    ...properties,
    'type': type,
    if (role != null) 'role': role,
    if (value != null) 'value': value,
    if (assetId != null) 'assetId': assetId,
  };
}

final class PlayInputDefinition {
  PlayInputDefinition({
    required this.type,
    this.label,
    List<PlayOption> options = const [],
    Map<String, Object?> properties = const {},
  }) : options = List<PlayOption>.unmodifiable(options),
       properties = _freezeJsonMap(properties);

  final PlayInputType type;
  final String? label;
  final List<PlayOption> options;
  final Map<String, Object?> properties;

  factory PlayInputDefinition.fromJson(Map<String, Object?> json) {
    final rawOptions = json['options'];
    final properties = Map<String, Object?>.from(json)
      ..remove('type')
      ..remove('label')
      ..remove('options');
    return PlayInputDefinition(
      type: _enumFromWire(PlayInputType.values, json['type'], 'input.type'),
      label: json['label'] as String?,
      options: rawOptions == null
          ? const []
          : (rawOptions as List)
                .map(
                  (value) =>
                      PlayOption.fromJson(_map(value, 'input.options[]')),
                )
                .toList(growable: false),
      properties: properties,
    );
  }

  Map<String, Object?> toJson() => {
    ...properties,
    'type': _wireName(type),
    if (label != null) 'label': label,
    if (options.isNotEmpty)
      'options': options.map((option) => option.toJson()).toList(),
  };
}

final class PlayValidationDefinition {
  PlayValidationDefinition({required this.type, Object? value})
    : value = _freezeJsonValue(value);

  final PlayValidatorType type;
  final Object? value;

  factory PlayValidationDefinition.fromJson(Map<String, Object?> json) =>
      PlayValidationDefinition(
        type: _enumFromWire(
          PlayValidatorType.values,
          json['type'],
          'validation.type',
        ),
        value: json['value'],
      );

  Map<String, Object?> toJson() => {
    'type': _wireName(type),
    if (value != null) 'value': value,
  };
}

final class PlayStateDefinition {
  PlayStateDefinition({
    required List<PresentationLayer> presentation,
    required this.input,
    required this.validation,
    required Map<String, String> transitions,
    Map<String, Map<String, Object?>> responses = const {},
  }) : presentation = List<PresentationLayer>.unmodifiable(presentation),
       transitions = Map<String, String>.unmodifiable(transitions),
       responses = _freezeResponseMap(responses);

  final List<PresentationLayer> presentation;
  final PlayInputDefinition input;
  final PlayValidationDefinition validation;
  final Map<String, String> transitions;
  final Map<String, Map<String, Object?>> responses;

  factory PlayStateDefinition.fromJson(Map<String, Object?> json) {
    final presentation = _map(json['presentation'], 'presentation');
    final rawLayers = presentation['layers'];
    if (rawLayers is! List) {
      throw const FormatException('presentation.layers must be an array');
    }
    final transitionMap = _map(json['transition'], 'transition');
    final rawResponses = json['responses'];
    final responseMap = rawResponses == null
        ? const <String, Map<String, Object?>>{}
        : _map(rawResponses, 'responses').map((key, value) {
            final response = _map(value, 'responses.$key');
            return MapEntry(key, response);
          });

    return PlayStateDefinition(
      presentation: rawLayers
          .map(
            (value) => PresentationLayer.fromJson(
              _map(value, 'presentation.layers[]'),
            ),
          )
          .toList(growable: false),
      input: PlayInputDefinition.fromJson(_map(json['input'], 'input')),
      validation: PlayValidationDefinition.fromJson(
        _map(json['validation'], 'validation'),
      ),
      transitions: transitionMap.map((key, value) {
        if (value is! String) {
          throw FormatException('transition.$key must be a string');
        }
        return MapEntry(key, value);
      }),
      responses: responseMap,
    );
  }

  Map<String, Object?> toJson() => {
    'presentation': {
      'layers': presentation.map((layer) => layer.toJson()).toList(),
    },
    'input': input.toJson(),
    'validation': validation.toJson(),
    if (responses.isNotEmpty) 'responses': responses,
    'transition': transitions,
  };
}

final class PlaySource {
  const PlaySource({required this.url, this.title, this.provider});

  final String url;
  final String? title;
  final String? provider;

  factory PlaySource.fromJson(Map<String, Object?> json) => PlaySource(
    url: json['url'] as String,
    title: json['title'] as String?,
    provider: json['provider'] as String?,
  );

  Map<String, Object?> toJson() => {
    'url': url,
    if (title != null) 'title': title,
    if (provider != null) 'provider': provider,
  };
}

final class PlayDocument {
  PlayDocument({
    required this.schemaVersion,
    required this.id,
    required this.revisionId,
    required this.format,
    required this.classification,
    required List<String> topics,
    required List<String> learningTopics,
    required this.estimatedDurationSec,
    required List<String> assets,
    required List<PlaySource> sources,
    required this.entryState,
    required Map<String, PlayStateDefinition> states,
  }) : topics = List<String>.unmodifiable(topics),
       learningTopics = List<String>.unmodifiable(learningTopics),
       assets = List<String>.unmodifiable(assets),
       sources = List<PlaySource>.unmodifiable(sources),
       states = Map<String, PlayStateDefinition>.unmodifiable(states);

  final int schemaVersion;
  final String id;
  final String revisionId;
  final PlayFormat format;
  final PlayClassification classification;
  final List<String> topics;
  final List<String> learningTopics;
  final int estimatedDurationSec;
  final List<String> assets;
  final List<PlaySource> sources;
  final String entryState;
  final Map<String, PlayStateDefinition> states;

  factory PlayDocument.fromJson(Map<String, Object?> json) {
    final rawStates = _map(json['states'], 'states');
    final rawSources = json['sources'];
    return PlayDocument(
      schemaVersion: json['schemaVersion'] as int,
      id: json['id'] as String,
      revisionId: json['revisionId'] as String,
      format: _enumFromWire(PlayFormat.values, json['format'], 'format'),
      classification: _enumFromWire(
        PlayClassification.values,
        json['classification'],
        'classification',
      ),
      topics: _strings(json['topics'], 'topics'),
      learningTopics: _strings(json['learningTopics'], 'learningTopics'),
      estimatedDurationSec: json['estimatedDurationSec'] as int,
      assets: _strings(json['assets'], 'assets'),
      sources: rawSources == null
          ? const []
          : (rawSources as List)
                .map(
                  (source) => PlaySource.fromJson(_map(source, 'sources[]')),
                )
                .toList(growable: false),
      entryState: json['entryState'] as String,
      states: rawStates.map(
        (key, value) => MapEntry(
          key,
          PlayStateDefinition.fromJson(_map(value, 'states.$key')),
        ),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'revisionId': revisionId,
    'format': _wireName(format),
    'classification': _wireName(classification),
    'topics': topics,
    'learningTopics': learningTopics,
    'estimatedDurationSec': estimatedDurationSec,
    'assets': assets,
    'sources': sources.map((source) => source.toJson()).toList(),
    'entryState': entryState,
    'states': states.map((key, value) => MapEntry(key, value.toJson())),
  };
}
