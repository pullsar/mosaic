import 'dart:convert';
import 'dart:io';

import 'package:play_schema/play_schema.dart';
import 'package:test/test.dart';

const _referenceFixtures = <String>[
  'where_is_this.json',
  'four_day_getaway.json',
  'which_piano_key.json',
  'play_it_back.json',
  'move_one_match.json',
  'which_century.json',
];

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('fixtures/$name').readAsStringSync())
        as Map<String, Object?>;

void main() {
  test('M1 capabilities are an additive superset of M0', () {
    final m0 = PlayCapabilityEnvelope.m0();
    final m1 = PlayCapabilityEnvelope.m1();

    expect(m1.schemaVersions, containsAll(m0.schemaVersions));
    expect(m1.presentationTypes, containsAll(m0.presentationTypes));
    expect(m1.inputTypes, containsAll(m0.inputTypes));
    expect(m1.validatorTypes, containsAll(m0.validatorTypes));
    expect(m1.presentationTypes, contains('canvas'));
    expect(m1.inputTypes, containsAll(['piano_key', 'drag']));
    expect(
      m1.validatorTypes,
      containsAll(['ordered_sequence', 'target_region']),
    );
    expect(m1.platformFlags, isEmpty);
  });

  test('M1 capability filtering admits all six canonical reference Plays', () {
    const checker = PlayCompatibilityChecker();
    final capabilities = PlayCapabilityEnvelope.m1();

    for (final fixtureName in _referenceFixtures) {
      final result = checker.decode(_fixture(fixtureName), capabilities);
      expect(
        result,
        isA<DecodedPlay>(),
        reason: '$fixtureName must be executable by the M1 renderer.',
      );
    }
  });

  test('M0 keeps failing closed for M1-only authored primitives', () {
    const checker = PlayCompatibilityChecker();

    final piano = checker.decode(
      _fixture('play_it_back.json'),
      PlayCapabilityEnvelope.m0(),
    );
    expect(piano, isA<UnsupportedPlay>());
    expect(
      (piano as UnsupportedPlay).decision.missingCapabilities,
      containsAll(['input:piano_key', 'validator:ordered_sequence']),
    );

    final drag = checker.decode(
      _fixture('move_one_match.json'),
      PlayCapabilityEnvelope.m0(),
    );
    expect(drag, isA<UnsupportedPlay>());
    expect(
      (drag as UnsupportedPlay).decision.missingCapabilities,
      containsAll([
        'presentation:canvas',
        'input:drag',
        'validator:target_region',
      ]),
    );
  });
}
