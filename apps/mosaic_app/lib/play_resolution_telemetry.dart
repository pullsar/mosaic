import 'package:analytics_contract/analytics_contract.dart';
import 'package:platform_contracts/platform_contracts.dart';

void recordPlayResolutionTelemetry(
  Telemetry telemetry, {
  required String playId,
  required String outcome,
  required int attempts,
  required bool completed,
  bool? correct,
}) {
  final normalizedPlayId = _boundedText(playId, 'playId');
  final normalizedOutcome = _boundedText(outcome, 'outcome');
  if (attempts < 1 || attempts > 1000) {
    throw ArgumentError.value(attempts, 'attempts', 'must be between 1 and 1000');
  }
  telemetry.event(MosaicEventName.playResolved, <String, Object?>{
    'playId': normalizedPlayId,
    'outcome': normalizedOutcome,
    'attempt': attempts,
    if (correct != null) 'correct': correct,
  });
  if (completed) {
    telemetry.event(MosaicEventName.playCompleted, <String, Object?>{
      'playId': normalizedPlayId,
      'attempts': attempts,
    });
  }
}

String _boundedText(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 200) {
    throw ArgumentError.value(value, name, 'must be 1 to 200 characters');
  }
  return normalized;
}
