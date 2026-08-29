import 'dart:io';

import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:local_state/local_state.dart';
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

MosaicEventEnvelope _event() => MosaicEventEnvelope(
  eventId: 'evt_restart',
  event: MosaicEventName.mediaPlayback,
  occurredAt: DateTime.utc(2026, 8, 29, 6),
  actorId: 'actor_restart',
  sessionId: 'session_restart',
  payload: const {'browser': 'none', 'videoCodec': 'h264'},
);

void main() {
  test('offline event survives SQLite reopen and drains when online', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mosaic_event_restart_',
    );
    final path = '${directory.path}${Platform.pathSeparator}state.sqlite3';

    try {
      var store = MosaicLocalStore.open(path);
      var outbox = SqliteEventOutbox(store);
      await outbox.enqueue(_event());
      await outbox.close();
      store.close();

      store = MosaicLocalStore.open(path);
      outbox = SqliteEventOutbox(store);
      final recovered = await outbox.due(now: DateTime.utc(2026, 8, 30));
      expect(recovered.map((queued) => queued.envelope.eventId), [
        'evt_restart',
      ]);

      final transport = _AcceptedTransport();
      final drain = EventDrainController(outbox: outbox, transport: transport);
      final result = await drain.drain(now: DateTime.utc(2026, 8, 30));

      expect(result.delivered, 1);
      expect(transport.calls, 1);
      expect(await outbox.due(now: DateTime.utc(2026, 8, 30)), isEmpty);
      await outbox.close();
      store.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
