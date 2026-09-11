import 'dart:convert';

String _sceneId(Object? value, String field) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(value.trim())) {
    throw FormatException('$field must be a bounded identifier.');
  }
  return value.trim();
}

String _sceneText(Object? value, String field) {
  if (value is! String || value.trim().isEmpty || value.trim().length > 160) {
    throw FormatException('$field must be bounded text.');
  }
  return value.trim();
}

double _sceneUnit(Object? value, String field, {bool positive = false}) {
  if (value is! num ||
      !value.isFinite ||
      value < 0 ||
      value > 1 ||
      (positive && value == 0)) {
    throw FormatException('$field must be a normalized coordinate.');
  }
  return value.toDouble();
}

Map<String, Object?> _sceneMap(Object? raw, String field) {
  if (raw is! Map) throw FormatException('$field must be an object.');
  final result = <String, Object?>{};
  for (final entry in raw.entries) {
    if (entry.key is! String)
      throw FormatException('$field keys must be strings.');
    result[entry.key as String] = entry.value;
  }
  return result;
}

enum GameSceneShape { roundedRect, circle, matchstick, cup }

enum GameSceneTone { foreground, muted, accent, surface }

const _maxSceneCueDurationMs = 12000;
const _maxSceneCueKeyframes = 128;

final class GameSceneRect {
  const GameSceneRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  factory GameSceneRect.fromJson(Map<String, Object?> json, String field) {
    final rect = GameSceneRect(
      x: _sceneUnit(json['x'], '$field.x'),
      y: _sceneUnit(json['y'], '$field.y'),
      width: _sceneUnit(json['width'], '$field.width', positive: true),
      height: _sceneUnit(json['height'], '$field.height', positive: true),
    );
    if (rect.x + rect.width > 1 || rect.y + rect.height > 1) {
      throw FormatException('$field must remain inside the scene.');
    }
    return rect;
  }

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };
}

final class GameSceneObject {
  const GameSceneObject({
    required this.id,
    required this.semanticLabel,
    required this.shape,
    required this.rect,
    required this.tone,
    required this.movable,
  });

  final String id;
  final String semanticLabel;
  final GameSceneShape shape;
  final GameSceneRect rect;
  final GameSceneTone tone;
  final bool movable;

  factory GameSceneObject.fromJson(Map<String, Object?> json, int index) {
    final shape = switch (json['shape']) {
      'rounded_rect' => GameSceneShape.roundedRect,
      'circle' => GameSceneShape.circle,
      'matchstick' => GameSceneShape.matchstick,
      'cup' => GameSceneShape.cup,
      _ => throw FormatException('objects[$index].shape is unsupported.'),
    };
    final tone = switch (json['tone']) {
      null || 'foreground' => GameSceneTone.foreground,
      'muted' => GameSceneTone.muted,
      'accent' => GameSceneTone.accent,
      'surface' => GameSceneTone.surface,
      _ => throw FormatException('objects[$index].tone is unsupported.'),
    };
    final movable = json['movable'] ?? false;
    if (movable is! bool)
      throw FormatException('objects[$index].movable must be boolean.');
    return GameSceneObject(
      id: _sceneId(json['id'], 'objects[$index].id'),
      semanticLabel: _sceneText(
        json['semanticLabel'],
        'objects[$index].semanticLabel',
      ),
      shape: shape,
      rect: GameSceneRect.fromJson(json, 'objects[$index]'),
      tone: tone,
      movable: movable,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'semanticLabel': semanticLabel,
    'shape': switch (shape) {
      GameSceneShape.roundedRect => 'rounded_rect',
      GameSceneShape.circle => 'circle',
      GameSceneShape.matchstick => 'matchstick',
      GameSceneShape.cup => 'cup',
    },
    ...rect.toJson(),
    'tone': tone.name,
    if (movable) 'movable': true,
  };
}

final class GameSceneTarget {
  const GameSceneTarget({
    required this.id,
    required this.semanticLabel,
    required this.rect,
  });
  final String id;
  final String semanticLabel;
  final GameSceneRect rect;

