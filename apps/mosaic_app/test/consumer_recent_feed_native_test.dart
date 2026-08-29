import 'package:flutter_test/flutter_test.dart';
import 'package:local_state/local_state.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/consumer_local_state_native.dart';
import 'package:play_schema/play_schema.dart';

Map<String, Object?> _canvasPlay() => <String, Object?>{
  'schemaVersion': 1,
  'id': 'play_cached',
  'revisionId': 'rev_cached',
  'format': 'discover',
  'classification': 'fact',
  'topics': <String>['science'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 15,
  'assets': <String>['canvas_asset'],
  'sources': <Object?>[],
  'entryState': 'start',
  'states': <String, Object?>{
    'start': <String, Object?>{
      'presentation': <String, Object?>{
        'layers': <Object?>[
          <String, Object?>{'type': 'canvas', 'assetId': 'canvas_asset'},
        ],
      },
      'input': <String, Object?>{'type': 'tap'},
      'validation': <String, Object?>{'type': 'none'},
      'transition': <String, Object?>{},
    },
  },
};

void main() {
  test(
    'native recovered feed is revalidated against current capabilities',
    () async {
      final store = MosaicLocalStore.openInMemory();
      final state = SqliteConsumerLocalState(store);
      final item = ConsumerFeedItem.fromJson(
        <String, Object?>{
          'playId': 'play_cached',
          'revisionId': 'rev_cached',
          'sourceBucket': 'known',
          'document': _canvasPlay(),
        },
        compatibilityChecker: const PlayCompatibilityChecker(),
        capabilities: PlayCapabilityEnvelope.m1(),
      );

      await state.writeRecentFeed(
        ConsumerFeedCache(
          requestId: 'feed_cached',
          items: <ConsumerFeedItem>[item],
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      final compatible = await state.readRecentFeed(
        capabilities: PlayCapabilityEnvelope.m1(),
      );
      expect(compatible?.requestId, 'feed_cached');
      expect(compatible?.items.single.play.revisionId, 'rev_cached');

      final unsupported = await state.readRecentFeed(
        capabilities: PlayCapabilityEnvelope.m0(),
      );
      expect(unsupported, isNull);
      expect(
        await state.readRecentFeed(capabilities: PlayCapabilityEnvelope.m1()),
        isNull,
      );

      store.close();
    },
  );
}
