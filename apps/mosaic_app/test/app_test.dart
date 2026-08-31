import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/main.dart';

void main() {
  testWidgets('first launch opens the optional visual onboarding', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: MosaicApp()));
    await tester.pumpAndSettle();

    expect(find.text('What are you into?'), findsOneWidget);
    expect(find.text('Surprise me'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Where is this?'), findsNothing);
  });
}
