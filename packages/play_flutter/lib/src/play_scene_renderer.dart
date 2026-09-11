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
    super.key,
  });

  final GameSceneDefinition scene;
  final Map<String, String> placements;
  final void Function(String pieceId, String targetId) onPieceMove;

  @override
  State<PlaySceneRenderer> createState() => _PlaySceneRendererState();
}

final class _PlaySceneRendererState extends State<PlaySceneRenderer> {
  String? _selectedId;

  void _select(GameSceneObject object) {
    if (!object.movable) return;
    setState(() => _selectedId = object.id);
  }

  void _move(GameSceneTarget target) {
    final pieceId = _selectedId;
    if (pieceId == null) return;
    setState(() => _selectedId = null);
    widget.onPieceMove(pieceId, target.id);
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
              border: Border.all(color: colors.primary, width: 2),
              color: colors.primary.withValues(alpha: .10),
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
          onTap: object.movable ? () => _select(object) : null,
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
    );
  }
}
