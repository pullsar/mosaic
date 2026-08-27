import 'dart:convert';
import 'dart:io';

import 'package:play_schema/play_schema.dart';
import 'package:test/test.dart';

void main() {
  const fixtures = [
    'where_is_this.json',
    'four_day_getaway.json',
    'which_piano_key.json',
    'play_it_back.json',
    'move_one_match.json',
    'which_century.json',
  ];

  test('all reference fixtures parse and validate', () {
    const validator = PlaySchemaValidator();
    for (final fixture in fixtures) {
      final raw =
          jsonDecode(File('fixtures/$fixture').readAsStringSync())
              as Map<String, Object?>;
      final play = PlayDocument.fromJson(raw);
      final errors = validator
          .validate(play)
          .where((issue) => issue.severity == PlayValidationSeverity.error)
          .toList();
      expect(
        errors,
        isEmpty,
        reason: '$fixture: ${errors.map((e) => e.message)}',
      );
    }
  });

  test('rejects unresolved transitions', () {
    final raw =
        jsonDecode(File('fixtures/where_is_this.json').readAsStringSync())
            as Map<String, Object?>;
    final states = Map<String, Object?>.from(raw['states']! as Map)
      ..['guess'] = {
        ...Map<String, Object?>.from((raw['states']! as Map)['guess']! as Map),
        'transition': {'default': 'missing'},
      };
    final play = PlayDocument.fromJson({...raw, 'states': states});
    final issues = const PlaySchemaValidator().validate(play);
    expect(
      issues.any((issue) => issue.code == 'transition_target_missing'),
      isTrue,
    );
  });

  test('enforces prompt copy budget', () {
    final raw =
        jsonDecode(File('fixtures/where_is_this.json').readAsStringSync())
            as Map<String, Object?>;
    final states = Map<String, Object?>.from(raw['states']! as Map);
    final guess = Map<String, Object?>.from(states['guess']! as Map);
    final presentation = Map<String, Object?>.from(
      guess['presentation']! as Map,
    );
    final layers = (presentation['layers']! as List)
        .map((layer) => Map<String, Object?>.from(layer as Map))
        .toList();
    layers[1] = {
      ...layers[1],
      'value':
          'This prompt deliberately contains far too many words for a consumer Play surface and should never be accepted by publication validation',
    };
    states['guess'] = {
      ...guess,
      'presentation': {...presentation, 'layers': layers},
    };
    final play = PlayDocument.fromJson({...raw, 'states': states});
    final issues = const PlaySchemaValidator().validate(play);
    expect(issues.any((issue) => issue.code == 'copy_budget'), isTrue);
  });
}
