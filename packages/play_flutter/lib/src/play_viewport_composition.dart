import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

enum PlayUtilityPlacement { horizontalDock, trailingRail }

@immutable
final class PlayViewportScope extends InheritedWidget {
  const PlayViewportScope({
    required this.composition,
    required super.child,
    super.key,
  });

  final PlayViewportComposition composition;

  static PlayViewportComposition? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PlayViewportScope>()
      ?.composition;

  @override
  bool updateShouldNotify(covariant PlayViewportScope oldWidget) =>
      composition != oldWidget.composition;
}

@immutable
final class PlayViewportComposition {
  PlayViewportComposition._({
    required this.viewportRect,
    required this.safeRect,
    required this.chromeRect,
    required this.promptRect,
    required this.stageRect,
    required this.inputRect,
    required this.utilityRect,
    required this.navigationRect,
    required this.utilityPlacement,
    required List<Rect> reservedRegions,
  }) : reservedRegions = List<Rect>.unmodifiable(reservedRegions);

  factory PlayViewportComposition.fromConstraints(
    BoxConstraints constraints, {
    EdgeInsets safeInsets = EdgeInsets.zero,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    _validateGeometry(constraints, safeInsets);
    final viewportSize = constraints.biggest;
    final viewportRect = Offset.zero & viewportSize;
    final safeRect = Rect.fromLTRB(
      safeInsets.left,
      safeInsets.top,
      viewportSize.width - safeInsets.right,
      viewportSize.height - safeInsets.bottom,
    );
    final textScale = _boundedTextScale(textScaler);
    final desiredPromptHeight = _promptHeight * textScale;
    final desiredInputHeight = _inputHeight * textScale;
    final desiredNavigationHeight = _navigationHeight * textScale;
    final desiredFixedHeight =
        _chromeHeight +
        desiredPromptHeight +
        desiredInputHeight +
        _utilityDockHeight +
        desiredNavigationHeight;
    final bandFactor = math.min(
      1.0,
      safeRect.height * 0.8 / desiredFixedHeight,
    );
    final chromeHeight = _chromeHeight * bandFactor;
    final promptHeight = desiredPromptHeight * bandFactor;
    final inputHeight = desiredInputHeight * bandFactor;
    final utilityDockHeight = _utilityDockHeight * bandFactor;
    final navigationHeight = desiredNavigationHeight * bandFactor;
    final isCompactLandscape =
        safeRect.width > safeRect.height &&
        safeRect.height < _compactLandscapeHeight;

    if (isCompactLandscape) {
      return _compactLandscape(
        viewportRect: viewportRect,
        safeRect: safeRect,
        navigationHeight: navigationHeight,
      );
    }

    final chromeRect = Rect.fromLTWH(
      safeRect.left,
      safeRect.top,
      safeRect.width,
      chromeHeight,
    );
    final promptRect = Rect.fromLTWH(
      safeRect.left,
      chromeRect.bottom,
      safeRect.width,
      promptHeight,
    );
    final navigationRect = Rect.fromLTWH(
      safeRect.left,
      safeRect.bottom - navigationHeight,
      safeRect.width,
      navigationHeight,
    );
    final railInputRect = Rect.fromLTWH(
      safeRect.left,
      navigationRect.top - inputHeight,
      safeRect.width,
      inputHeight,
    );
    final railStageBounds = Rect.fromLTRB(
      safeRect.left,
      promptRect.bottom,
      safeRect.right - _utilityRailWidth - _regionGap,
      railInputRect.top,
    );
    final railStageSize = _fitStage(
      Size(
        math.max(0.0, railStageBounds.width),
        math.max(0.0, railStageBounds.height),
      ),
    );
    final useRail =
        railStageSize.width >= _minimumRailStage.width &&
        railStageSize.height >= _minimumRailStage.height;

    if (useRail) {
      final groupWidth = railStageSize.width + _regionGap + _utilityRailWidth;
      final groupLeft = safeRect.left + (safeRect.width - groupWidth) / 2;
      final stageRect = Rect.fromLTWH(
        groupLeft,
        railStageBounds.center.dy - railStageSize.height / 2,
        railStageSize.width,
        railStageSize.height,
      );
      final utilityRect = Rect.fromLTWH(
        stageRect.right + _regionGap,
        stageRect.top,
        _utilityRailWidth,
        stageRect.height,
      );
      return PlayViewportComposition._(
        viewportRect: viewportRect,
        safeRect: safeRect,
        chromeRect: chromeRect,
        promptRect: promptRect,
        stageRect: stageRect,
        inputRect: railInputRect,
        utilityRect: utilityRect,
        navigationRect: navigationRect,
        utilityPlacement: PlayUtilityPlacement.trailingRail,
        reservedRegions: <Rect>[
          chromeRect,
          promptRect,
          stageRect,
          utilityRect,
          railInputRect,
          navigationRect,
        ],
      );
    }

    final utilityRect = Rect.fromLTWH(
      safeRect.left,
      navigationRect.top - utilityDockHeight,
      safeRect.width,
      utilityDockHeight,
    );
    final inputRect = Rect.fromLTWH(
      safeRect.left,
      utilityRect.top - inputHeight,
      safeRect.width,
      inputHeight,
    );
    final stageBounds = Rect.fromLTRB(
      safeRect.left,
      promptRect.bottom,
      safeRect.right,
      inputRect.top,
    );
    final stageRect = _centeredStage(stageBounds);
    return PlayViewportComposition._(
      viewportRect: viewportRect,
      safeRect: safeRect,
      chromeRect: chromeRect,
      promptRect: promptRect,
      stageRect: stageRect,
      inputRect: inputRect,
      utilityRect: utilityRect,
      navigationRect: navigationRect,
      utilityPlacement: PlayUtilityPlacement.horizontalDock,
      reservedRegions: <Rect>[
        chromeRect,
        promptRect,
        stageRect,
        inputRect,
        utilityRect,
        navigationRect,
      ],
    );
  }

  static const double _minimumStageAspectRatio = 3 / 4;
  static const double _maximumStageAspectRatio = 16 / 9;
  static const double _maximumStageWidth = 720;
  static const double _chromeHeight = 48;
  static const double _promptHeight = 64;
  static const double _inputHeight = 64;
  static const double _utilityDockHeight = 56;
  static const double _utilityRailWidth = 72;
  static const double _navigationHeight = 56;
  static const double _regionGap = 16;
  static const double _compactLandscapeHeight = 600;
  static const double _compactChromeHeight = 48;
  static const double _compactUtilityDockHeight = 48;
  static const Size _minimumRailStage = Size(320, 240);

  final Rect viewportRect;
  final Rect safeRect;
  final Rect chromeRect;
  final Rect promptRect;
  final Rect stageRect;
  final Rect inputRect;
  final Rect utilityRect;
  final Rect navigationRect;
  final PlayUtilityPlacement utilityPlacement;
  final List<Rect> reservedRegions;
}

PlayViewportComposition _compactLandscape({
  required Rect viewportRect,
  required Rect safeRect,
  required double navigationHeight,
}) {
  final desiredFixedHeight =
      PlayViewportComposition._compactChromeHeight +
      PlayViewportComposition._compactUtilityDockHeight +
      navigationHeight;
  final bandFactor = math.min(1.0, safeRect.height * 0.6 / desiredFixedHeight);
  final chromeHeight =
      PlayViewportComposition._compactChromeHeight * bandFactor;
  final utilityHeight =
      PlayViewportComposition._compactUtilityDockHeight * bandFactor;
  final boundedNavigationHeight = navigationHeight * bandFactor;
  final chromeRect = Rect.fromLTWH(
    safeRect.left,
    safeRect.top,
    safeRect.width,
    chromeHeight,
  );
  final navigationRect = Rect.fromLTWH(
    safeRect.left,
    safeRect.bottom - boundedNavigationHeight,
    safeRect.width,
    boundedNavigationHeight,
  );
  final utilityRect = Rect.fromLTWH(
    safeRect.left,
    navigationRect.top - utilityHeight,
    safeRect.width,
    utilityHeight,
  );
  final contextColumnWidth = math.min(160.0, safeRect.width * 0.2);
  final regionGap = math.min(
    PlayViewportComposition._regionGap,
    safeRect.width * 0.04,
  );
  final promptRect = Rect.fromLTRB(
    safeRect.left,
    chromeRect.bottom,
    safeRect.left + contextColumnWidth,
    utilityRect.top,
  );
  final inputRect = Rect.fromLTRB(
    safeRect.right - contextColumnWidth,
    chromeRect.bottom,
    safeRect.right,
    utilityRect.top,
  );
  final stageBounds = Rect.fromLTRB(
    promptRect.right + regionGap,
    chromeRect.bottom,
    inputRect.left - regionGap,
    utilityRect.top,
  );
  final stageRect = _centeredStage(stageBounds);

  return PlayViewportComposition._(
    viewportRect: viewportRect,
    safeRect: safeRect,
    chromeRect: chromeRect,
    promptRect: promptRect,
    stageRect: stageRect,
    inputRect: inputRect,
    utilityRect: utilityRect,
    navigationRect: navigationRect,
    utilityPlacement: PlayUtilityPlacement.horizontalDock,
    reservedRegions: <Rect>[
      chromeRect,
      promptRect,
      stageRect,
      inputRect,
      utilityRect,
      navigationRect,
    ],
  );
}

void _validateGeometry(BoxConstraints constraints, EdgeInsets safeInsets) {
  final viewportSize = constraints.biggest;
  if (!constraints.hasBoundedWidth ||
      !constraints.hasBoundedHeight ||
      !viewportSize.width.isFinite ||
      !viewportSize.height.isFinite ||
      viewportSize.width <= 0 ||
      viewportSize.height <= 0) {
    throw ArgumentError.value(
      constraints,
      'constraints',
      'must provide a bounded, finite, positive viewport',
    );
  }
  final insetValues = <double>[
    safeInsets.left,
    safeInsets.top,
    safeInsets.right,
    safeInsets.bottom,
  ];
  if (insetValues.any((value) => !value.isFinite || value < 0)) {
    throw ArgumentError.value(
      safeInsets,
      'safeInsets',
      'must contain only finite, non-negative values',
    );
  }
  if (safeInsets.horizontal >= viewportSize.width ||
      safeInsets.vertical >= viewportSize.height) {
    throw ArgumentError.value(
      safeInsets,
      'safeInsets',
      'must leave positive width and height inside the viewport',
    );
  }
}

double _boundedTextScale(TextScaler textScaler) {
  const referenceFontSize = 16.0;
  final scaledFontSize = textScaler.scale(referenceFontSize);
  if (!scaledFontSize.isFinite || scaledFontSize <= 0) {
    throw ArgumentError.value(
      textScaler,
      'textScaler',
      'must produce a finite, positive scale',
    );
  }
  return (scaledFontSize / referenceFontSize).clamp(1.0, 2.0).toDouble();
}

Rect _centeredStage(Rect bounds) {
  final size = _fitStage(bounds.size);
  return Rect.fromCenter(
    center: bounds.center,
    width: size.width,
    height: size.height,
  );
}

Size _fitStage(Size available) {
  if (available.width <= 0 || available.height <= 0) {
    return Size.zero;
  }
  var width = math.min(
    available.width,
    PlayViewportComposition._maximumStageWidth,
  );
  var height = available.height;
  final aspectRatio = width / height;
  final minimumAspect = PlayViewportComposition._minimumStageAspectRatio;
  final maximumAspect = PlayViewportComposition._maximumStageAspectRatio;
  if (aspectRatio < minimumAspect) {
    height = width / minimumAspect;
  } else if (aspectRatio > maximumAspect) {
    width = height * maximumAspect;
  }
  return Size(width, height);
}
