import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/guest_engagement.dart';
import 'package:mosaic_app/guest_home.dart';

Future<GuestEngagementController> _controller({bool eligible = false}) async {
  final controller = GuestEngagementController(
    store: MemoryGuestEngagementStore(),
    clock: () => DateTime.utc(2026, 8, 31, 12),
  );
  await controller.initialize();
  if (eligible) {
    for (var index = 0; index < 5; index += 1) {
      await controller.recordVisible(
        feedRequestId: 'request',
        revisionId: 'rev_$index',
      );
    }
  }
  return controller;
}

Widget _app({
  required GuestEngagementController controller,
  required Widget child,
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
  bool disableAnimations = false,
}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: Directionality(
        textDirection: direction,
        child: GuestHome(engagement: controller, onSearch: () {}, child: child),
      ),
    ),
  ),
);

void main() {
  testWidgets('feed is visible before any registration request', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(controller: controller, child: const Text('First Play')),
    );
    await tester.pumpAndSettle();

    expect(find.text('First Play'), findsOneWidget);
    expect(find.text('What are you into?'), findsNothing);
    expect(find.text('Your Mixli is getting good'), findsNothing);
  });

  testWidgets('eligible guest sees a dismissible signup sheet', (tester) async {
    final controller = await _controller(eligible: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(controller: controller, child: const Text('Fifth Play')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fifth Play'), findsOneWidget);
    expect(find.text('Your Mixli is getting good'), findsOneWidget);
    expect(find.text('Join Mixli'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Fifth Play'), findsOneWidget);
    expect(find.text('Your Mixli is getting good'), findsNothing);
  });

  testWidgets('join opens truthful early-access page', (tester) async {
    final controller = await _controller(eligible: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(controller: controller, child: const Text('Fifth Play')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join Mixli'));
    await tester.pumpAndSettle();

    expect(find.text('Accounts are opening soon'), findsOneWidget);
    expect(find.text('Your guest feed stays right here.'), findsOneWidget);
    expect(find.text('Back to exploring'), findsOneWidget);
    expect(find.text('Account created'), findsNothing);
  });

  testWidgets('compact home remains usable with RTL and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(624, 1350.4);
    tester.view.devicePixelRatio = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _controller(eligible: true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(
        controller: controller,
        child: const Text('Fifth Play'),
        direction: TextDirection.rtl,
        textScale: 1.6,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Search Mixli'), findsOneWidget);
    expect(find.text('Join Mixli'), findsOneWidget);
  });
}
