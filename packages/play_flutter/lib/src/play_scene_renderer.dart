import 'package:flutter/material.dart';
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
    super.key,
  });

  final GameSceneDefinition scene;
  final Map<String, String> placements;
  final void Function(String pieceId, String targetId) onPieceMove;
  final ValueChanged<bool>? onDirectManipulationChanged;

  @override
  State<PlaySceneRenderer> createState() => _PlaySceneRendererState();
}

final class _PlaySceneRendererState extends State<PlaySceneRenderer> {
  String? _selectedId;
  String? _draggedId;
  String? _hoveredTargetId;
  Offset _dragOffset = Offset.zero;

  void _select(GameSceneObject object) {
    if (!object.movable) return;
    setState(() => _selectedId = object.id);
  }

  void _tapObject(GameSceneObject object) {
    _releaseDirectManipulation();
    _select(object);
  }

  void _move(GameSceneTarget target) {
    final pieceId = _selectedId;
    if (pieceId == null) return;
    _releaseDirectManipulation();
    setState(() => _selectedId = null);
    widget.onPieceMove(pieceId, target.id);
  }

  void _beginDrag(GameSceneObject object) {
    if (!object.movable) return;
    if (_draggedId == null) widget.onDirectManipulationChanged?.call(true);
    setState(() {
      _selectedId = object.id;
      _draggedId = object.id;
      _dragOffset = Offset.zero;
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
    final centerX =
        object.rect.x * width + object.rect.width * width / 2 + offset.dx;
    final centerY =
        object.rect.y * height + object.rect.height * height / 2 + offset.dy;
    final target = widget.scene.targets.where((candidate) {
      final rect = candidate.rect;
      return centerX >= rect.x * width &&
          centerX <= (rect.x + rect.width) * width &&
          centerY >= rect.y * height &&
          centerY <= (rect.y + rect.height) * height;
    }).firstOrNull;
    setState(() {
      _dragOffset = offset;
      _hoveredTargetId = target?.id;
    });
  }

  void _finishDrag() {
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

  void _releaseDirectManipulation() {
    final wasDragging = _draggedId != null;
    if (wasDragging) widget.onDirectManipulationChanged?.call(false);
    if (_draggedId == null &&
        _hoveredTargetId == null &&
        _dragOffset == Offset.zero) {
      return;
    }
    setState(() {
      _draggedId = null;
      _hoveredTargetId = null;
      _dragOffset = Offset.zero;
    });
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
      child: Semantics(
        button: true,
        label: target.semanticLabel,
        child: GestureDetector(
          onTap: () => _move(target),
          child: AnimatedContainer(
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
    final targetId = widget.placements[object.id];
    final target = targetId == null
        ? null
        : widget.scene.targets
              .where((entry) => entry.id == targetId)
              .firstOrNull;
    final rect = target?.rect ?? object.rect;
    final selected = object.id == _selectedId;
    final color = switch (object.tone) {
      GameSceneTone.foreground => colors.onSurface,
      GameSceneTone.muted => colors.onSurfaceVariant,
      GameSceneTone.accent => colors.primary,
      GameSceneTone.surface => colors.surfaceContainerHighest,
    };
    return AnimatedPositioned(
      key: ValueKey<String>('scene-object:${object.id}'),
      duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      left: rect.x * width,
      top: rect.y * height,
      width: rect.width * width,
      height: rect.height * height,
      child: Semantics(
        button: object.movable,
        label: object.semanticLabel,
        selected: selected,
        child: GestureDetector(
          onTap: object.movable ? () => _tapObject(object) : null,
          onPanDown: object.movable ? (_) => _beginDrag(object) : null,
          onPanStart: object.movable ? (_) => _beginDrag(object) : null,
          onPanUpdate: object.movable
              ? (details) => _updateDrag(details, object, width, height)
              : null,
          onPanEnd: object.movable ? (_) => _finishDrag() : null,
          onPanCancel: object.movable ? _releaseDirectManipulation : null,
          child: AnimatedSlide(
            duration: reduced
                ? Duration.zero
                : const Duration(milliseconds: 110),
            curve: Curves.easeOutCubic,
            offset: Offset(
              rect.width * width == 0
                  ? 0
                  : _dragOffset.dx / (rect.width * width),
              rect.height * height == 0
                  ? 0
                  : _dragOffset.dy / (rect.height * height),
            ),
            child: AnimatedScale(
              duration: reduced
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              scale: selected ? 1.08 : 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  shape: object.shape == GameSceneShape.circle
                      ? BoxShape.circle
                      : BoxShape.rectangle,
                  borderRadius: object.shape == GameSceneShape.roundedRect
                      ? BorderRadius.circular(999)
                      : null,
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: colors.shadow.withValues(alpha: .22),
                            offset: const Offset(0, 4),
                            blurRadius: 8,
                          ),
                        ]
                      : const [],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
