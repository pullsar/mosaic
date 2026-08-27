import 'package:analytics_contract/analytics_contract.dart';
import 'package:test/test.dart';

void main() {
  test('serializes canonical event envelope', () {
    final event = MosaicEventEnvelope(
      eventId: 'evt_1',
      event: MosaicEventName.playStarted,
      occurredAt: DateTime.utc(2026, 8, 27, 18),
      actorId: 'actor_1',
      sessionId: 'session_1',
      playRevisionId: 'rev_1',
    );
    expect(event.toJson()['eventId'], 'evt_1');
    expect(event.toJson()['version'], 1);
    expect(event.toJson()['playRevisionId'], 'rev_1');
  });
}
