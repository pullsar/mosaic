import 'package:flutter/material.dart';
import 'package:play_engine/play_engine.dart';
import 'package:play_schema/play_schema.dart';

import 'play_input_primitives.dart';
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

  void _apply(PlayAction action) {
    if (_session.ended) return;
    final result = _engine.apply(_session, action);
    setState(() => _session = result.session);
    widget.onResolved?.call(result);
  }

  @override
  Widget build(BuildContext context) {
    final state = _session.state;
    final media = state.presentation.where((layer) => layer.role == 'media');
    final text = state.presentation.where((layer) => layer.type == 'text');

    return ColoredBox(
      color: MosaicVisualTokens.surface,
      child: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (final layer in media) _buildMedia(context, layer),
            _TextOverlay(layers: text.toList(growable: false)),
            _InputOverlay(
              input: state.input,
              validation: state.validation,
              inputEpoch: _session.attempts,
              onAction: _apply,
              onDirectManipulationChanged:
                  widget.onDirectManipulationChanged,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMedia(BuildContext context, PresentationLayer layer) =>
      widget.mediaBuilder?.call(context, layer) ?? const SizedBox.expand();
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
      return Positioned(
        right: 20,
        bottom: 24,
        child: _ControlButton(
          label: input.label ?? 'Done',
          onPressed: () => onAction(const TapAction()),
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
      final spec = PlayPianoInputSpec.fromDefinitions(input, validation);
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
      final spec = PlayDragInputSpec.fromDefinition(input);
      if (spec == null) {
        return const PlayInputUnavailable(type: 'drag');
      }
      return Positioned.fill(
        child: PlayDragInput(
          key: ValueKey<String>('drag:$inputEpoch'),
          spec: spec,
          onTarget: (targetId) => onAction(DragAction(targetId)),
          onManipulationChanged: onDirectManipulationChanged,
        ),
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
