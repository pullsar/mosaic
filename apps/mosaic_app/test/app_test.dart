import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/main.dart';

void main() {
  testWidgets('first launch opens the guest discovery feed', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MosaicApp()));
    await tester.pumpAndSettle();

    expect(find.text('What are you into?'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('guest-home')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('feed-empty-retry')),
      findsOneWidget,
    );
  });
}
