import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:platform_contracts/platform_contracts.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

final class _Controller implements PlayVideoController {
  _Controller(this.name, this.events);

  final String name;
  final List<String> events;
  var playCount = 0;
  var pauseCount = 0;
  var releaseCount = 0;

  @override
  Future<void> initialize() async => events.add('$name.initialize');

  @override
  Future<void> setMuted(bool muted) async => events.add('$name.mute:$muted');

  @override
  Future<void> play() async {
    playCount += 1;
    events.add('$name.play');
  }

  @override
  Future<void> pause() async {
    pauseCount += 1;
    events.add('$name.pause');
  }

  @override
  Future<void> release() async {
    releaseCount += 1;
    events.add('$name.release');
  }

  @override
  Widget buildView(BuildContext context) => Text('video:$name');
}

PlayDocument _play({
  required String id,
  required String revisionId,
  required String assetId,
}) => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': id,
  'revisionId': revisionId,
  'format': 'guess',
  'classification': 'challenge',
  'topics': <String>[],
  'learningTopics': <String>[],
  'estimatedDurationSec': 10,
  'assets': [assetId],
  'sources': <Object>[],
  'entryState': 'question',
  'states': {
    'question': {
      'presentation': {
        'layers': [
          {'type': 'video_clip', 'role': 'media', 'assetId': assetId},
          {'type': 'text', 'role': 'prompt', 'value': 'Question $id'},
        ],
      },
      'input': {'type': 'tap', 'label': 'Done'},
      'validation': {'type': 'none'},
      'transition': {'default': r'$end'},
    },
  },
});

void main() {
  testWidgets(
    'recycled PlaySurface releases old media before the next revision owns it',
    (tester) async {
      const surfaceKey = ValueKey<String>('recycled-media-surface');
      final events = <String>[];
      final coordinator = ActiveMediaCoordinator();
      final firstController = _Controller('first', events);
      final secondController = _Controller('second', events);
      final first = _play(
        id: 'play_a',
        revisionId: 'rev_1',
        assetId: 'video_a',
      );
      final second = _play(
        id: 'play_b',
        revisionId: 'rev_1',
        assetId: 'video_b',
      );
      final assets = {
        'video_a': PlayVideoAsset(
          id: 'video_a',
          source: NetworkPlayVideoSource(
            Uri.parse('https://cdn.example.com/video_a.mp4'),
          ),
        ),
        'video_b': PlayVideoAsset(
          id: 'video_b',
          source: NetworkPlayVideoSource(
            Uri.parse('https://cdn.example.com/video_b.mp4'),
          ),
        ),
      };

      Widget surface(PlayDocument play) {
        final media = PlayMediaLayerBuilder(
          ownerId: playMediaOwnerId(play),
          visualResolver: MapPlayVisualAssetResolver(const {}),
          videoResolver: MapPlayVideoAssetResolver(assets),
          mediaCoordinator: coordinator,
          videoControllerFactory: (asset) =>
              asset.id == 'video_a' ? firstController : secondController,
        );
        return MaterialApp(
          home: PlaySurface(
            key: surfaceKey,
            play: play,
            mediaBuilder: media.call,
          ),
        );
      }

      await tester.pumpWidget(surface(first));
      await tester.pumpAndSettle();

      expect(firstController.playCount, 1);
      expect(
        coordinator.owns(playMediaOwnerId(first), firstController),
        isTrue,
      );
      expect(find.text('video:first'), findsOneWidget);

      await tester.pumpWidget(surface(second));
      await tester.pumpAndSettle();

      expect(firstController.pauseCount, 1);
      expect(firstController.releaseCount, 1);
      expect(secondController.playCount, 1);
      expect(
        coordinator.owns(playMediaOwnerId(second), secondController),
        isTrue,
      );
      expect(find.text('video:first'), findsNothing);
      expect(find.text('video:second'), findsOneWidget);
      expect(
        events.indexOf('first.release'),
        lessThan(events.indexOf('second.initialize')),
      );
    },
  );
}
