import 'dart:convert';

import 'package:event_delivery/event_delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mosaic_app/asset_delivery_client.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/consumer_feed.dart';
import 'package:mosaic_app/consumer_local_state.dart';
import 'package:mosaic_app/consumer_runtime.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

const _actorToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

final class _MemoryConsumerState implements ConsumerLocalState {
  @override
  Future<ConsumerPreferences> readPreferences() async => ConsumerPreferences();

  @override
  Future<void> writePreferences(ConsumerPreferences preferences) async {}

  @override
  Future<bool> readOnboardingCompleted() async => true;

  @override
  Future<void> writeOnboardingCompleted(bool completed) async {}

  @override
  Future<ConsumerFeedResume?> readFeedResume() async => null;

  @override
  Future<void> writeFeedResume(ConsumerFeedResume state) async {}

  @override
  Future<void> clearFeedResume() async {}

  @override
  Future<ConsumerFeedCache?> readRecentFeed({
    required PlayCapabilityEnvelope capabilities,
  }) async => null;

  @override
  Future<void> writeRecentFeed(ConsumerFeedCache state) async {}

  @override
  Future<void> clearRecentFeed() async {}
}

void main() {
  testWidgets('media network failure does not lock vertical paging', (
    tester,
  ) async {
    final feedClient = MockClient((request) async {
      if (request.url.path == '/v1/actors') return http.Response('{}', 201);
      if (request.url.path == '/v1/feed') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'requestId': 'request_media_failure',
            'rankingConfigVersion': 'ranking_test',
            'fallback': false,
            'items': <Object?>[
              _feedItem('play_broken_media'),
              _feedItem('play_after_media'),
            ],
            'nextCursor': null,
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    final runtime = ConsumerRuntime(
      api: ConsumerApiClient(
        baseUri: Uri.parse('https://api.example.test/'),
        actorAccess: ActorAccessIdentity(
          actorId: 'actor_media_failure',
          accessToken: _actorToken,
        ),
        client: feedClient,
      ),
      localState: _MemoryConsumerState(),
      capabilities: PlayCapabilityEnvelope.m1(),
    );
    addTearDown(runtime.close);

    final assetDelivery = AssetDeliveryClient(
      baseUri: Uri.parse('https://api.example.test/'),
      client: MockClient(
        (request) async => request.url.path == '/v1/assets/media_bad'
            ? http.Response('{"error":"temporary"}', 503)
            : http.Response('{}', 404),
      ),
    );
    addTearDown(assetDelivery.close);
    final visualResolver = ManagedVisualAssetResolver(assetDelivery);

    await tester.pumpWidget(
      MaterialApp(
        home: ConsumerFeed(
          runtime: runtime,
          itemBuilder:
              (
                context,
                item, {
                required feedRequestId,
                required active,
                required onDirectManipulationChanged,
              }) => item.playId == 'play_broken_media'
              ? ResolvedPlayVisual(
                  assetId: 'media_bad',
                  resolver: visualResolver,
                )
              : Center(child: Text(item.playId)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Visual unavailable'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('consumer-feed-pager')),
      findsOneWidget,
    );

    await tester.drag(
      find.byKey(const ValueKey<String>('consumer-feed-pager')),
      const Offset(0, -700),
    );
    await tester.pumpAndSettle();

    expect(find.text('play_after_media'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Map<String, Object?> _feedItem(String id) => <String, Object?>{
  'playId': id,
  'revisionId': 'revision_$id',
  'sourceBucket': 'known',
  'document': _play(id),
};

Map<String, Object?> _play(String id) => <String, Object?>{
  'schemaVersion': 1,
  'id': id,
  'revisionId': 'revision_$id',
  'format': 'play',
  'classification': 'challenge',
  'topics': <String>['testing'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 5,
  'assets': <String>[],
  'sources': <Object>[],
  'entryState': 'entry',
  'states': <String, Object?>{
    'entry': <String, Object?>{
      'presentation': <String, Object?>{
        'layers': <Object?>[
          <String, Object?>{'type': 'text', 'role': 'prompt', 'value': id},
        ],
      },
      'input': <String, Object?>{'type': 'tap', 'label': 'Done'},
      'validation': <String, Object?>{'type': 'none'},
      'transition': <String, Object?>{'default': r'$end'},
    },
  },
};
