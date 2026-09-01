import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/guest_engagement.dart';
import 'package:mosaic_app/guest_home.dart';
import 'package:play_flutter/play_flutter.dart';

Future<GuestEngagementController> _controller({bool eligible = false}) async {
  final controller = GuestEngagementController(
    store: MemoryGuestEngagementStore(),
    clock: () => DateTime.utc(2026, 8, 31, 12),
  );
  await controller.initialize();
  if (eligible) {
    for (var index = 0; index < 8; index += 1) {
      await controller.recordVisible(
        playId: 'play_$index',
        revisionId: 'rev_1',
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
  bool directManipulationActive = false,
  Size? size,
  EdgeInsets safeInsets = EdgeInsets.zero,
  String? activeSearchLabel,
  VoidCallback? onClearSearch,
}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        size: size,
        padding: safeInsets,
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: Directionality(
        textDirection: direction,
        child: _guestHome(
          controller: controller,
          child: child,
          directManipulationActive: directManipulationActive,
          activeSearchLabel: activeSearchLabel,
          onClearSearch: onClearSearch,
        ),
      ),
    ),
  ),
);

Widget _guestHome({
  required GuestEngagementController controller,
  required Widget child,
  required bool directManipulationActive,
  String? activeSearchLabel,
  VoidCallback? onClearSearch,
}) {
  if (activeSearchLabel == null) {
    return GuestHome(
      engagement: controller,
      directManipulationActive: directManipulationActive,
      onSearch: () {},
      child: child,
    );
  }
  return Function.apply(
        GuestHome.new,
        const <Object?>[],
        <Symbol, dynamic>{
          #engagement: controller,
          #directManipulationActive: directManipulationActive,
          #onSearch: () {},
          #activeSearchLabel: activeSearchLabel,
          #onClearSearch: onClearSearch,
          #child: child,
        },
      )
      as Widget;
}

final class _BlockingGuestStore implements GuestEngagementStore {
  GuestEngagementState? state;
  Completer<void>? _writeGate;
  bool blockedWriteStarted = false;

  void blockNextWrite() {
    _writeGate = Completer<void>();
    blockedWriteStarted = false;
  }

