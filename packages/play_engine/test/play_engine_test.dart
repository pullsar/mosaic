import 'dart:convert';
import 'dart:io';

import 'package:play_engine/play_engine.dart';
import 'package:play_schema/play_schema.dart';
import 'package:test/test.dart';

PlayDocument fixture(String name) {
  final raw =
      jsonDecode(File('../play_schema/fixtures/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayDocument.fromJson(raw);
}

PlayDocument playWithValidation({
  required String inputType,
  required Map<String, Object?> validation,
}) => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'malformed_validator',
  'revisionId': 'rev_1',
  'format': 'play',
  'classification': 'challenge',
  'topics': <String>[],
  'learningTopics': <String>[],
  'estimatedDurationSec': 10,
  'assets': <String>[],
  'sources': <Object>[],
  'entryState': 'active',
  'states': {
    'active': {
      'presentation': {
        'layers': [
          {'type': 'text', 'role': 'prompt', 'value': 'Try it.'},
        ],
      },
      'input': {'type': inputType},
      'validation': validation,
      'transition': {'correct': r'$end', 'incorrect': r'$end'},
    },
  },
});

void main() {
  const engine = PlayEngine();

  test('resolves factual choice and terminal tap', () {
    var session = engine.start(fixture('where_is_this.json'));
    final answer = engine.apply(session, const ChoiceAction('dubrovnik'));
    expect(answer.wasCorrect, isTrue);
    expect(answer.session.stateId, 'reveal');

    session = answer.session;
    final done = engine.apply(session, const TapAction());
    expect(done.session.ended, isTrue);
  });

  test('branches preference choice without inventing correctness', () {
    final session = engine.start(fixture('four_day_getaway.json'));
    final result = engine.apply(session, const ChoiceAction('marrakech'));
    expect(result.wasCorrect, isNull);
    expect(result.outcome, 'marrakech');
    expect(result.session.stateId, 'marrakech');
  });

  test('validates ordered piano sequence', () {
    final session = engine.start(fixture('play_it_back.json'));
    final result = engine.apply(
      session,
      const SequenceAction(['C4', 'E4', 'G4']),
    );
    expect(result.wasCorrect, isTrue);
    expect(result.session.stateId, 'reveal');
  });

  test('validates typed drag target and rejects unrelated actions', () {
    final session = engine.start(fixture('move_one_match.json'));
    final result = engine.apply(session, const DragAction('solution_a'));

    expect(result.wasCorrect, isTrue);
    expect(result.session.stateId, 'reveal');
    expect(
      () => engine.apply(session, const TapAction()),
      throwsA(isA<StateError>()),
    );
  });

  test('incorrect drag target can stay in the authored solve state', () {
    final session = engine.start(fixture('move_one_match.json'));
    final result = engine.apply(session, const DragAction('miss'));

    expect(result.wasCorrect, isFalse);
    expect(result.outcome, 'incorrect');
    expect(result.session.stateId, 'solve');
  });

  test('unimplemented typed inputs reject arbitrary actions', () {
    final play = PlayDocument.fromJson({
      'schemaVersion': 1,
      'id': 'unsupported_input',
      'revisionId': 'rev_1',
      'format': 'play',
      'classification': 'challenge',
      'topics': <String>[],
      'learningTopics': <String>[],
      'estimatedDurationSec': 10,
      'assets': <String>[],
      'sources': <Object>[],
      'entryState': 'active',
      'states': {
        'active': {
          'presentation': {
            'layers': [
              {'type': 'text', 'role': 'prompt', 'value': 'Order these.'},
            ],
          },
          'input': {'type': 'order'},
          'validation': {'type': 'none'},
          'transition': {'default': r'$end'},
        },
      },
    });
    final session = engine.start(play);

    expect(
      () => engine.apply(session, const TapAction()),
      throwsA(isA<StateError>()),
    );
    expect(
      () => engine.apply(session, const ChoiceAction('anything')),
      throwsA(isA<StateError>()),
    );
  });

  test('malformed ordered-sequence payload fails with a stable engine error', () {
    final session = engine.start(
      playWithValidation(
        inputType: 'piano_key',
        validation: {'type': 'ordered_sequence', 'value': 'C4,E4,G4'},
      ),
    );

    expect(
      () => engine.apply(
        session,
        const SequenceAction(['C4', 'E4', 'G4']),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'ordered_sequence validation payload is malformed.',
        ),
      ),
    );
  });

  test('malformed target-region payload fails with a stable engine error', () {
    final session = engine.start(
      playWithValidation(
        inputType: 'drag',
        validation: {'type': 'target_region', 'value': 42},
      ),
    );

    expect(
      () => engine.apply(session, const DragAction('solution_a')),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'target_region validation payload is malformed.',
        ),
      ),
    );
  });
}
