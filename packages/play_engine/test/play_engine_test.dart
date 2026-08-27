import 'dart:convert';
import 'dart:io';

import 'package:play_engine/play_engine.dart';
import 'package:play_schema/play_schema.dart';
import 'package:test/test.dart';

PlayDocument fixture(String name) {
  final raw = jsonDecode(
    File('../play_schema/fixtures/$name').readAsStringSync(),
  ) as Map<String, Object?>;
  return PlayDocument.fromJson(raw);
}

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
}
