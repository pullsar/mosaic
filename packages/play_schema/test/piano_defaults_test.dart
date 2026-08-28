import 'package:play_schema/play_schema.dart';
import 'package:test/test.dart';

PlayDocument _pianoPlay(List<String> expected) => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'piano_defaults',
  'revisionId': 'rev_1',
  'format': 'play',
  'classification': 'challenge',
  'topics': <String>[],
  'learningTopics': <String>[],
  'estimatedDurationSec': 10,
  'assets': <String>[],
  'sources': <Object>[],
  'entryState': 'play',
  'states': {
    'play': {
      'presentation': {
        'layers': [
          {'type': 'text', 'role': 'prompt', 'value': 'Play it.'},
        ],
      },
      'input': {'type': 'piano_key'},
      'validation': {'type': 'ordered_sequence', 'value': expected},
      'transition': {'correct': 'done', 'incorrect': 'done'},
    },
    'done': {
      'presentation': {
        'layers': [
          {'type': 'text', 'role': 'reveal_title', 'value': 'Done'},
        ],
      },
      'input': {'type': 'tap', 'label': 'Done'},
      'validation': {'type': 'none'},
      'transition': {'default': r'$end'},
    },
  },
});

void main() {
  test('canonical default piano surface is stable and publication-visible', () {
    expect(
      MosaicPianoInputDefaults.keys,
      containsAll(<String>['C4', 'C#4', 'B4']),
    );
    expect(MosaicPianoInputDefaults.keys, hasLength(12));
  });

  test('publication rejects notes absent from the default piano surface', () {
    final issues = const PlaySchemaValidator().validate(_pianoPlay(['H4']));

    expect(
      issues.any((issue) => issue.code == 'piano_expected_key_missing'),
      isTrue,
    );
  });

  test('publication accepts ordered notes present on the default surface', () {
    final issues = const PlaySchemaValidator().validate(
      _pianoPlay(<String>['C4', 'E4', 'G4']),
    );

    expect(
      issues.where((issue) => issue.severity == PlayValidationSeverity.error),
      isEmpty,
    );
  });
}
