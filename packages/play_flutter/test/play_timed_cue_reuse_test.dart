import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:play_flutter/play_flutter.dart';

void main() {
  testWidgets('replacement cue receives its entire authored duration', (
    tester,
  ) async {
    final elapsed = <String>[];
    Widget app(String id, int ordinal) => MaterialApp(
      home: PlayTimedCueInput(
        duration: const Duration(seconds: 1),
        cueId: id,
        ordinal: ordinal,
        onElapsed: () => elapsed.add('$id:$ordinal'),
      ),
    );
    await tester.pumpWidget(app('observe', 0));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpWidget(app('shuffle', 1));
    await tester.pump(const Duration(milliseconds: 200));
    expect(elapsed, isEmpty);
    await tester.pump(const Duration(milliseconds: 800));
    expect(elapsed, ['shuffle:1']);
    await tester.pumpWidget(app('shuffle', 2));
    await tester.pump(const Duration(milliseconds: 1000));
    expect(elapsed, ['shuffle:1', 'shuffle:2']);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });
}
