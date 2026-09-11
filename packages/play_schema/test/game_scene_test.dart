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
