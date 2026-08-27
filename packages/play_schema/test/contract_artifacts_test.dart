import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Play and capability contract artifacts are valid JSON', () {
    final playSchema = jsonDecode(
      File('../../contracts/play-v1.schema.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final capabilitySchema = jsonDecode(
      File('../../contracts/client-capabilities-v1.schema.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;

    expect(playSchema[r'$schema'], 'https://json-schema.org/draft/2020-12/schema');
    expect(
      (playSchema['properties'] as Map)['schemaVersion'],
      containsPair('const', 1),
    );
    expect(
      capabilitySchema['required'],
      containsAll([
        'schemaVersions',
        'presentationTypes',
        'inputTypes',
        'validatorTypes',
        'platformFlags',
      ]),
    );
  });
}
