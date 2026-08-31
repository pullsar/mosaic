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
  final normalizedPlayId = _boundedText(playId);
  final normalizedOutcome = _boundedText(outcome);
  if (normalizedPlayId == null ||
      normalizedOutcome == null ||
      attempts < 1 ||
      attempts > 1000) {
    return;
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

String? _boundedText(String value) {
  final normalized = value.trim();
  return normalized.isEmpty || normalized.length > 200 ? null : normalized;
}
