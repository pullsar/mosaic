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
        if (value is! String)
          throw FormatException('$field must contain strings');
        return value;
      })
      .toList(growable: false);
}

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
  const PresentationLayer({
    required this.type,
    this.role,
    this.value,
    this.assetId,
    this.properties = const {},
  });

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
      properties: Map.unmodifiable(properties),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    if (role != null) 'role': role,
    if (value != null) 'value': value,
    if (assetId != null) 'assetId': assetId,
    ...properties,
  };
}

final class PlayInputDefinition {
  const PlayInputDefinition({
    required this.type,
    this.label,
    this.options = const [],
    this.properties = const {},
  });

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
      properties: Map.unmodifiable(properties),
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
  const PlayValidationDefinition({required this.type, this.value});

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
  const PlayStateDefinition({
    required this.presentation,
    required this.input,
    required this.validation,
    required this.transitions,
    this.responses = const {},
  });

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
        : _map(
            rawResponses,
            'responses',
          ).map((key, value) => MapEntry(key, _map(value, 'responses.$key')));

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
      responses: Map.unmodifiable(responseMap),
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
  const PlayDocument({
    required this.schemaVersion,
    required this.id,
    required this.revisionId,
    required this.format,
    required this.classification,
    required this.topics,
    required this.learningTopics,
    required this.estimatedDurationSec,
    required this.assets,
    required this.sources,
    required this.entryState,
    required this.states,
  });

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
      topics: List.unmodifiable(_strings(json['topics'], 'topics')),
      learningTopics: List.unmodifiable(
        _strings(json['learningTopics'], 'learningTopics'),
      ),
      estimatedDurationSec: json['estimatedDurationSec'] as int,
      assets: List.unmodifiable(_strings(json['assets'], 'assets')),
      sources: rawSources == null
          ? const []
          : (rawSources as List)
                .map((source) => PlaySource.fromJson(_map(source, 'sources[]')))
                .toList(growable: false),
      entryState: json['entryState'] as String,
      states: Map.unmodifiable(
        rawStates.map(
          (key, value) => MapEntry(
            key,
            PlayStateDefinition.fromJson(_map(value, 'states.$key')),
          ),
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
