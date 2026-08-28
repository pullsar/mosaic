import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

const _referenceFixtures = <String>[
  'where_is_this.json',
  'four_day_getaway.json',
  'which_piano_key.json',
  'play_it_back.json',
  'move_one_match.json',
  'which_century.json',
];

PlayDocument _fixture(String name) {
  final raw =
      jsonDecode(File('../play_schema/fixtures/$name').readAsStringSync())
          as Map<String, Object?>;
  return PlayDocument.fromJson(raw);
}

int _wordCount(String value) => value
    .trim()
    .split(RegExp(r'\s+'))
    .where((word) => word.isNotEmpty)
    .length;

void main() {
  for (final fixtureName in _referenceFixtures) {
    test('$fixtureName keeps its entry state content-first', () {
      final play = _fixture(fixtureName);
      final entry = play.states[play.entryState]!;
      final primaryText = entry.presentation.where(
        (layer) => layer.role == 'prompt' || layer.role == 'scenario',
      );

      expect(entry.presentation, isNotEmpty);
      expect(entry.presentation.first.role, 'media');
      expect(entry.presentation.first.assetId, isNotNull);
      expect(primaryText.length, lessThanOrEqualTo(1));

      for (final layer in primaryText) {
        final value = layer.value ?? '';
        final limit = layer.role == 'scenario'
            ? MosaicTextBudget.scenarioWords
            : MosaicTextBudget.promptWords;
        expect(
          _wordCount(value),
          lessThanOrEqualTo(limit),
          reason: '$fixtureName ${layer.role} exceeds its publication budget.',
        );
      }
    });
  }
}
