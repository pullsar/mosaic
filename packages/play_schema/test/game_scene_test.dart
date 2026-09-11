import 'package:play_schema/play_schema.dart';
import 'package:test/test.dart';

void main() {
  test('scene decodes bounded stable objects and targets', () {
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'operator_vertical',
          'semanticLabel': 'Vertical match',
          'shape': 'rounded_rect',
          'x': .32,
          'y': .43,
          'width': .03,
          'height': .14,
          'tone': 'accent',
          'movable': true,
        },
      ],
      'targets': [
        {
          'id': 'left_top_right',
          'semanticLabel': 'Upper right of the left number',
          'x': .195,
          'y': .36,
          'width': .04,
          'height': .14,
        },
      ],
    });

    expect(scene.objects.single.id, 'operator_vertical');
    expect(scene.objects.single.movable, isTrue);
    expect(scene.targets.single.id, 'left_top_right');
  });

  test('scene retains the bounded matchstick appearance', () {
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'match',
          'semanticLabel': 'Match',
          'shape': 'matchstick',
          'x': .2,
          'y': .2,
          'width': .04,
          'height': .2,
          'movable': true,
        },
      ],
      'targets': const [],
    });

    expect(scene.objects.single.shape, GameSceneShape.matchstick);
    expect(scene.toJson()['objects'], [containsPair('shape', 'matchstick')]);
  });

  test('scene rejects duplicate identities and off-stage geometry', () {
    expect(
      () => GameSceneDefinition.fromJson({
        'version': 1,
        'objects': [
          {
            'id': 'piece',
            'semanticLabel': 'Piece',
            'shape': 'circle',
            'x': .9,
            'y': .9,
            'width': .2,
            'height': .2,
          },
        ],
        'targets': const [],
      }),
      throwsFormatException,
    );
    expect(
      () => GameSceneDefinition.fromJson({
        'version': 1,
        'objects': [
          {
            'id': 'piece',
            'semanticLabel': 'Piece',
            'shape': 'circle',
            'x': .1,
            'y': .1,
            'width': .2,
            'height': .2,
          },
          {
            'id': 'piece',
            'semanticLabel': 'Second piece',
            'shape': 'circle',
            'x': .4,
            'y': .1,
            'width': .2,
            'height': .2,
          },
        ],
        'targets': const [],
      }),
      throwsFormatException,
    );
  });

  test('scene samples a bounded cue at its authored timeline position', () {
    final scene = GameSceneDefinition.fromJson({
      'version': 1,
      'objects': [
        {
          'id': 'coin',
          'semanticLabel': 'Coin',
          'shape': 'circle',
          'x': .1,
          'y': .3,
          'width': .1,
          'height': .1,
        },
      ],
      'targets': const [],
      'cues': [
        {
          'id': 'coin_path',
          'objectId': 'coin',
          'durationMs': 1000,
          'keyframes': [
            {'timeMs': 0, 'x': .1, 'y': .3, 'width': .1, 'height': .1},
            {'timeMs': 1000, 'x': .7, 'y': .3, 'width': .1, 'height': .1},
          ],
        },
      ],
    });

    final cue = scene.cueById('coin_path');
    expect(cue, isNotNull);
    expect(cue!.sample(.5).x, closeTo(.4, .0001));
    expect(cue.sample(double.nan).x, .1);
    expect(scene.toJson()['cues'], isA<List<Object?>>());
  });

  test('scene rejects cue frames that cannot form a deterministic path', () {
    expect(
      () => GameSceneDefinition.fromJson({
        'version': 1,
        'objects': [
          {
            'id': 'coin',
            'semanticLabel': 'Coin',
            'shape': 'circle',
            'x': .1,
            'y': .3,
            'width': .1,
            'height': .1,
          },
        ],
        'targets': const [],
        'cues': [
          {
            'id': 'coin_path',
            'objectId': 'coin',
            'durationMs': 1000,
            'keyframes': [
              {'timeMs': 0, 'x': .1, 'y': .3, 'width': .1, 'height': .1},
              {'timeMs': 0, 'x': .7, 'y': .3, 'width': .1, 'height': .1},
            ],
          },
        ],
      }),
      throwsFormatException,
    );
  });

  test('a timed scene declares its dedicated platform capability', () {
    PlayDocument documentWithFlags(List<String> flags) =>
        PlayDocument.fromJson({
          'schemaVersion': 1,
          'id': 'timed_scene',
          'revisionId': 'rev_1',
          'format': 'guess',
          'classification': 'challenge',
          'topics': const <String>[],
          'learningTopics': const <String>[],
          'estimatedDurationSec': 8,
          'assets': const <String>[],
          'sources': const <Object?>[],
          'requiredPlatformFlags': flags,
          'entryState': 'observe',
          'states': {
            'observe': {
              'presentation': {
                'layers': [
                  {
                    'type': 'scene',
                    'role': 'media',
                    'scene': {
                      'version': 1,
                      'objects': [
                        {
                          'id': 'coin',
                          'semanticLabel': 'Coin',
                          'shape': 'circle',
                          'x': .1,
                          'y': .3,
                          'width': .1,
                          'height': .1,
                        },
                      ],
                      'targets': const <Object?>[],
                      'cues': [
                        {
                          'id': 'observe_1',
                          'objectId': 'coin',
                          'durationMs': 300,
                          'keyframes': [
                            {
                              'timeMs': 0,
                              'x': .1,
                              'y': .3,
                              'width': .1,
                              'height': .1,
                            },
                            {
                              'timeMs': 300,
                              'x': .7,
                              'y': .3,
                              'width': .1,
                              'height': .1,
                            },
                          ],
                        },
                      ],
                    },
                  },
                ],
              },
              'input': {
                'type': 'timed_cue',
                'cueId': 'observe_1',
                'cueOrdinal': 1,
                'durationMs': 300,
              },
              'validation': {'type': 'none'},
              'transition': {'default': r'$end'},
            },
          },
        });

    expect(
      const PlaySchemaValidator()
          .validate(documentWithFlags(const <String>[]))
          .map((issue) => issue.code),
      contains('timed_scene_capability'),
    );
    expect(
      const PlaySchemaValidator()
          .validate(documentWithFlags(const ['timed_scene_v1']))
          .map((issue) => issue.code),
      isNot(contains('timed_scene_capability')),
    );
  });

  test('scene layer retains typed scene data in the Play document', () {
    final play = PlayDocument.fromJson({
      'schemaVersion': 1,
      'id': 'scene_play',
      'revisionId': 'rev_1',
      'format': 'solve',
      'classification': 'challenge',
      'topics': [],
      'learningTopics': [],
      'estimatedDurationSec': 10,
      'assets': [],
      'sources': [],
      'entryState': 'move',
      'states': {
        'move': {
          'presentation': {
            'layers': [
              {
                'type': 'scene',
                'role': 'media',
                'scene': {
                  'version': 1,
                  'objects': [
                    {
                      'id': 'piece',
                      'semanticLabel': 'Piece',
                      'shape': 'circle',
                      'x': .2,
                      'y': .2,
                      'width': .2,
                      'height': .2,
                    },
                  ],
                  'targets': [],
                },
              },
            ],
          },
          'input': {'type': 'tap'},
          'validation': {'type': 'none'},
          'transition': {'default': r'$end'},
        },
      },
    });

    final layer = play.states['move']!.presentation.single;
    expect(layer.scene, isNotNull);
    expect(layer.toJson()['scene'], isA<Map<String, Object?>>());
    expect(const PlaySchemaValidator().validate(play), isEmpty);
  });
}