  factory GameSceneTarget.fromJson(Map<String, Object?> json, int index) =>
      GameSceneTarget(
        id: _sceneId(json['id'], 'targets[$index].id'),
        semanticLabel: _sceneText(
          json['semanticLabel'],
          'targets[$index].semanticLabel',
        ),
        rect: GameSceneRect.fromJson(json, 'targets[$index]'),
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'semanticLabel': semanticLabel,
    ...rect.toJson(),
  };
}

final class GameSceneCueKeyframe {
  const GameSceneCueKeyframe({required this.timeMs, required this.rect});

  final int timeMs;
  final GameSceneRect rect;

  factory GameSceneCueKeyframe.fromJson(
    Map<String, Object?> json,
    String field,
  ) {
    final timeMs = json['timeMs'];
    if (timeMs is! int || timeMs < 0 || timeMs > _maxSceneCueDurationMs) {
      throw FormatException(
        '$field.timeMs must be a bounded millisecond offset.',
      );
    }
    return GameSceneCueKeyframe(
      timeMs: timeMs,
      rect: GameSceneRect.fromJson(json, field),
    );
  }

  Map<String, Object?> toJson() => {'timeMs': timeMs, ...rect.toJson()};
}

final class GameSceneCue {
  GameSceneCue({
    required this.id,
    required this.objectId,
    required this.durationMs,
    required List<GameSceneCueKeyframe> keyframes,
  }) : keyframes = List.unmodifiable(keyframes) {
    if (durationMs < 1 || durationMs > _maxSceneCueDurationMs) {
      throw ArgumentError(
        'Cue duration must be 1-$_maxSceneCueDurationMs milliseconds.',
      );
    }
    if (this.keyframes.length < 2 ||
        this.keyframes.length > _maxSceneCueKeyframes ||
        this.keyframes.first.timeMs != 0 ||
        this.keyframes.last.timeMs != durationMs) {
      throw ArgumentError(
        'Cue keyframes must start at zero and end at duration.',
      );
    }
    for (var index = 1; index < this.keyframes.length; index += 1) {
      if (this.keyframes[index].timeMs <= this.keyframes[index - 1].timeMs) {
        throw ArgumentError('Cue keyframes must be strictly time ordered.');
      }
    }
  }

  final String id;
  final String objectId;
  final int durationMs;
  final List<GameSceneCueKeyframe> keyframes;

  factory GameSceneCue.fromJson(Map<String, Object?> json, int index) {
    final durationMs = json['durationMs'];
    final rawKeyframes = json['keyframes'];
    if (durationMs is! int || rawKeyframes is! List) {
      throw FormatException('cues[$index] requires durationMs and keyframes.');
    }
    try {
      return GameSceneCue(
        id: _sceneId(json['id'], 'cues[$index].id'),
        objectId: _sceneId(json['objectId'], 'cues[$index].objectId'),
        durationMs: durationMs,
        keyframes: List.generate(
          rawKeyframes.length,
          (keyframeIndex) => GameSceneCueKeyframe.fromJson(
            _sceneMap(
              rawKeyframes[keyframeIndex],
              'cues[$index].keyframes[$keyframeIndex]',
            ),
            'cues[$index].keyframes[$keyframeIndex]',
          ),
        ),
      );
    } on ArgumentError catch (error) {
      throw FormatException(error.message);
    }
  }

