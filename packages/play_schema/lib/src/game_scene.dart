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

enum GameSceneShape { roundedRect, circle }

enum GameSceneTone { foreground, muted, accent, surface }

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
    'shape': shape == GameSceneShape.roundedRect ? 'rounded_rect' : 'circle',
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

final class GameSceneDefinition {
  GameSceneDefinition({
    required List<GameSceneObject> objects,
    required List<GameSceneTarget> targets,
  }) : objects = List.unmodifiable(objects),
       targets = List.unmodifiable(targets) {
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
  }

  final List<GameSceneObject> objects;
  final List<GameSceneTarget> targets;

  factory GameSceneDefinition.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1)
      throw const FormatException('Unsupported scene version.');
    final objects = json['objects'];
    final targets = json['targets'];
    if (objects is! List || targets is! List)
      throw const FormatException('Scene requires objects and targets.');
    try {
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
  };
}
