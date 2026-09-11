import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:play_engine/play_engine.dart';
import 'package:play_schema/play_schema.dart';

import 'play_canvas_renderer.dart';
import 'play_input_primitives.dart';
import 'play_media_layer_renderer.dart';
import 'play_scene_renderer.dart';
import 'play_viewport_composition.dart';
import 'visual_tokens.dart';

typedef PlayMediaBuilder =
    Widget Function(BuildContext context, PresentationLayer layer);

final class PlaySurface extends StatefulWidget {
  const PlaySurface({
    required this.play,
    this.mediaBuilder,
    this.onResolved,
    this.terminal,
    this.onDirectManipulationChanged,
    super.key,
  }) : session = null,
       onAction = null;

  PlaySurface.controlled({
    required PlaySession session,
    required ValueChanged<PlayAction> onAction,
    this.mediaBuilder,
    this.onResolved,
    this.terminal,
    this.onDirectManipulationChanged,
    super.key,
  }) : play = session.play,
       session = session,
       onAction = onAction;

  final PlayDocument play;
  final PlaySession? session;
  final ValueChanged<PlayAction>? onAction;
  final PlayMediaBuilder? mediaBuilder;
  final ValueChanged<PlayResolution>? onResolved;
  final Widget? terminal;

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
  PlaySession? _ownedSession;

  bool get _isControlled => widget.session != null;

  PlaySession get _session => widget.session ?? _ownedSession!;

  @override
  void initState() {
    super.initState();
    if (!_isControlled) _ownedSession = _engine.start(widget.play);
  }

  @override
  void didUpdateWidget(covariant PlaySurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasControlled = oldWidget.session != null;
    if (wasControlled != _isControlled) {
      throw FlutterError(
        'Changing PlaySurface session ownership requires a new widget identity.',
      );
    }
    if (!_isControlled &&
        (oldWidget.play.id != widget.play.id ||
            oldWidget.play.revisionId != widget.play.revisionId)) {
      _ownedSession = _engine.start(widget.play);
    }
  }

