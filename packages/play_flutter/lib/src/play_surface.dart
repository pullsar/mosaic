import 'package:flutter/material.dart';
import 'package:play_engine/play_engine.dart';
import 'package:play_schema/play_schema.dart';

import 'play_canvas_renderer.dart';
import 'play_input_primitives.dart';
import 'play_media_layer_renderer.dart';
import 'visual_tokens.dart';

typedef PlayMediaBuilder =
    Widget Function(BuildContext context, PresentationLayer layer);

final class PlaySurface extends StatefulWidget {
  const PlaySurface({
    required this.play,
    this.mediaBuilder,
    this.onResolved,
    this.onDirectManipulationChanged,
    super.key,
  });

  final PlayDocument play;
  final PlayMediaBuilder? mediaBuilder;
  final ValueChanged<PlayResolution>? onResolved;

  /// True while a direct-manipulation primitive owns a drag gesture.
  ///
  /// Feed containers should use this to suspend vertical paging until the
  /// manipulation ends instead of relying on gesture-arena ordering.
  final ValueChanged<bool>? onDirectManipulationChanged;

  @override
  State<PlaySurface> createState() => _PlaySurfaceState();
}

final class _PlaySurfaceState extends State<PlaySurface> {
  static const _engine = PlayEngine();
  late PlaySession _session;

  @override
  void initState() {
    super.initState();
    _session = _engine.start(widget.play);
  }

  @override
  void didUpdateWidget(covariant PlaySurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.play.id != widget.play.id ||
        oldWidget.play.revisionId != widget.play.revisionId) {
      _session = _engine.start(widget.play);
    }
  }

  void _apply(PlayAction action) {
    if (_session.ended) return;
    final result = _engine.apply(_session, action);
    setState(() => _session = result.session);
    widget.onResolved?.call(result);
  }

  @override
  Widget build(BuildContext context) {
    final state = _session.state;
    final media = state.presentation
        .where((layer) => layer.role == 'media')
        .toList(growable: false);
    final text = state.presentation.where((layer) => layer.type == 'text');
    final isDragInput = state.input.type == PlayInputType.drag;
    final usesCanvasStage = media.any((layer) => layer.type == 'canvas');
    final input = _InputOverlay(
      input: state.input,
      validation: state.validation,
      inputEpoch: _session.attempts,
      onAction: _apply,
      onDirectManipulationChanged: widget.onDirectManipulationChanged,
    );

    return ColoredBox(
      color: MosaicVisualTokens.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final layer in media) _buildMedia(context, layer),
          SafeArea(child: _TextOverlay(layers: text.toList(growable: false))),
          if (isDragInput && usesCanvasStage)
            PlayCanvasStage(child: input)
          else if (isDragInput)
            input
          else
            SafeArea(child: input),
        ],
      ),
    );
  }

  Widget _buildMedia(BuildContext context, PresentationLayer layer) =>
      widget.mediaBuilder?.call(context, layer) ??
      PlayMediaUnavailable(type: layer.type);
}

final class _TextOverlay extends StatelessWidget {
  const _TextOverlay({required this.layers});
  final List<PresentationLayer> layers;

