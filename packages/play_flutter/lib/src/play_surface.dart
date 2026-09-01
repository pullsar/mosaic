import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:play_engine/play_engine.dart';
import 'package:play_schema/play_schema.dart';

import 'play_canvas_renderer.dart';
import 'play_input_primitives.dart';
import 'play_media_layer_renderer.dart';
import 'play_viewport_composition.dart';
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final mediaQuery = MediaQuery.maybeOf(context);
      final composition =
          PlayViewportScope.maybeOf(context) ??
          PlayViewportComposition.fromConstraints(
            constraints,
            safeInsets: mediaQuery?.padding ?? EdgeInsets.zero,
            textScaler: mediaQuery?.textScaler ?? TextScaler.noScaling,
          );
      final state = _session.state;
      final media = state.presentation
          .where((layer) => layer.role == 'media')
          .toList(growable: false);
      final mediaSlots = _mediaSlots(media);
      final text = state.presentation
          .where((layer) => layer.type == 'text')
          .toList(growable: false);
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
            Positioned.fromRect(
              rect: composition.promptRect,
              child: SizedBox.expand(
                key: const ValueKey<String>('play-prompt'),
                child: _TextOverlay(layers: text),
              ),
            ),
            Positioned.fromRect(
              rect: composition.stageRect,
              child: SizedBox.expand(
                key: const ValueKey<String>('play-stage'),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final slot in mediaSlots)
                      KeyedSubtree(
                        key: ValueKey<String>(slot.key),
                        child: _buildMedia(context, slot.layer),
                      ),
                    if (isDragInput)
                      if (usesCanvasStage)
                        PlayCanvasStage(child: input)
                      else
                        input,
                  ],
                ),
              ),
            ),
            Positioned.fromRect(
              rect: composition.inputRect,
              child: SizedBox.expand(
                key: const ValueKey<String>('play-input'),
                child: isDragInput ? const SizedBox.shrink() : input,
              ),
            ),
            Positioned.fromRect(
              rect: composition.utilityRect,
              child: const IgnorePointer(
                child: SizedBox.expand(
                  key: ValueKey<String>('play-utilities-region'),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _buildMedia(BuildContext context, PresentationLayer layer) =>
      widget.mediaBuilder?.call(context, layer) ??
      PlayMediaUnavailable(type: layer.type);

  List<_MediaSlot> _mediaSlots(List<PresentationLayer> layers) {
    final occurrences = <String, int>{};
    final result = <_MediaSlot>[];
    for (final layer in layers) {
      final identity = '${layer.type}:${layer.assetId}';
      final occurrence = occurrences[identity] ?? 0;
      occurrences[identity] = occurrence + 1;
      result.add(
        _MediaSlot(
          layer: layer,
          key: 'play-media:${widget.play.id}:${widget.play.revisionId}:'
              '$identity:$occurrence',
        ),
      );
    }
    return result;
  }
}

final class _MediaSlot {
  const _MediaSlot({required this.layer, required this.key});

  final PresentationLayer layer;
  final String key;
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
    final visibleLayers = <PresentationLayer>[...primary, ...reveal];
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final contentKey = ValueKey<String>(
      visibleLayers
          .map((layer) => '${layer.role}:${layer.value}')
          .join('|'),
    );
    final content = _BoundedTextViewport(
      key: contentKey,
      layers: visibleLayers,
      reduceMotion: reduceMotion,
    );

    return ClipRect(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 8),
        child: AnimatedSwitcher(
          duration: reduceMotion
              ? Duration.zero
              : MosaicVisualTokens.revealTransition,
          transitionBuilder: (child, animation) {
            if (reduceMotion) return child;
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: MosaicVisualTokens.revealDisplacement,
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            );
          },
          child: content,
        ),
      ),
    );
  }
}

final class _BoundedTextViewport extends StatefulWidget {
  const _BoundedTextViewport({
    required this.layers,
    required this.reduceMotion,
    super.key,
  });

  final List<PresentationLayer> layers;
  final bool reduceMotion;

