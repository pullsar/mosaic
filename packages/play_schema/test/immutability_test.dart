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
      () => state.presentation[0] = const PresentationLayer(type: 'text'),
      throwsUnsupportedError,
    );
    expect(() => play.topics[0] = 'mutated', throwsUnsupportedError);
    expect(() => play.states['new'] = state, throwsUnsupportedError);
  });
}
