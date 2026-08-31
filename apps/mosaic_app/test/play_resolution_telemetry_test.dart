import 'dart:async';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/play_resolution_telemetry.dart';
import 'package:platform_contracts/platform_contracts.dart';

final class _RecordingTelemetry implements Telemetry {
  final events = <({String name, Map<String, Object?> payload})>[];

  @override
  void event(String name, Map<String, Object?> payload) {
    events.add((name: name, payload: Map<String, Object?>.of(payload)));
  }

  @override
  void error(Object error, StackTrace stackTrace, {String? operation}) {}

  @override
  FutureOr<T> trace<T>(String operation, FutureOr<T> Function() body) => body();
}

void main() {
  test('resolution records bounded inspectable outcome and correctness', () {
    final telemetry = _RecordingTelemetry();

    recordPlayResolutionTelemetry(
      telemetry,
      playId: 'play_guess',
      outcome: 'correct',
      attempts: 2,
      completed: false,
      correct: true,
    );

    expect(telemetry.events, hasLength(1));
    expect(telemetry.events.single.name, MosaicEventName.playResolved);
    expect(telemetry.events.single.payload, <String, Object?>{
      'playId': 'play_guess',
      'outcome': 'correct',
      'attempt': 2,
      'correct': true,
    });
  });

  test(
    'terminal resolution also records completion without inventing correctness',
    () {
      final telemetry = _RecordingTelemetry();

      recordPlayResolutionTelemetry(
        telemetry,
        playId: 'play_choose',
        outcome: 'option_a',
        attempts: 1,
        completed: true,
      );

      expect(telemetry.events.map((event) => event.name), <String>[
        MosaicEventName.playResolved,
        MosaicEventName.playCompleted,
      ]);
      expect(telemetry.events.first.payload.containsKey('correct'), isFalse);
      expect(telemetry.events.last.payload, <String, Object?>{
        'playId': 'play_choose',
        'attempts': 1,
      });
    },
  );

  test(
    'invalid identities and impossible attempt counts are dropped safely',
    () {
      final telemetry = _RecordingTelemetry();

      recordPlayResolutionTelemetry(
        telemetry,
        playId: ' ',
        outcome: 'correct',
        attempts: 1,
        completed: true,
      );
      recordPlayResolutionTelemetry(
        telemetry,
        playId: 'play',
        outcome: 'correct',
        attempts: 0,
        completed: true,
      );

      expect(telemetry.events, isEmpty);
    },
  );
}