  @override
  Widget build(BuildContext context) {
    final primary = layers.where(
      (layer) => layer.role == 'prompt' || layer.role == 'scenario',
    );
    final reveal = layers.where(
      (layer) => layer.role == 'reveal_title' || layer.role == 'reveal_detail',
    );
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 160),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final layer in primary)
              Text(
                layer.value ?? '',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: MosaicVisualTokens.foreground,
                  fontWeight: FontWeight.w600,
                  height: 1.08,
                ),
              ),
            const Spacer(),
            for (final layer in reveal)
              Text(
                layer.value ?? '',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: MosaicVisualTokens.foreground,
                  fontWeight: layer.role == 'reveal_title'
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

PlayPianoInputSpec? _safePianoSpec(
  PlayInputDefinition input,
  PlayValidationDefinition validation,
) {
  if (validation.type != PlayValidatorType.orderedSequence) return null;
  final expectedRaw = validation.value;
  if (expectedRaw is! List ||
      expectedRaw.isEmpty ||
      expectedRaw.length > 16 ||
      expectedRaw.any((value) => value is! String || value.trim().isEmpty)) {
    return null;
  }

  final spec = PlayPianoInputSpec.fromDefinitions(input, validation);
  if (spec == null || spec.sequenceLength != expectedRaw.length) return null;
  final keys = spec.keys.toSet();
  if (expectedRaw.any((value) => !keys.contains(value))) return null;
  return spec;
}

PlayDragInputSpec? _safeDragSpec(
  PlayInputDefinition input,
  PlayValidationDefinition validation,
) {
  if (validation.type != PlayValidatorType.targetRegion) return null;
  final expectedRaw = validation.value;
  if (expectedRaw is! String || expectedRaw.trim().isEmpty) return null;

  final spec = PlayDragInputSpec.fromDefinition(input);
  if (spec == null ||
      !spec.targets.any((target) => target.id == expectedRaw.trim())) {
    return null;
  }

  for (var left = 0; left < spec.targets.length; left += 1) {
    for (var right = left + 1; right < spec.targets.length; right += 1) {
      if (_dragRectsOverlap(
        spec.targets[left].rect,
        spec.targets[right].rect,
      )) {
        return null;
      }
    }
  }
  return spec;
}

bool _dragRectsOverlap(PlayNormalizedRect left, PlayNormalizedRect right) =>
    left.x < right.x + right.width &&
    left.x + left.width > right.x &&
    left.y < right.y + right.height &&
    left.y + left.height > right.y;

final class _InputOverlay extends StatelessWidget {
  const _InputOverlay({
    required this.input,
    required this.validation,
    required this.inputEpoch,
    required this.onAction,
    this.onDirectManipulationChanged,
  });

  final PlayInputDefinition input;
  final PlayValidationDefinition validation;
  final int inputEpoch;
  final ValueChanged<PlayAction> onAction;
  final ValueChanged<bool>? onDirectManipulationChanged;

  @override
  Widget build(BuildContext context) {
    if (input.type == PlayInputType.tap) {
      return Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 20, bottom: 24),
          child: _ControlButton(
            label: input.label ?? 'Done',
            onPressed: () => onAction(const TapAction()),
          ),
        ),
      );
    }

    if (input.type == PlayInputType.singleChoice) {
      return Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in input.options)
                _ControlButton(
                  label: option.label,
                  onPressed: () => onAction(ChoiceAction(option.id)),
                ),
            ],
          ),
        ),
      );
    }

    if (input.type == PlayInputType.pianoKey) {
      final spec = _safePianoSpec(input, validation);
      if (spec == null) {
        return const PlayInputUnavailable(type: 'piano_key');
      }
      return Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 20),
          child: PlayPianoInput(
            key: ValueKey<String>('piano:$inputEpoch'),
            keys: spec.keys,
            sequenceLength: spec.sequenceLength,
            onSequence: (values) => onAction(SequenceAction(values)),
          ),
        ),
      );
    }

    if (input.type == PlayInputType.drag) {
      final spec = _safeDragSpec(input, validation);
      if (spec == null) {
        return const PlayInputUnavailable(type: 'drag');
      }
      return PlayDragInput(
        key: ValueKey<String>('drag:$inputEpoch'),
        spec: spec,
        onTarget: (targetId) => onAction(DragAction(targetId)),
        onManipulationChanged: onDirectManipulationChanged,
      );
    }

    return PlayInputUnavailable(type: input.type.name);
  }
}

final class _ControlButton extends StatelessWidget {
  const _ControlButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        foregroundColor: MosaicVisualTokens.foreground,
        backgroundColor: MosaicVisualTokens.controlSurface,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: const StadiumBorder(),
      ),
      child: Text(label),
    ),
  );
}
