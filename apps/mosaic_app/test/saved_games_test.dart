import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/consumer_api_client.dart';
import 'package:mosaic_app/saved_games.dart';
import 'package:play_schema/play_schema.dart';

ConsumerFeedItem _item(String id) => ConsumerFeedItem.fromJson(
  <String, Object?>{
    'playId': id,
    'revisionId': 'rev_1',
    'sourceBucket': 'curated_fallback',
    'document': <String, Object?>{
      'schemaVersion': 1,
      'id': id,
      'revisionId': 'rev_1',
      'format': 'play',
      'classification': 'challenge',
      'topics': <String>['testing'],
      'learningTopics': <String>[],
      'estimatedDurationSec': 5,
      'assets': <String>[],
      'sources': <Object>[],
      'entryState': 'start',
      'states': <String, Object?>{
        'start': <String, Object?>{
          'presentation': <String, Object?>{
            'layers': <Object?>[
              <String, Object?>{
                'type': 'text',
                'role': 'prompt',
                'value': 'Look closer.',
              },
            ],
          },
          'input': <String, Object?>{'type': 'tap', 'label': 'Done'},
          'validation': <String, Object?>{'type': 'none'},
          'transition': <String, Object?>{'default': '\$end'},
        },
      },
    },
  },
  capabilities: PlayCapabilityEnvelope.m1(),
  compatibilityChecker: const PlayCompatibilityChecker(),
);

void main() {
  testWidgets('Saved opens a retained round', (tester) async {
    final retained = _item('saved_play');
    ConsumerFeedItem? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: SavedGamesPage(
          loadEntries: () async => <SavedGameEntry>[
            SavedGameEntry(
              item: retained,
              updatedAt: DateTime.utc(2026, 9, 11),
            ),
          ],
          onOpen: (item) async => opened = item,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Look closer.'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('saved-game:saved_play')),
    );

    expect(opened?.playId, 'saved_play');
  });

  testWidgets('Saved has a compact empty state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SavedGamesPage(loadEntries: () async => const [])),
    );
    await tester.pumpAndSettle();

    expect(find.text('No saved games'), findsOneWidget);
  });
}
