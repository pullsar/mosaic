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

  test('decodes the exact persisted canonical envelope', () {
    final decoded = MosaicEventEnvelope.fromJson({
      'eventId': 'evt_2',
      'event': MosaicEventName.mediaPlayback,
      'version': 1,
      'occurredAt': '2026-08-28T18:00:00.000Z',
      'actorId': 'actor_2',
      'sessionId': 'session_2',
      'feedRequestId': 'feed_1',
      'playRevisionId': 'rev_2',
      'payload': {
        'phase': 'firstFramePainted',
        'videoCodec': 'h264',
        'browser': 'safari',
      },
    });

    expect(decoded.eventId, 'evt_2');
    expect(decoded.occurredAt, DateTime.utc(2026, 8, 28, 18));
    expect(decoded.feedRequestId, 'feed_1');
    expect(decoded.playRevisionId, 'rev_2');
    expect(decoded.payload['browser'], 'safari');
    expect(decoded.toJson()['occurredAt'], '2026-08-28T18:00:00.000Z');
  });

  test('rejects malformed persisted envelopes before delivery', () {
    expect(
      () => MosaicEventEnvelope.fromJson({
        'eventId': '',
        'event': MosaicEventName.playStarted,
        'version': 1,
        'occurredAt': '2026-08-28T18:00:00Z',
        'actorId': 'actor',
        'sessionId': 'session',
        'payload': <String, Object?>{},
      }),
      throwsFormatException,
    );
    expect(
      () => MosaicEventEnvelope.fromJson({
        'eventId': 'evt',
        'event': MosaicEventName.playStarted,
        'version': 0,
        'occurredAt': 'not-a-date',
        'actorId': 'actor',
        'sessionId': 'session',
        'payload': <String, Object?>{},
      }),
      throwsFormatException,
    );
    expect(
      () => MosaicEventEnvelope.fromJson({
        'eventId': 'evt',
        'event': MosaicEventName.playStarted,
        'version': 1,
        'occurredAt': '2026-08-28T18:00:00Z',
        'actorId': 'actor',
        'sessionId': 'session',
        'payload': 'not-an-object',
      }),
      throwsFormatException,
    );
  });
}
