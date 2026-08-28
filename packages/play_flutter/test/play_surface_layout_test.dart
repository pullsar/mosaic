import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';
import 'package:play_schema/play_schema.dart';

PlayDocument _visualTapPlay() => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'layout_play',
  'revisionId': 'rev_1',
  'format': 'discover',
  'classification': 'fact',
  'topics': ['layout'],
  'learningTopics': <String>[],
  'estimatedDurationSec': 5,
  'assets': ['visual_1'],
  'sources': <Object>[],
  'entryState': 'show',
  'states': {
    'show': {
      'presentation': {
        'layers': [
          {'type': 'image', 'role': 'media', 'assetId': 'visual_1'},
          {'type': 'text', 'role': 'prompt', 'value': 'Look closely.'},
        ],
      },
      'input': {'type': 'tap', 'label': 'Done'},
      'validation': {'type': 'none'},
      'transition': {'default': r'$end'},
    },
  },
});

void main() {
  testWidgets('media stays edge-to-edge while copy and controls respect insets', (
    tester,
  ) async {
    Size? mediaSize;
    const surfaceSize = Size(320, 640);
    const insets = EdgeInsets.only(top: 40, bottom: 30);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: MediaQuery(
              data: const MediaQueryData(
                size: surfaceSize,
                padding: insets,
              ),
              child: SizedBox.fromSize(
                size: surfaceSize,
                child: PlaySurface(
                  play: _visualTapPlay(),
                  mediaBuilder: (context, layer) => LayoutBuilder(
                    builder: (context, constraints) {
                      mediaSize = constraints.biggest;
                      return const ColoredBox(color: Colors.black);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(mediaSize, surfaceSize);

    final surface = tester.getRect(find.byType(PlaySurface));
    final prompt = tester.getRect(find.text('Look closely.'));
    final done = tester.getRect(find.widgetWithText(FilledButton, 'Done'));

    expect(prompt.top, greaterThanOrEqualTo(surface.top + insets.top));
    expect(done.bottom, lessThanOrEqualTo(surface.bottom - insets.bottom));
  });
}