  @override
  State<_BoundedTextViewport> createState() => _BoundedTextViewportState();
}

final class _BoundedTextViewportState extends State<_BoundedTextViewport> {
  final ScrollController _controller = ScrollController();
  bool _metricsCheckScheduled = false;
  bool _hasOverflow = false;
  bool _atEnd = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleMetricsCheck() {
    if (_metricsCheckScheduled) return;
    _metricsCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsCheckScheduled = false;
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      final hasOverflow = position.maxScrollExtent > 0;
      final atEnd =
          hasOverflow && position.pixels >= position.maxScrollExtent - 0.5;
      if (_hasOverflow == hasOverflow && _atEnd == atEnd) return;
      setState(() {
        _hasOverflow = hasOverflow;
        _atEnd = atEnd;
      });
    });
  }

  Future<void> _advance() async {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = _atEnd
        ? 0.0
        : math.min(
            position.maxScrollExtent,
            position.pixels + position.viewportDimension * 0.8,
          );
    if (widget.reduceMotion) {
      _controller.jumpTo(target);
    } else {
      await _controller.animateTo(
        target,
        duration: MosaicVisualTokens.revealTransition,
        curve: Curves.easeOutCubic,
      );
    }
    _scheduleMetricsCheck();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMetricsCheck();
    return Stack(
      fit: StackFit.expand,
      children: [
        SingleChildScrollView(
          key: const ValueKey<String>('play-text-scroll'),
          controller: _controller,
          physics: const NeverScrollableScrollPhysics(),
          primary: false,
          child: Padding(
            padding: EdgeInsetsDirectional.only(end: _hasOverflow ? 48 : 0),
            child: _TextGroup(layers: widget.layers),
          ),
        ),
        if (_hasOverflow)
          Align(
            alignment: AlignmentDirectional.bottomEnd,
            child: IconButton(
              key: const ValueKey<String>('play-text-more'),
              tooltip: _atEnd ? 'Back to reveal start' : 'More reveal detail',
              onPressed: _advance,
              icon: Icon(
                _atEnd
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
              ),
            ),
          ),
      ],
    );
  }
}

final class _TextGroup extends StatelessWidget {
  const _TextGroup({required this.layers, super.key});

  final List<PresentationLayer> layers;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.topStart,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < layers.length; index += 1) ...[
          if (index > 0) const SizedBox(height: 4),
          Text(
            layers[index].value ?? '',
            textAlign: TextAlign.start,
            style: _textStyle(context, layers[index]),
          ),
        ],
      ],
    ),
  );

  TextStyle? _textStyle(BuildContext context, PresentationLayer layer) {
    final isDetail = layer.role == 'reveal_detail';
    return (isDetail
            ? Theme.of(context).textTheme.bodyLarge
            : Theme.of(context).textTheme.headlineSmall)
        ?.copyWith(
          color: isDetail
              ? MosaicVisualTokens.secondary
              : MosaicVisualTokens.foreground,
          fontWeight: isDetail ? FontWeight.w400 : FontWeight.w600,
          height: 1.08,
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
        alignment: AlignmentDirectional.centerEnd,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 8),
          child: _ControlButton(
            label: input.label ?? 'Done',
            onPressed: () => onAction(const TapAction()),
          ),
        ),
      );
    }

    if (input.type == PlayInputType.singleChoice) {
      return Align(
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              key: const ValueKey<String>('play-choice-scroll'),
              primary: false,
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (
                      var index = 0;
                      index < input.options.length;
                      index += 1
                    )
                      Padding(
                        padding: EdgeInsetsDirectional.only(
                          end: index + 1 == input.options.length ? 0 : 8,
                        ),
                        child: _ControlButton(
                          label: input.options[index].label,
                          onPressed: () => onAction(
                            ChoiceAction(input.options[index].id),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
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
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
        semanticTargetId: validation.value as String,
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
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        shape: const StadiumBorder(),
      ),
      child: Text(label),
    ),
  );
}