  void releaseWrite() {
    final gate = _writeGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<GuestEngagementState?> readGuestEngagement() async => state;

  @override
  Future<void> writeGuestEngagement(GuestEngagementState next) async {
    final gate = _writeGate;
    if (gate != null) {
      blockedWriteStarted = true;
      await gate.future;
      _writeGate = null;
    }
    state = next;
  }
}

typedef _ShellViewportCase = ({
  String name,
  Size size,
  EdgeInsets safeInsets,
  TextDirection direction,
  double textScale,
});

const _shellViewportCases = <_ShellViewportCase>[
  (
    name: 'small phone',
    size: Size(320, 640),
    safeInsets: EdgeInsets.only(top: 24, bottom: 16),
    direction: TextDirection.ltr,
    textScale: 2,
  ),
  (
    name: 'portrait',
    size: Size(390, 844),
    safeInsets: EdgeInsets.only(top: 47, bottom: 34),
    direction: TextDirection.ltr,
    textScale: 2,
  ),
  (
    name: 'landscape',
    size: Size(844, 390),
    safeInsets: EdgeInsets.fromLTRB(44, 0, 44, 21),
    direction: TextDirection.rtl,
    textScale: 2,
  ),
  (
    name: 'tablet',
    size: Size(768, 1024),
    safeInsets: EdgeInsets.only(top: 24, bottom: 20),
    direction: TextDirection.rtl,
    textScale: 2,
  ),
  (
    name: 'desktop',
    size: Size(1440, 900),
    safeInsets: EdgeInsets.fromLTRB(16, 12, 16, 12),
    direction: TextDirection.ltr,
    textScale: 2,
  ),
];

void _expectContained(Rect outer, Rect inner) {
  expect(inner.left, greaterThanOrEqualTo(outer.left));
  expect(inner.top, greaterThanOrEqualTo(outer.top));
  expect(inner.right, lessThanOrEqualTo(outer.right));
  expect(inner.bottom, lessThanOrEqualTo(outer.bottom));
}

void main() {
  testWidgets('GuestHome supplies one safe-area viewport composition', (
    tester,
  ) async {
    const viewport = Size(390, 844);
    const safeInsets = EdgeInsets.only(top: 47, bottom: 34);
    tester.view
      ..physicalSize = viewport
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = await _controller();
    addTearDown(controller.dispose);
    PlayViewportComposition? captured;

    await tester.pumpWidget(
      _app(
        controller: controller,
        size: viewport,
        safeInsets: safeInsets,
        textScale: 2,
        child: Builder(
          builder: (context) {
            captured = PlayViewportScope.maybeOf(context);
            return const ColoredBox(color: Colors.black);
          },
        ),
      ),
    );

    expect(find.byType(LayoutBuilder), findsOneWidget);
    expect(find.byType(PlayViewportScope), findsOneWidget);
    expect(captured, isNotNull);
    if (captured == null) return;
    final expected = PlayViewportComposition.fromConstraints(
      const BoxConstraints.tightFor(width: 390, height: 844),
      safeInsets: safeInsets,
      textScaler: const TextScaler.linear(2),
    );
    expect(captured!.safeRect, expected.safeRect);
    expect(captured!.chromeRect, expected.chromeRect);
    expect(captured!.navigationRect, expected.navigationRect);
  });

  for (final viewportCase in _shellViewportCases) {
    testWidgets(
      '${viewportCase.name} shell keeps quiet chrome and exact navigation',
      (tester) async {
        tester.view
          ..physicalSize = viewportCase.size
          ..devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final controller = await _controller();
        addTearDown(controller.dispose);
        final composition = PlayViewportComposition.fromConstraints(
          BoxConstraints.tight(viewportCase.size),
          safeInsets: viewportCase.safeInsets,
          textScaler: TextScaler.linear(viewportCase.textScale),
        );

        await tester.pumpWidget(
          _app(
            controller: controller,
            size: viewportCase.size,
            safeInsets: viewportCase.safeInsets,
            direction: viewportCase.direction,
            textScale: viewportCase.textScale,
            child: const ColoredBox(color: Colors.black),
          ),
        );

        expect(find.text('mixli'), findsNothing);
        expect(find.text('For You'), findsOneWidget);
        expect(find.bySemanticsLabel('Search Mixli'), findsOneWidget);
        _expectContained(
          composition.chromeRect,
          tester.getRect(find.text('For You')),
        );
        _expectContained(
          composition.chromeRect,
          tester.getRect(find.byKey(const ValueKey<String>('open-search'))),
        );
        expect(
          tester.getRect(find.byKey(const ValueKey<String>('open-search'))),
          isA<Rect>()
              .having((rect) => rect.width, 'width', greaterThanOrEqualTo(48))
              .having(
                (rect) => rect.height,
                'height',
                greaterThanOrEqualTo(48),
              ),
        );

        const destinations = <(String, String)>[
          ('play', 'Play'),
          ('saved', 'Saved'),
          ('create', 'Create'),
          ('me', 'Me'),
        ];
        for (final (id, label) in destinations) {
          expect(find.text(label), findsOneWidget);
          expect(find.byKey(ValueKey<String>('guest-nav-$id')), findsOneWidget);
        }
        if (destinations.any(
          (destination) => find
              .byKey(ValueKey<String>('guest-nav-${destination.$1}'))
              .evaluate()
              .isEmpty,
        )) {
          return;
        }
        for (final (id, _) in destinations) {
          final rect = tester.getRect(
            find.byKey(ValueKey<String>('guest-nav-$id')),
          );
          _expectContained(composition.navigationRect, rect);
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
        }
      },
    );
  }

  for (final viewportCase in _shellViewportCases) {
    testWidgets(
      '${viewportCase.name} active search belongs to shared chrome at 200% RTL',
      (tester) async {
        tester.view
          ..physicalSize = viewportCase.size
          ..devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final controller = await _controller();
        addTearDown(controller.dispose);
        var clearCount = 0;
        final composition = PlayViewportComposition.fromConstraints(
          BoxConstraints.tight(viewportCase.size),
          safeInsets: viewportCase.safeInsets,
          textScaler: const TextScaler.linear(2),
        );

        await tester.pumpWidget(
          _app(
            controller: controller,
            child: const ColoredBox(color: Colors.black),
            size: viewportCase.size,
            safeInsets: viewportCase.safeInsets,
            direction: TextDirection.rtl,
            textScale: 2,
            activeSearchLabel: 'Travel',
            onClearSearch: () => clearCount += 1,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('For You'), findsNothing);
        expect(find.text('Travel'), findsOneWidget);
        final chip = find.byKey(const ValueKey<String>('search-scope'));
        expect(chip, findsOneWidget);
        final clear = find.bySemanticsLabel('Clear search');
        expect(clear, findsOneWidget);
        if (chip.evaluate().isEmpty || clear.evaluate().isEmpty) return;
        final chipRect = tester.getRect(chip);
        final searchRect = tester.getRect(
          find.byKey(const ValueKey<String>('open-search')),
        );
        _expectContained(composition.chromeRect, chipRect);
        expect(chipRect.overlaps(searchRect), isFalse);
        expect(chipRect.overlaps(composition.promptRect), isFalse);
        expect(chipRect.overlaps(composition.inputRect), isFalse);

        await tester.tap(clear);
        await tester.pump();
        expect(clearCount, 1);
      },
    );
  }

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
    expect(find.text('Get early access'), findsOneWidget);
    expect(find.text('Join Mixli'), findsNothing);
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
    await tester.tap(find.text('Get early access'));
    await tester.pumpAndSettle();

    expect(find.text('Accounts are opening soon'), findsOneWidget);
    expect(find.text('Your guest feed stays right here.'), findsOneWidget);
    expect(find.text('Back to exploring'), findsOneWidget);
    expect(find.text('Account created'), findsNothing);
  });