  GameSceneRect sample(double progress) {
    if (!progress.isFinite) return keyframes.first.rect;
    final elapsedMs = (progress.clamp(0, 1) * durationMs).round();
    final after = keyframes.indexWhere(
      (keyframe) => keyframe.timeMs >= elapsedMs,
    );
    if (after <= 0) return keyframes.first.rect;
    if (after == -1) return keyframes.last.rect;
    final end = keyframes[after];
    final start = keyframes[after - 1];
    final portion = (elapsedMs - start.timeMs) / (end.timeMs - start.timeMs);
    return GameSceneRect(
      x: start.rect.x + (end.rect.x - start.rect.x) * portion,
      y: start.rect.y + (end.rect.y - start.rect.y) * portion,
      width: start.rect.width + (end.rect.width - start.rect.width) * portion,
      height:
          start.rect.height + (end.rect.height - start.rect.height) * portion,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'objectId': objectId,
    'durationMs': durationMs,
    'keyframes': keyframes.map((keyframe) => keyframe.toJson()).toList(),
  };
}

final class GameSceneDefinition {
  GameSceneDefinition({
    required List<GameSceneObject> objects,
    required List<GameSceneTarget> targets,
    List<GameSceneCue> cues = const [],
  }) : objects = List.unmodifiable(objects),
       targets = List.unmodifiable(targets),
       cues = List.unmodifiable(cues) {
    if (objects.length > 12 || targets.length > 12 || objects.isEmpty) {
      throw ArgumentError(
        'Scenes require 1–12 objects and at most 12 targets.',
      );
    }
    if (objects.map((object) => object.id).toSet().length != objects.length ||
        targets.map((target) => target.id).toSet().length != targets.length) {
      throw ArgumentError(
        'Scene object and target identifiers must be unique.',
      );
    }
    if (this.cues
                .map((cue) => '${cue.id}\u0000${cue.objectId}')
                .toSet()
                .length !=
            this.cues.length ||
        this.cues.fold<int>(0, (total, cue) => total + cue.keyframes.length) >
            _maxSceneCueKeyframes ||
        this.cues.any(
          (cue) => !this.objects.any((object) => object.id == cue.objectId),
        )) {
      throw ArgumentError(
        'Scene cues require unique IDs, real objects, and bounded keyframes.',
      );
    }
  }

  final List<GameSceneObject> objects;
  final List<GameSceneTarget> targets;
  final List<GameSceneCue> cues;

  factory GameSceneDefinition.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1)
      throw const FormatException('Unsupported scene version.');
    final objects = json['objects'];
    final targets = json['targets'];
    if (objects is! List || targets is! List)
      throw const FormatException('Scene requires objects and targets.');
    try {
      final rawCues = json['cues'];
      if (rawCues != null && rawCues is! List) {
        throw const FormatException('Scene cues must be an array.');
      }
      final cueList = rawCues as List?;
      final scene = GameSceneDefinition(
        objects: List.generate(
          objects.length,
          (index) => GameSceneObject.fromJson(
            _sceneMap(objects[index], 'objects[$index]'),
            index,
          ),
        ),
        targets: List.generate(
          targets.length,
          (index) => GameSceneTarget.fromJson(
            _sceneMap(targets[index], 'targets[$index]'),
            index,
          ),
        ),
        cues: cueList == null
            ? const []
            : List.generate(
                cueList.length,
                (index) => GameSceneCue.fromJson(
                  _sceneMap(cueList[index], 'cues[$index]'),
                  index,
                ),
              ),
      );
      if (utf8.encode(jsonEncode(scene.toJson())).length > 64 * 1024) {
        throw const FormatException('Scene exceeds 64 KiB.');
      }
      return scene;
    } on ArgumentError catch (error) {
      throw FormatException(error.message);
    }
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'objects': objects.map((object) => object.toJson()).toList(),
    'targets': targets.map((target) => target.toJson()).toList(),
    if (cues.isNotEmpty) 'cues': cues.map((cue) => cue.toJson()).toList(),
  };

  GameSceneCue? cueById(String? id) {
    if (id == null) return null;
    for (final cue in cues) {
      if (cue.id == id) return cue;
    }
    return null;
  }

  List<GameSceneCue> cuesForId(String? id) => id == null
      ? const <GameSceneCue>[]
      : List.unmodifiable(cues.where((cue) => cue.id == id));
}
