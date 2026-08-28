import 'dart:convert';
import 'dart:io';

import 'package:play_schema/play_schema.dart';
import 'package:test/test.dart';

PlayDocument _fixture(String name) {
  final raw =
      jsonDecode(File('fixtures/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayDocument.fromJson(raw);
}

void main() {
  test('nested input extension data cannot be mutated after decode', () {
    final play = _fixture('move_one_match.json');
    final input = play.states['solve']!.input;
    final origin = input.properties['dragOrigin']! as Map<String, Object?>;
    final targets = input.properties['targets']! as List<Object?>;

    expect(() => origin['x'] = 0.9, throwsUnsupportedError);
    expect(
      () => targets.add({
        'id': 'extra',
        'x': 0.1,
        'y': 0.1,
        'width': 0.1,
        'height': 0.1,
      }),
      throwsUnsupportedError,
    );
  });

  test('validator values and transitions cannot be mutated after decode', () {
    final play = _fixture('play_it_back.json');
    final state = play.states['playback']!;
    final expected = state.validation.value! as List<Object?>;

    expect(() => expected.add('A4'), throwsUnsupportedError);
    expect(() => state.transitions['correct'] = 'playback', throwsUnsupportedError);
  });

  test('state presentation and document collections reject replacement', () {
    final play = _fixture('where_is_this.json');
    final state = play.states['guess']!;

    expect(
      () => state.presentation[0] = PresentationLayer(type: 'text'),
      throwsUnsupportedError,
    );
    expect(() => play.topics[0] = 'mutated', throwsUnsupportedError);
    expect(() => play.states['new'] = state, throwsUnsupportedError);
  });

  test('public constructors defensively own nested semantic collections', () {
    final nestedLayer = <String, Object?>{'weight': 1};
    final layerProperties = <String, Object?>{'nested': nestedLayer};
    final layer = PresentationLayer(
      type: 'canvas',
      role: 'media',
      properties: layerProperties,
    );

    final options = <PlayOption>[
      const PlayOption(id: 'a', label: 'A'),
    ];
    final authoredKeys = <Object?>['C4', 'E4'];
    final inputProperties = <String, Object?>{'keys': authoredKeys};
    final input = PlayInputDefinition(
      type: PlayInputType.pianoKey,
      options: options,
      properties: inputProperties,
    );

    final expected = <Object?>['C4', 'E4'];
    final validation = PlayValidationDefinition(
      type: PlayValidatorType.orderedSequence,
      value: expected,
    );

    final presentation = <PresentationLayer>[layer];
    final transitions = <String, String>{'correct': 'done'};
    final responseDetail = <String, Object?>{
      'meta': <String, Object?>{'score': 1},
    };
    final responses = <String, Map<String, Object?>>{
      'correct': responseDetail,
    };
    final state = PlayStateDefinition(
      presentation: presentation,
      input: input,
      validation: validation,
      transitions: transitions,
      responses: responses,
    );

    final topics = <String>['music'];
    final learningTopics = <String>['ear-training'];
    final assets = <String>['audio_a'];
    final sources = <PlaySource>[
      const PlaySource(url: 'https://example.com/source'),
    ];
    final states = <String, PlayStateDefinition>{'play': state};
    final play = PlayDocument(
      schemaVersion: 1,
      id: 'immutable_direct',
      revisionId: 'rev_1',
      format: PlayFormat.play,
      classification: PlayClassification.challenge,
      topics: topics,
      learningTopics: learningTopics,
      estimatedDurationSec: 10,
      assets: assets,
      sources: sources,
      entryState: 'play',
      states: states,
    );

    nestedLayer['weight'] = 99;
    layerProperties['late'] = true;
    options.add(const PlayOption(id: 'b', label: 'B'));
    authoredKeys.add('G4');
    inputProperties['sequenceLength'] = 3;
    expected.add('G4');
    presentation.clear();
    transitions['correct'] = 'mutated';
    (responseDetail['meta']! as Map<String, Object?>)['score'] = 99;
    responses['late'] = <String, Object?>{'value': true};
    topics.add('mutated');
    learningTopics.clear();
    assets.add('audio_b');
    sources.clear();
    states.clear();

    expect(layer.properties, {
      'nested': {'weight': 1},
    });
    expect(input.options.map((option) => option.id), ['a']);
    expect(input.properties['keys'], ['C4', 'E4']);
    expect(input.properties.containsKey('sequenceLength'), isFalse);
    expect(validation.value, ['C4', 'E4']);
    expect(state.presentation, [same(layer)]);
    expect(state.transitions, {'correct': 'done'});
    expect(state.responses, {
      'correct': {
        'meta': {'score': 1},
      },
    });
    expect(play.topics, ['music']);
    expect(play.learningTopics, ['ear-training']);
    expect(play.assets, ['audio_a']);
    expect(play.sources, hasLength(1));
    expect(play.states, {'play': same(state)});
  });
}