  testWidgets('early access persists reset before truthful navigation', (
    tester,
  ) async {
    final store = _BlockingGuestStore();
    var clock = DateTime.utc(2026, 8, 31, 12);
    final controller = GuestEngagementController(
      store: store,
      clock: () => clock,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    for (var index = 0; index < 8; index += 1) {
      await controller.recordVisible(
        playId: 'before_$index',
        revisionId: 'rev_before_$index',
      );
    }
    store.blockNextWrite();

    await tester.pumpWidget(
      _app(controller: controller, child: const Text('Eligible Play')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Get early access'));
    await tester.pump();

    expect(store.blockedWriteStarted, isTrue);
    expect(find.text('Accounts are opening soon'), findsNothing);
    if (!store.blockedWriteStarted) return;
    store.releaseWrite();
    await tester.pumpAndSettle();
    expect(find.text('Accounts are opening soon'), findsOneWidget);
    expect(store.state?.seenIdentities, isEmpty);
    expect(
      store.state?.toJson()['hasMeaningfulInteraction'],
      isFalse,
    );

    final restarted = GuestEngagementController(
      store: store,
      clock: () => clock,
    );
    addTearDown(restarted.dispose);
    await restarted.initialize();
    await tester.pumpWidget(
      _app(controller: restarted, child: const Text('Restarted Play')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Your Mixli is getting good'), findsNothing);

    clock = clock.add(const Duration(days: 7));
    for (var index = 0; index < 8; index += 1) {
      await restarted.recordVisible(
        playId: 'later_$index',
        revisionId: 'rev_later_$index',
      );
    }
    expect(restarted.shouldPrompt, isTrue);
  });

  testWidgets('signup waits until direct manipulation settles', (tester) async {
    final controller = await _controller(eligible: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        controller: controller,
        directManipulationActive: true,
        child: const Text('Fifth Play'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Your Mixli is getting good'), findsNothing);

    await tester.pumpWidget(
      _app(controller: controller, child: const Text('Fifth Play')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Your Mixli is getting good'), findsOneWidget);
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
    expect(find.text('Get early access'), findsOneWidget);
    expect(find.text('Join Mixli'), findsNothing);
  });
}
