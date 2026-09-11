import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:play_schema/play_schema.dart';

/// Renders a bounded declarative scene with stable, accessible object IDs.
/// Selection is presentation state only; callers receive the authoritative
/// piece/target pair for the engine to validate.
final class PlaySceneRenderer extends StatefulWidget {
  const PlaySceneRenderer({
    required this.scene,
    required this.onPieceMove,
    this.placements = const {},
    this.onDirectManipulationChanged,
    this.cueId,
    this.cueProgress = 0,
    super.key,
  });

  final GameSceneDefinition scene;
  final Map<String, String> placements;
  final void Function(String pieceId, String targetId) onPieceMove;
  final ValueChanged<bool>? onDirectManipulationChanged;
  final String? cueId;
  final double cueProgress;

  @override
  State<PlaySceneRenderer> createState() => _PlaySceneRendererState();
}

final class _PlaySceneRendererState extends State<PlaySceneRenderer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _returnMotion;
  final _translation = ValueNotifier<Offset>(Offset.zero);
  Offset _returnFrom = Offset.zero;
  String? _returningId;
  String? _selectedId;
  String? _draggedId;
  String? _hoveredTargetId;
  Offset _dragOffset = Offset.zero;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _returnMotion =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          _translation.value = Offset.lerp(
            _returnFrom,
            Offset.zero,
            Curves.easeOutBack.transform(_returnMotion.value),
          )!;
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_reducedMotion && _returnMotion.isAnimating) {
      _returnMotion.stop();
      _translation.value = Offset.zero;
    }
  }

  @override
  void didUpdateWidget(covariant PlaySceneRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene != widget.scene || oldWidget.cueId != widget.cueId) {
      _interrupt(oldWidget.onDirectManipulationChanged);
    }
  }

  @override
  void dispose() {
    _interrupt(widget.onDirectManipulationChanged);
    _returnMotion.dispose();
    _translation.dispose();
    super.dispose();
  }

  void _interrupt(ValueChanged<bool>? callback) {
    final held = _draggedId != null;
    _returnMotion.stop();
    _translation.value = Offset.zero;
    _returningId = null;
    _selectedId = null;
    _draggedId = null;
    _hoveredTargetId = null;
    _dragOffset = Offset.zero;
    // Removal/replacement can happen during build; release the parent lease
    // after that build instead of calling its setState while the tree is locked.
    if (held && callback != null) scheduleMicrotask(() => callback(false));
  }

  void _select(GameSceneObject object) {
    if (!object.movable) return;
    setState(() => _selectedId = object.id);
  }

  void _tapObject(GameSceneObject object) {
    if (_draggedId != null && _draggedId != object.id) return;
    _releaseDirectManipulation();
    _select(object);
  }

  void _move(GameSceneTarget target) {
    if (_draggedId != null) return;
    final pieceId = _selectedId;
    if (pieceId == null) return;
    _releaseDirectManipulation();
    setState(() => _selectedId = null);
    widget.onPieceMove(pieceId, target.id);
  }

  void _beginDrag(GameSceneObject object) {
    if (!object.movable || _draggedId != null) return;
    _returnMotion.stop();
    final offset = _returningId == object.id ? _translation.value : Offset.zero;
    widget.onDirectManipulationChanged?.call(true);
    setState(() {
      _selectedId = object.id;
      _draggedId = object.id;
      _dragOffset = offset;
      _translation.value = offset;
      _returningId = null;
      _hoveredTargetId = null;
    });
  }

  void _updateDrag(
    DragUpdateDetails details,
    GameSceneObject object,
    double width,
    double height,
  ) {
    if (_draggedId != object.id) return;
    final offset = _dragOffset + details.delta;
    final rect = _placedRect(object);
    final centerX = rect.x * width + rect.width * width / 2 + offset.dx;
    final centerY = rect.y * height + rect.height * height / 2 + offset.dy;
    final target = widget.scene.targets.where((candidate) {
      final rect = candidate.rect;
      return centerX >= rect.x * width &&
          centerX <= (rect.x + rect.width) * width &&
          centerY >= rect.y * height &&
          centerY <= (rect.y + rect.height) * height;
    }).firstOrNull;
    _dragOffset = offset;
    _translation.value = offset;
    // Pointer motion changes only the held object's paint transform. Rebuild
    // scene controls when the destination changes, not on every pointer event.
    if (_hoveredTargetId != target?.id) {
      setState(() => _hoveredTargetId = target?.id);
    }
  }

  void _finishDrag(String objectId) {
    if (_draggedId != objectId) return;
    final pieceId = _draggedId;
    final targetId = _hoveredTargetId;
    _releaseDirectManipulation();
    if (pieceId == null || targetId == null) return;
    final target = widget.scene.targets
        .where((candidate) => candidate.id == targetId)
        .firstOrNull;
    if (target == null) return;
    setState(() => _selectedId = null);
    widget.onPieceMove(pieceId, target.id);
  }

  void _cancelDrag(String objectId) {
    if (_draggedId != objectId) return;
    _releaseDirectManipulation();
  }

  void _releaseDirectManipulation() {
    final wasDragging = _draggedId != null;
    if (wasDragging) widget.onDirectManipulationChanged?.call(false);
    if (_draggedId == null &&
        _hoveredTargetId == null &&
        _dragOffset == Offset.zero) {
      return;
    }
    setState(() {
      _returningId = _draggedId;
      _returnFrom = _dragOffset;
      _draggedId = null;
      _hoveredTargetId = null;
      _dragOffset = Offset.zero;
    });
    if (_reducedMotion) {
      _translation.value = Offset.zero;
    } else if (_returnFrom != Offset.zero) {
      unawaited(_returnMotion.forward(from: 0));
    }
  }

  GameSceneRect _placedRect(GameSceneObject object) {
    final targetId = widget.placements[object.id];
    return widget.scene.targets
            .where((target) => target.id == targetId)
            .firstOrNull
            ?.rect ??
        object.rect;
  }

  KeyEventResult _onActivate(KeyEvent event, VoidCallback action) {
    if (event is! KeyDownEvent ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.space)) {
      return KeyEventResult.ignored;
    }
    action();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final height = constraints.maxHeight;
      if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
        return const SizedBox.shrink();
      }
      final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      final colors = Theme.of(context).colorScheme;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          for (final target in widget.scene.targets)
            if (_selectedId != null)
              _target(target, width, height, colors, reduced),
          for (final object in widget.scene.objects)
            _object(object, width, height, colors, reduced),
        ],
      );
    },
  );

  Widget _target(
    GameSceneTarget target,
    double width,
    double height,
    ColorScheme colors,
    bool reduced,
  ) {
    final rect = target.rect;
    return Positioned(
      left: rect.x * width,
      top: rect.y * height,
      width: rect.width * width,
      height: rect.height * height,
      child: Focus(
        onKeyEvent: (_, event) => _onActivate(event, () => _move(target)),
        child: Semantics(
          button: true,
          label: target.semanticLabel,
          onTap: () => _move(target),
          child: GestureDetector(
            onTap: () => _move(target),
            child: AnimatedContainer(
              key: ValueKey<String>('scene-target-socket:${target.id}'),
              duration: reduced
                  ? Duration.zero
                  : const Duration(milliseconds: 140),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: _hoveredTargetId == target.id
                      ? colors.primary
                      : colors.outlineVariant,
                  width: _hoveredTargetId == target.id ? 3 : 2,
                ),
                color: colors.primary.withValues(
                  alpha: _hoveredTargetId == target.id ? .18 : .10,
                ),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: .18),
                    offset: const Offset(0, 2),
                    blurRadius: 5,
                  ),
                  BoxShadow(
                    color: colors.primary.withValues(
                      alpha: _hoveredTargetId == target.id ? .2 : .11,
                    ),
                    blurRadius: _hoveredTargetId == target.id ? 12 : 7,
                    spreadRadius: _hoveredTargetId == target.id ? 1 : 0,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _object(
    GameSceneObject object,
    double width,
    double height,
    ColorScheme colors,
    bool reduced,
  ) {
    final activeCue = widget.scene
        .cuesForId(widget.cueId)
        .where((cue) => cue.objectId == object.id)
        .firstOrNull;
    final targetId = widget.placements[object.id];
    final target = targetId == null
        ? null
        : widget.scene.targets
              .where((entry) => entry.id == targetId)
              .firstOrNull;
    final safeProgress = widget.cueProgress.isFinite
        ? widget.cueProgress.clamp(0.0, 1.0).toDouble()
        : 0.0;
    final rect = activeCue?.sample(safeProgress) ?? target?.rect ?? object.rect;
    final movable = object.movable && activeCue == null;
    final selected = object.id == _selectedId;
    final isMatchstick = object.shape == GameSceneShape.matchstick;
    final isCup = object.shape == GameSceneShape.cup;
    final isCoin = object.shape == GameSceneShape.coin;
    final isOrb = object.shape == GameSceneShape.orb;
    final horizontalMatchstick = isMatchstick && rect.width > rect.height;
    final color = isMatchstick
        ? const Color(0xFFC9783E)
        : switch (object.tone) {
            GameSceneTone.foreground => colors.onSurface,
            GameSceneTone.muted => colors.onSurfaceVariant,
            GameSceneTone.accent => colors.primary,
            GameSceneTone.surface => colors.surfaceContainerHighest,
          };
    return AnimatedPositioned(
      key: ValueKey<String>('scene-object:${object.id}'),
      duration: reduced || activeCue != null
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      left: rect.x * width,
      top: rect.y * height,
      width: rect.width * width,
      height: rect.height * height,
      child: ValueListenableBuilder<Offset>(
        valueListenable: _draggedId == object.id || _returningId == object.id
            ? _translation
            : const AlwaysStoppedAnimation<Offset>(Offset.zero),
        builder: (context, offset, child) => Transform.translate(
          offset: _draggedId == object.id || _returningId == object.id
              ? offset
              : Offset.zero,
          child: child,
        ),
        child: Focus(
          canRequestFocus: movable,
          skipTraversal: !movable,
          onKeyEvent: movable
              ? (_, event) => _onActivate(event, () => _tapObject(object))
              : null,
          child: Semantics(
            button: movable,
            label: object.semanticLabel,
            selected: selected,
            onTap: movable ? () => _tapObject(object) : null,
            child: GestureDetector(
              dragStartBehavior: DragStartBehavior.down,
              onTap: movable ? () => _tapObject(object) : null,
              onPanDown: movable ? (_) => _beginDrag(object) : null,
              onPanStart: movable ? (_) => _beginDrag(object) : null,
              onPanUpdate: movable
                  ? (details) => _updateDrag(details, object, width, height)
                  : null,
              onPanEnd: movable ? (_) => _finishDrag(object.id) : null,
              onPanCancel: movable ? () => _cancelDrag(object.id) : null,
              child: AnimatedScale(
                duration: reduced
                    ? Duration.zero
                    : const Duration(milliseconds: 120),
                scale: selected ? 1.08 : 1,
                curve: Curves.easeOutBack,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: isCup
                        ? colors.primaryContainer
                        : isCoin
                        ? colors.tertiaryContainer
                        : color,
                    shape:
                        object.shape == GameSceneShape.circle || isCoin || isOrb
                        ? BoxShape.circle
                        : BoxShape.rectangle,
                    borderRadius:
                        object.shape == GameSceneShape.roundedRect ||
                            isCup ||
                            isMatchstick
                        ? BorderRadius.circular(999)
                        : null,
                    border: isMatchstick
                        ? Border.all(
                            color: const Color(0xFF7A3E20),
                            width: 1.25,
                          )
                        : isCup
                        ? Border.all(color: colors.primary, width: 1.5)
                        : isCoin
                        ? Border.all(color: colors.tertiary, width: 1.5)
                        : isOrb
                        ? Border.all(
                            color: colors.onSurface.withValues(alpha: .24),
                            width: 1.25,
                          )
                        : null,
                    boxShadow:
                        selected || isMatchstick || isCup || isCoin || isOrb
                        ? [
                            BoxShadow(
                              color: colors.shadow.withValues(alpha: .22),
                              offset: const Offset(0, 4),
                              blurRadius: 8,
                            ),
                          ]
                        : const [],
                  ),
                  child: isMatchstick
                      ? Align(
                          alignment: horizontalMatchstick
                              ? Alignment.centerRight
                              : Alignment.topCenter,
                          child: FractionallySizedBox(
                            widthFactor: horizontalMatchstick ? .2 : .78,
                            heightFactor: horizontalMatchstick ? .78 : .2,
                            child: DecoratedBox(
                              key: const ValueKey<String>(
                                'scene-matchstick-head',
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF5D2518),
                                borderRadius: horizontalMatchstick
                                    ? const BorderRadius.horizontal(
                                        right: Radius.circular(999),
                                      )
                                    : const BorderRadius.vertical(
                                        top: Radius.circular(999),
                                      ),
                              ),
                            ),
                          ),
                        )
                      : isCup
                      ? _SceneCup(colors: colors)
                      : isCoin
                      ? _SceneCoin(colors: colors)
                      : isOrb
                      ? _SceneOrb(id: object.id, colors: colors)
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _SceneCup extends StatelessWidget {
  const _SceneCup({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Align(
        alignment: Alignment.topCenter,
        child: FractionallySizedBox(
          widthFactor: .86,
          heightFactor: .2,
          child: DecoratedBox(
            key: const ValueKey<String>('scene-cup-rim'),
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: colors.onPrimary.withValues(alpha: .36),
              ),
            ),
          ),
        ),
      ),
      Align(
        alignment: Alignment.topCenter,
        child: FractionallySizedBox(
          widthFactor: .58,
          heightFactor: .1,
          child: DecoratedBox(
            key: const ValueKey<String>('scene-cup-well'),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
      Align(
        alignment: const Alignment(0, .45),
        child: FractionallySizedBox(
          widthFactor: .16,
          heightFactor: .44,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.onPrimaryContainer.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
      Align(
        alignment: Alignment.bottomCenter,
        child: FractionallySizedBox(
          widthFactor: .62,
          heightFactor: .08,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: .42),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    ],
  );
}

final class _SceneCoin extends StatelessWidget {
  const _SceneCoin({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: DecoratedBox(
            key: const ValueKey<String>('scene-coin-rim'),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: colors.tertiary.withValues(alpha: .72),
                width: 1.25,
              ),
            ),
          ),
        ),
      ),
      Center(
        child: FractionallySizedBox(
          widthFactor: .38,
          heightFactor: .38,
          child: DecoratedBox(
            key: const ValueKey<String>('scene-coin-mark'),
            decoration: BoxDecoration(
              color: colors.tertiary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: colors.onTertiaryContainer.withValues(alpha: .18),
                  offset: const Offset(0, 1),
                  blurRadius: 1.5,
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

final class _SceneOrb extends StatelessWidget {
  const _SceneOrb({required this.id, required this.colors});

  final String id;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Align(
        alignment: const Alignment(-.32, -.36),
        child: FractionallySizedBox(
          widthFactor: .28,
          heightFactor: .28,
          child: DecoratedBox(
            key: ValueKey<String>('scene-orb-highlight:$id'),
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: .72),
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
      Align(
        alignment: const Alignment(.22, .3),
        child: FractionallySizedBox(
          widthFactor: .2,
          heightFactor: .2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.onSurface.withValues(alpha: .16),
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    ],
  );
}
