import 'package:play_schema/play_schema.dart';
import 'package:test/test.dart';

void main() {
  test('layer extension metadata cannot override canonical wire fields', () {
    final layer = PresentationLayer(
      type: 'image',
      role: 'media',
      value: 'canonical',
      assetId: 'asset_a',
      properties: {
        'type': 'text',
        'role': 'prompt',
        'value': 'mutated',
        'assetId': 'asset_b',
        'futureHint': true,
      },
    );

    expect(layer.toJson(), {
      'type': 'image',
      'role': 'media',
      'value': 'canonical',
      'assetId': 'asset_a',
      'futureHint': true,
    });
  });

  test('input extension metadata cannot override canonical wire fields', () {
    final input = PlayInputDefinition(
      type: PlayInputType.pianoKey,
      label: 'Play',
      options: const [PlayOption(id: 'a', label: 'A')],
      properties: {
        'type': 'drag',
        'label': 'Wrong',
        'options': <Object?>[],
        'sequenceLength': 1,
      },
    );

    expect(input.toJson(), {
      'type': 'piano_key',
      'label': 'Play',
      'options': [
        {'id': 'a', 'label': 'A'},
      ],
      'sequenceLength': 1,
    });
  });

  test('direct validation list is frozen before round trip', () {
    final expected = <Object?>['C4', 'E4'];
    final validation = PlayValidationDefinition(
      type: PlayValidatorType.orderedSequence,
      value: expected,
    );
    expected.add('G4');

    expect(validation.toJson(), {
      'type': 'ordered_sequence',
      'value': ['C4', 'E4'],
    });
  });
}