  void _apply(PlayAction action) {
    if (_session.ended) return;
    final delegated = widget.onAction;
    if (delegated != null) {
      delegated(action);
      return;
    }
    final result = _engine.apply(_session, action);
    setState(() => _ownedSession = result.session);
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
      final isPieceMoveInput = state.input.type == PlayInputType.pieceMove;
      final usesCanvasStage = media.any((layer) => layer.type == 'canvas');
      final input = _InputOverlay(
        input: state.input,
        validation: state.validation,
        // A direct terminal drag keeps the placed object from its final input.
        inputEpoch: _session.attempts - (isDragInput && _session.ended ? 1 : 0),
        onAction: _apply,
        onDirectManipulationChanged: widget.onDirectManipulationChanged,
      );
      final dragPresentation = IgnorePointer(
        ignoring: _session.ended,
        child: ExcludeFocus(
          excluding: _session.ended,
          child: ExcludeSemantics(excluding: _session.ended, child: input),
        ),
      );

      return ColoredBox(
        color: MosaicVisualTokens.surface,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _PlayThemeBackdrop(presentation: widget.play.presentation),
            Positioned.fromRect(
              rect: composition.promptRect,
              child: SizedBox.expand(
                key: const ValueKey<String>('play-prompt'),
                child: _TextOverlay(layers: text),
              ),
            ),
            Positioned.fromRect(
              rect: composition.stageRect,
              child: _StageFeedback(
                resolved: _session.ended,
                animateScale: !isDragInput,
                child: _StageStateTransition(
                  stateId: _session.stateId,
                  child: SizedBox.expand(
                    key: const ValueKey<String>('play-stage'),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        for (final slot in mediaSlots)
                          KeyedSubtree(
                            key: ValueKey<String>(slot.key),
                            child:
                                slot.layer.type == 'scene' &&
                                    slot.layer.scene != null
                                ? IgnorePointer(
                                    ignoring: _session.ended,
                                    child: PlaySceneRenderer(
                                      scene: slot.layer.scene!,
                                      placements: _session.piecePlacements,
                                      onPieceMove: (pieceId, targetId) =>
                                          _apply(
                                            PieceMoveAction(
                                              pieceId: pieceId,
                                              targetId: targetId,
                                            ),
                                          ),
                                      onDirectManipulationChanged:
                                          widget.onDirectManipulationChanged,
                                    ),
                                  )
                                : _buildMedia(context, slot.layer),
                          ),
                        if (isDragInput)
                          if (usesCanvasStage)
                            PlayCanvasStage(child: dragPresentation)
                          else
                            dragPresentation,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: composition.inputRect,
              child: SizedBox.expand(
                key: const ValueKey<String>('play-input'),
                child: _session.ended
                    ? _terminalOrEmpty(widget.terminal)
                    : isDragInput || isPieceMoveInput
                    ? const SizedBox.shrink()
                    : input,
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
          key:
              'play-media:${widget.play.id}:${widget.play.revisionId}:'
              '$identity:$occurrence',
        ),
      );
    }
    return result;
  }
}

/// A frozen, low-cost visual treatment selected when the immutable Play was
/// prepared. It deliberately uses no time, random state, or user preference:
/// replaying a revision retains the same visual identity.
final class _PlayThemeBackdrop extends StatelessWidget {
  const _PlayThemeBackdrop({required this.presentation});

  final PlayPresentationReference? presentation;

  @override
  Widget build(BuildContext context) {
    final reference = presentation;
    if (reference == null) return const SizedBox.expand();
    final color = _themeSurface(reference);
    if (color == null) return const SizedBox.expand();
    return RepaintBoundary(
      child: ColoredBox(
        key: ValueKey<String>(
          'play-theme-backdrop:${reference.themeId}:'
          '${reference.themeRevisionId}:${reference.variantId}',
        ),
        color: color,
      ),
    );
  }
}

Color? _themeSurface(PlayPresentationReference reference) => switch ((
  reference.themeId,
  reference.themeRevisionId,
  reference.variantId,
)) {
  ('paper-studio', 'theme_1', 'felt-ivory') => const Color(0xFF302821),
  ('night-museum', 'theme_1', 'ceramic-night') => const Color(0xFF111216),
  ('glass-garden', 'theme_1', 'mineral-mist') => const Color(0xFF102C30),
  ('orbital', 'theme_1', 'onyx-orbit') => const Color(0xFF0B1020),
  _ => null,
};

final class _StageFeedback extends StatelessWidget {
  const _StageFeedback({
    required this.resolved,
    required this.animateScale,
    required this.child,
  });
  final bool resolved;
  final bool animateScale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final accent = Theme.of(context).colorScheme.primary;
    return RepaintBoundary(
      child: AnimatedScale(
        scale: resolved && animateScale ? 1.012 : 1,
        duration: reduced ? Duration.zero : MosaicVisualTokens.fastFeedback,
        curve: Curves.easeOutBack,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(26), child: child),
            IgnorePointer(
              child: AnimatedContainer(
                duration: reduced
                    ? Duration.zero
                    : MosaicVisualTokens.fastFeedback,
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: resolved
                        ? accent.withValues(alpha: .72)
                        : Colors.transparent,
                    width: 2,
                  ),
                  boxShadow: resolved && !reduced
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: .20),
                            blurRadius: 18,
                          ),
                        ]
                      : const [],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Gives an authored scene change one immediate visual beat without keeping a
/// previous media tree alive. The state key resets only when the deterministic
/// engine advances, so retries inside the same state remain stable.
final class _StageStateTransition extends StatefulWidget {
  const _StageStateTransition({required this.stateId, required this.child});

  final String stateId;
  final Widget child;

  @override
  State<_StageStateTransition> createState() => _StageStateTransitionState();
}

final class _StageStateTransitionState extends State<_StageStateTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _opacity;

  @override
  void initState() {
    super.initState();
    _opacity = AnimationController(
      value: 1,
      duration: MosaicVisualTokens.revealTransition,
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(covariant _StageStateTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stateId == widget.stateId) return;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _opacity.value = 1;
    } else {
      unawaited(_opacity.forward(from: .78));
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return FadeTransition(
      key: const ValueKey<String>('play-stage-state-transition'),
      opacity: reduced ? const AlwaysStoppedAnimation<double>(1) : _opacity,
      child: widget.child,
    );
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
      visibleLayers.map((layer) => '${layer.role}:${layer.value}').join('|'),
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
          layoutBuilder: (currentChild, previousChildren) => Stack(
            fit: StackFit.expand,
            children: [
              for (final child in previousChildren)
                Positioned.fill(child: child),
              if (currentChild != null) Positioned.fill(child: currentChild),
            ],
          ),
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
  const _TextGroup({required this.layers});

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
            ? Theme.of(context).textTheme.bodySmall
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
            builder: (context, constraints) {
              final useVerticalFlow =
                  constraints.maxHeight > constraints.maxWidth;
              Widget buildButton(int index) {
                final button = _ControlButton(
                  label: input.options[index].label,
                  compact: useVerticalFlow,
                  onPressed: () =>
                      onAction(ChoiceAction(input.options[index].id)),
                );
                return useVerticalFlow
                    ? SizedBox(width: constraints.maxWidth, child: button)
                    : button;
              }

              final buttons = <Widget>[
                for (var index = 0; index < input.options.length; index += 1)
                  buildButton(index),
              ];
              final content = useVerticalFlow
                  ? Wrap(
                      key: const ValueKey<String>('play-choice-vertical-flow'),
                      direction: Axis.vertical,
                      alignment: WrapAlignment.center,
                      runAlignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: buttons,
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var index = 0; index < buttons.length; index += 1)
                          Padding(
                            padding: EdgeInsetsDirectional.only(
                              end: index + 1 == buttons.length ? 0 : 8,
                            ),
                            child: buttons[index],
                          ),
                      ],
                    );
              final constrainedContent = ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: constraints.maxWidth,
                  minHeight: useVerticalFlow ? constraints.maxHeight : 0,
                ),
                child: content,
              );
              return SingleChildScrollView(
                key: const ValueKey<String>('play-choice-scroll'),
                primary: false,
                scrollDirection: Axis.horizontal,
                child: constrainedContent,
              );
            },
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
        onTarget: (targetId) => onAction(DragAction(targetId)),
        onManipulationChanged: onDirectManipulationChanged,
      );
    }

    return PlayInputUnavailable(type: input.type.name);
  }
}

final class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.label,
    required this.onPressed,
    this.compact = false,
  });
  final String label;
  final VoidCallback onPressed;
  final bool compact;

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
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 18,
          vertical: 10,
        ),
        shape: const StadiumBorder(),
      ),
      child: compact
          ? Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )
          : Text(label),
    ),
  );
}

Widget _terminalOrEmpty(Widget? terminal) =>
    terminal ?? const SizedBox.shrink();
