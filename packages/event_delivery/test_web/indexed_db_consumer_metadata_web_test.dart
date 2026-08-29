import 'package:analytics_contract/analytics_contract.dart';
import 'package:event_delivery/event_delivery.dart';
import 'package:test/test.dart';

String _databaseName() => 'mosaic_consumer_metadata_${secureUuidV4()}';

MosaicEventEnvelope _event(String actorId) => MosaicEventEnvelope(
  eventId: 'evt_consumer_metadata',
  event: MosaicEventName.playStarted,
  occurredAt: DateTime.utc(2026, 8, 29, 15),
  actorId: actorId,
  sessionId: 'session_consumer_metadata',
  playRevisionId: 'rev_consumer_metadata',
);

void main() {
  test('consumer metadata survives reopen without disturbing identity or outbox', () async {
    final name = _databaseName();
    var store = await IndexedDbEventStore.open(databaseName: name);
    try {
      final actor = await store.getOrCreateActorAccess();
      await store.enqueue(_event(actor.actorId));
      await store.writeConsumerMetadata('preferences.v1', '{"interestTopicIds":[]}');
      await store.writeConsumerMetadata('actor_id', 'consumer-shadow-value');
      await store.close();

      store = await IndexedDbEventStore.open(databaseName: name);
      final reopened = await store.getOrCreateActorAccess();
      expect(reopened.actorId, actor.actorId);
      expect(reopened.accessToken, actor.accessToken);
      expect(
        await store.readConsumerMetadata('preferences.v1'),
        '{"interestTopicIds":[]}',
      );
      expect(await store.readConsumerMetadata('actor_id'), 'consumer-shadow-value');
      expect((await store.due()).single.envelope.eventId, 'evt_consumer_metadata');

      await store.deleteConsumerMetadata('preferences.v1');
      expect(await store.readConsumerMetadata('preferences.v1'), isNull);
      expect((await store.getOrCreateActorAccess()).actorId, actor.actorId);
    } finally {
      await store.close();
      await IndexedDbEventStore.deleteDatabase(name);
    }
  });

  test('consumer metadata keys and values are bounded', () async {
    final name = _databaseName();
    final store = await IndexedDbEventStore.open(databaseName: name);
    try {
      expect(
        () => store.writeConsumerMetadata('../actor_id', 'bad'),
        throwsArgumentError,
      );
      expect(
        () => store.writeConsumerMetadata('preferences.v1', 'x' * (256 * 1024 + 1)),
        throwsArgumentError,
      );
    } finally {
      await store.close();
      await IndexedDbEventStore.deleteDatabase(name);
    }
  });
}
