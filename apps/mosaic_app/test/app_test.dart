import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/main.dart';

void main() {
  testWidgets('opens directly into a Play', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MosaicApp()));
    expect(find.text('Where is this?'), findsOneWidget);
    expect(find.text('Lisbon'), findsOneWidget);
    expect(find.text('Marrakech'), findsOneWidget);
  });
}
