import 'dart:convert';
import 'dart:io';

import 'package:play_schema/play_schema.dart';
import 'package:test/test.dart';

Map<String, Object?> _fixture(String path) =>
    jsonDecode(File('fixtures/$path').readAsStringSync())
        as Map<String, Object?>;

void main() {
  const fixtures = [
    'where_is_this.json',
    'four_day_getaway.json',
    'which_piano_key.json',
    'play_it_back.json',
    'move_one_match.json',
    'which_century.json',
    'compat/v1_baseline_guess.json',
  ];

  test(
    'all reference and pinned compatibility fixtures parse and validate',
    () {
      const validator = PlaySchemaValidator();
      for (final fixture in fixtures) {
        final play = PlayDocument.fromJson(_fixture(fixture));
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
    },
  );

  test('M0 capabilities decode a supported Play', () {
    final result = const PlayCompatibilityChecker().decode(
      _fixture('where_is_this.json'),
      PlayCapabilityEnvelope.m0(),
    );
    expect(result, isA<DecodedPlay>());
  });

  test('future schema fails closed without throwing', () {
    final raw = {..._fixture('where_is_this.json'), 'schemaVersion': 2};
    final result = const PlayCompatibilityChecker().decode(
      raw,
      PlayCapabilityEnvelope.m0(),
    );
    expect(result, isA<UnsupportedPlay>());
    final unsupported = result as UnsupportedPlay;
    expect(
      unsupported.decision.status,
      PlayCompatibilityStatus.unsupportedSchema,
    );
    expect(unsupported.decision.missingCapabilities, contains('schema:2'));
  });

  test('future primitive fails closed before enum parsing', () {
    final raw = _fixture('where_is_this.json');
    final states = Map<String, Object?>.from(raw['states']! as Map);
    final guess = Map<String, Object?>.from(states['guess']! as Map);
    states['guess'] = {
      ...guess,
      'input': {
        ...Map<String, Object?>.from(guess['input']! as Map),
        'type': 'future_spin',
      },
    };

    final result = const PlayCompatibilityChecker().decode({
      ...raw,
      'states': states,
    }, PlayCapabilityEnvelope.m0());
    expect(result, isA<UnsupportedPlay>());
    expect(
      (result as UnsupportedPlay).decision.missingCapabilities,
      contains('input:future_spin'),
    );
  });

  test('required platform flag participates in eligibility', () {
    final raw = {
      ..._fixture('where_is_this.json'),
      'requiredPlatformFlags': ['low_latency_audio'],
    };
    final checker = const PlayCompatibilityChecker();

    final unsupported = checker.decode(raw, PlayCapabilityEnvelope.m0());
    expect(unsupported, isA<UnsupportedPlay>());
    expect(
      (unsupported as UnsupportedPlay).decision.missingCapabilities,
      contains('platform:low_latency_audio'),
    );

    final supported = checker.decode(
      raw,
      const PlayCapabilityEnvelope(
        schemaVersions: {1},
        presentationTypes: {'text', 'video_clip'},
        inputTypes: {'tap', 'single_choice'},
        validatorTypes: {'none', 'equals'},
        platformFlags: {'low_latency_audio'},
      ),
    );
    expect(supported, isA<DecodedPlay>());
  });

  test('unknown optional fields remain additive-compatible', () {
    final raw = {
      ..._fixture('where_is_this.json'),
      'futureOptionalMetadata': {'anything': true},
    };
    final result = const PlayCompatibilityChecker().decode(
      raw,
      PlayCapabilityEnvelope.m0(),
    );
    expect(result, isA<DecodedPlay>());
  });

  test('authored input extension properties survive typed round-trip', () {
    final play = PlayDocument.fromJson(_fixture('play_it_back.json'));
    final input = play.states['playback']!.input;

    expect(input.properties['keys'], [
      'C4',
      'D4',
      'E4',
      'F4',
      'G4',
      'A4',
      'B4',
    ]);
    expect(input.properties['sequenceLength'], 3);

    final encoded = play.toJson();
    final states = encoded['states']! as Map<String, Object?>;
    final playback = states['playback']! as Map<String, Object?>;
    final encodedInput = playback['input']! as Map<String, Object?>;
    expect(encodedInput['type'], 'piano_key');
    expect(encodedInput['sequenceLength'], 3);
    expect(encodedInput['keys'], input.properties['keys']);
  });

  test('reserved input fields cannot be overridden by extension properties', () {
    const input = PlayInputDefinition(
      type: PlayInputType.pianoKey,
      label: 'Play',
      properties: {'type': 'drag', 'label': 'Wrong', 'sequenceLength': 3},
    );

    final encoded = input.toJson();
    expect(encoded['type'], 'piano_key');
    expect(encoded['label'], 'Play');
    expect(encoded['sequenceLength'], 3);
  });

  test('malformed raw capability shape returns MalformedPlay', () {
    final raw = {..._fixture('where_is_this.json'), 'states': 'broken'};
    final result = const PlayCompatibilityChecker().decode(
      raw,
      PlayCapabilityEnvelope.m0(),
    );
    expect(result, isA<MalformedPlay>());
  });

  test('capability envelope round-trips deterministically', () {
    const capabilities = PlayCapabilityEnvelope(
      schemaVersions: {1},
      presentationTypes: {'text', 'video_clip'},
      inputTypes: {'tap', 'single_choice'},
      validatorTypes: {'none', 'equals'},
      platformFlags: {'web_video'},
    );
    final decoded = PlayCapabilityEnvelope.fromJson(capabilities.toJson());
    expect(decoded.schemaVersions, capabilities.schemaVersions);
    expect(decoded.presentationTypes, capabilities.presentationTypes);
    expect(decoded.inputTypes, capabilities.inputTypes);
    expect(decoded.validatorTypes, capabilities.validatorTypes);
    expect(decoded.platformFlags, capabilities.platformFlags);
  });

  test('rejects unresolved transitions', () {
    final raw = _fixture('where_is_this.json');
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
    final raw = _fixture('where_is_this.json');
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
