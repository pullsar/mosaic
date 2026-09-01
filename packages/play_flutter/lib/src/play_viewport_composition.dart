import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

enum PlayUtilityPlacement { horizontalDock, trailingRail }

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
  }) {
    final viewportSize = constraints.biggest;
    final viewportRect = Offset.zero & viewportSize;
    final safeRect = Rect.fromLTRB(
      safeInsets.left,
      safeInsets.top,
      viewportSize.width - safeInsets.right,
      viewportSize.height - safeInsets.bottom,
    );
    final railStageArea = Size(
      math.max(0.0, safeRect.width - _utilityRailWidth - _regionGap),
      math.max(
        0.0,
        safeRect.height -
            _chromeHeight -
            _promptHeight -
            _inputHeight -
            _navigationHeight,
      ),
    );
    final railStageSize = _fitStage(railStageArea);
    final useRail =
        railStageSize.width >= _minimumRailStage.width &&
        railStageSize.height >= _minimumRailStage.height;
    final utilityPlacement = useRail
        ? PlayUtilityPlacement.trailingRail
        : PlayUtilityPlacement.horizontalDock;

    var top = safeRect.top;
    final chromeRect = Rect.fromLTWH(
      safeRect.left,
      top,
      safeRect.width,
      _chromeHeight,
    );
    top = chromeRect.bottom;
    final promptRect = Rect.fromLTWH(
      safeRect.left,
      top,
      safeRect.width,
      _promptHeight,
    );
    top = promptRect.bottom;

    late final Rect stageRect;
    late final Rect inputRect;
    late final Rect utilityRect;
    late final Rect navigationRect;
    late final List<Rect> reservedRegions;
    if (useRail) {
      stageRect = Rect.fromLTWH(
        safeRect.left,
        top,
        railStageSize.width,
        railStageSize.height,
      );
      utilityRect = Rect.fromLTWH(
        stageRect.right + _regionGap,
        top,
        _utilityRailWidth,
        stageRect.height,
      );
      inputRect = Rect.fromLTWH(
        safeRect.left,
        stageRect.bottom,
        safeRect.width,
        _inputHeight,
      );
      navigationRect = Rect.fromLTWH(
        safeRect.left,
        inputRect.bottom,
        safeRect.width,
        _navigationHeight,
      );
      reservedRegions = <Rect>[
        chromeRect,
        promptRect,
        stageRect,
        utilityRect,
        inputRect,
        navigationRect,
      ];
    } else {
      final stageArea = Size(
        safeRect.width,
        math.max(
          0.0,
          safeRect.height -
              _chromeHeight -
              _promptHeight -
              _inputHeight -
              _utilityDockHeight -
              _navigationHeight,
        ),
      );
      final stageSize = _fitStage(stageArea);
      stageRect = Rect.fromLTWH(
        safeRect.left,
        top,
        stageSize.width,
        stageSize.height,
      );
      inputRect = Rect.fromLTWH(
        safeRect.left,
        stageRect.bottom,
        safeRect.width,
        _inputHeight,
      );
      utilityRect = Rect.fromLTWH(
        safeRect.left,
        inputRect.bottom,
        safeRect.width,
        _utilityDockHeight,
      );
      navigationRect = Rect.fromLTWH(
        safeRect.left,
        utilityRect.bottom,
        safeRect.width,
        _navigationHeight,
      );
      reservedRegions = <Rect>[
        chromeRect,
        promptRect,
        stageRect,
        inputRect,
        utilityRect,
        navigationRect,
      ];
    }

    return PlayViewportComposition._(
      viewportRect: viewportRect,
      safeRect: safeRect,
      chromeRect: chromeRect,
      promptRect: promptRect,
      stageRect: stageRect,
      inputRect: inputRect,
      utilityRect: utilityRect,
      navigationRect: navigationRect,
      utilityPlacement: utilityPlacement,
      reservedRegions: reservedRegions,
    );
  }

  static const double _minimumStageAspectRatio = 3 / 4;
  static const double _maximumStageAspectRatio = 16 / 9;
  static const double _chromeHeight = 48;
  static const double _promptHeight = 64;
  static const double _inputHeight = 64;
  static const double _utilityDockHeight = 56;
  static const double _utilityRailWidth = 72;
  static const double _navigationHeight = 56;
  static const double _regionGap = 16;
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

Size _fitStage(Size available) {
  if (available.width == 0 || available.height == 0) {
    return Size.zero;
  }
  final aspectRatio = available.width / available.height;
  if (aspectRatio < PlayViewportComposition._minimumStageAspectRatio) {
    return Size(
      available.width,
      available.width / PlayViewportComposition._minimumStageAspectRatio,
    );
  }
  if (aspectRatio > PlayViewportComposition._maximumStageAspectRatio) {
    return Size(
      available.height * PlayViewportComposition._maximumStageAspectRatio,
      available.height,
    );
  }
  return available;
}
