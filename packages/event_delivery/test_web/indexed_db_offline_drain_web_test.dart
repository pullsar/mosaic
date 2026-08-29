import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:test/test.dart';

final class _AcceptedTransport implements EventTransport {
  var calls = 0;

  @override
  Future<EventDeliveryResult> deliver(MosaicEventEnvelope event) async {
    calls += 1;
    return const EventDeliveryResult(
      EventDeliveryDisposition.accepted,
      statusCode: 202,
    );
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('offline event survives IndexedDB reopen and drains when online', () async {
    final name = 'mosaic_event_reload_${secureUuidV4()}';
    var store = await IndexedDbEventStore.open(databaseName: name);

    try {
      await store.enqueue(
        MosaicEventEnvelope(
          eventId: 'evt_reload',
          event: MosaicEventName.mediaPlayback,
          occurredAt: DateTime.utc(2026, 8, 29, 6),
          actorId: 'actor_reload',
          sessionId: 'session_reload',
          payload: const {'browser': 'chrome', 'videoCodec': 'h264'},
        ),
      );
      await store.close();

      store = await IndexedDbEventStore.open(databaseName: name);
      final recovered = await store.due(now: DateTime.utc(2026, 8, 30));
      expect(recovered.map((queued) => queued.envelope.eventId), ['evt_reload']);

      final transport = _AcceptedTransport();
      final drain = EventDrainController(outbox: store, transport: transport);
      final result = await drain.drain(now: DateTime.utc(2026, 8, 30));

      expect(result.delivered, 1);
      expect(transport.calls, 1);
      expect(await store.due(now: DateTime.utc(2026, 8, 30)), isEmpty);
    } finally {
      await store.close();
      await IndexedDbEventStore.deleteDatabase(name);
    }
  });
}
