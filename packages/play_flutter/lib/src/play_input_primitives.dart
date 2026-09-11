import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:play_schema/play_schema.dart';

import 'visual_tokens.dart';

/// A small, bounded visual beat. Completion is reported to the deterministic
/// engine by the owning surface; this widget never changes Play state itself.
final class PlayTimedCueInput extends StatefulWidget {
  const PlayTimedCueInput({
    required this.duration,
    required this.cueId,
    required this.ordinal,
    required this.onElapsed,
    this.onProgress,
    super.key,
  });

  final Duration duration;
  final String cueId;
  final int ordinal;
  final VoidCallback onElapsed;
  final ValueChanged<double>? onProgress;

  @override
  State<PlayTimedCueInput> createState() => _PlayTimedCueInputState();
}

final class _PlayTimedCueInputState extends State<PlayTimedCueInput>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;
  Timer? _completion;
  bool _started = false;
  bool? _reducedMotion;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this)..addListener(_rebuild);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!_started) {
      _reducedMotion = reduced;
      _start();
    } else if (_reducedMotion != reduced) {
      _reducedMotion = reduced;
      if (reduced) {
        _progress.stop();
      } else {
        unawaited(_progress.forward(from: _progress.value));
      }
    }
  }

  @override
  void didUpdateWidget(covariant PlayTimedCueInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) _start();
  }

  void _start() {
    _started = true;
    _completion?.cancel();
    _progress
      ..stop()
      ..duration = widget.duration
      ..value = 0;
    _reportProgress(0);
    if (!(_reducedMotion ?? false)) {
      unawaited(_progress.forward());
    }
    _completion = Timer(widget.duration, () {
      if (!mounted) return;
      _reportProgress(1);
      widget.onElapsed();
    });
  }

  void _rebuild() {
    _reportProgress(_progress.value);
    if (mounted) setState(() {});
  }

  void _reportProgress(double value) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onProgress?.call(value);
    });
  }

  @override
  void dispose() {
    _completion?.cancel();
    _progress
      ..removeListener(_rebuild)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Semantics(
      label: 'Brief cue',
      liveRegion: true,
      child: RepaintBoundary(
        child: SizedBox(
          key: const ValueKey<String>('play-timed-cue'),
          width: 64,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: reduced ? 1 : _progress.value,
              minHeight: 4,
              color: Theme.of(context).colorScheme.primary,
              backgroundColor: MosaicVisualTokens.controlSurface,
            ),
          ),
        ),
      ),
    );
  }
}

final class PlayMultipleChoiceInput extends StatefulWidget {
  const PlayMultipleChoiceInput({
    required this.options,
    required this.onSubmit,
    super.key,
  });

  final List<PlayOption> options;
  final ValueChanged<List<String>> onSubmit;

  @override
  State<PlayMultipleChoiceInput> createState() =>
      _PlayMultipleChoiceInputState();
}

final class _PlayMultipleChoiceInputState
    extends State<PlayMultipleChoiceInput> {
  final Set<String> _selected = <String>{};

  void _toggle(String id, bool selected) => setState(() {
    if (selected) {
      _selected.add(id);
    } else {
      _selected.remove(id);
    }
  });

  void _submit() {
    if (_selected.isEmpty) return;
    widget.onSubmit(
      List<String>.unmodifiable([
        for (final option in widget.options)
          if (_selected.contains(option.id)) option.id,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Semantics(
      container: true,
      label: 'Multiple choice',
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final option in widget.options)
                      AnimatedScale(
                        key: ValueKey<String>(
                          'multiple-choice-motion:${option.id}',
                        ),
                        scale: _selected.contains(option.id) ? 1.04 : 1,
                        duration: reduced
                            ? Duration.zero
                            : MosaicVisualTokens.fastFeedback,
                        curve: Curves.easeOutBack,
                        child: Padding(
                          padding: const EdgeInsetsDirectional.only(end: 8),
                          child: ChoiceChip(
                            label: Text(option.label),
                            selected: _selected.contains(option.id),
                            onSelected: (selected) =>
                                _toggle(option.id, selected),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Tooltip(
              message: 'Submit selection',
              child: Semantics(
                button: true,
                label: 'Submit selection',
                child: FilledButton(
                  onPressed: _selected.isEmpty ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.square(48),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Icon(Icons.check_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class PlayPianoInputSpec {
  const PlayPianoInputSpec({required this.keys, required this.sequenceLength});

  final List<String> keys;
  final int sequenceLength;

  static PlayPianoInputSpec? fromDefinitions(
    PlayInputDefinition input,
    PlayValidationDefinition validation,
  ) {
    if (input.type != PlayInputType.pianoKey) return null;

    final rawKeys = input.properties['keys'];
    final keys = rawKeys == null
        ? MosaicPianoInputDefaults.keys
        : _readUniqueStrings(rawKeys);
    if (keys == null || keys.isEmpty) return null;

    final configuredLength = input.properties['sequenceLength'];
    final expected = validation.value;
    final inferredLength =
        validation.type == PlayValidatorType.orderedSequence && expected is List
        ? expected.length
        : null;
    final sequenceLength = configuredLength is int
        ? configuredLength
        : inferredLength ?? 1;
    if (sequenceLength < 1 || sequenceLength > 16) return null;

    return PlayPianoInputSpec(
      keys: List<String>.unmodifiable(keys),
      sequenceLength: sequenceLength,
    );
  }
}

final class PlayPianoInput extends StatefulWidget {
  const PlayPianoInput({
    required this.keys,
    required this.sequenceLength,
    required this.onSequence,
    this.onNote,
    super.key,
  });

  final List<String> keys;
  final int sequenceLength;
  final ValueChanged<List<String>> onSequence;

  /// Runs at pointer-down for a physical key press, before score submission.
  ///
  /// A future sound session can use this to start a matching preloaded note
  /// while the immutable [onSequence] path remains authoritative for scoring.
  final ValueChanged<String>? onNote;

  @override
  State<PlayPianoInput> createState() => _PlayPianoInputState();
}

final class _PlayPianoInputState extends State<PlayPianoInput> {
  final List<String> _sequence = <String>[];
  String? _lastKey;
  bool _locked = false;

  @override
  void didUpdateWidget(covariant PlayPianoInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sequenceLength != widget.sequenceLength ||
        !listEquals(oldWidget.keys, widget.keys)) {
      _reset();
    }
  }

  void _reset() {
    _sequence.clear();
    _lastKey = null;
    _locked = false;
  }

  void _press(String note) {
    if (_locked) return;
    final completed = _sequence.length + 1 >= widget.sequenceLength;
    widget.onNote?.call(note);
    setState(() {
      _sequence.add(note);
      _lastKey = note;
      _locked = completed;
    });
    if (completed) {
      widget.onSequence(List<String>.unmodifiable(_sequence));
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colorScheme = Theme.of(context).colorScheme;
      final availableHeight = constraints.hasBoundedHeight
          ? constraints.maxHeight
          : 118.0;
      final showProgress = availableHeight >= 70;
      final reservedHeight = showProgress ? 14.0 : 0.0;
      final keyboardHeight = math
          .min(104.0, math.max(48.0, availableHeight - reservedHeight))
          .toDouble();

      return Semantics(
        container: true,
        label: 'Piano keyboard',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showProgress) ...[
              SizedBox(
                height: 6,
                child: Center(
                  child: Wrap(
                    spacing: 4,
                    children: List<Widget>.generate(
                      widget.sequenceLength,
                      (index) => DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: index < _sequence.length
                              ? colorScheme.primary
                              : colorScheme.outlineVariant,
                        ),
                        child: const SizedBox.square(dimension: 5),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              height: keyboardHeight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final note in widget.keys)
                      _PianoKey(
                        note: note,
                        selected: note == _lastKey,
                        onPressed: _locked ? null : () => _press(note),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

final class _PianoKey extends StatefulWidget {
  const _PianoKey({
    required this.note,
    required this.selected,
    required this.onPressed,
  });

  final String note;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  State<_PianoKey> createState() => _PianoKeyState();
}

final class _PianoKeyState extends State<_PianoKey> {
  bool _pressed = false;
  bool _activatedFromPointer = false;

  void _activate() {
    final callback = widget.onPressed;
    if (callback == null) return;
    callback();
  }

  void _onTapDown(TapDownDetails details) {
    if (widget.onPressed == null) return;
    _activatedFromPointer = true;
    setState(() => _pressed = true);
    _activate();
  }

  void _onTapUp(TapUpDetails details) {
    if (mounted) setState(() => _pressed = false);
  }

  void _onTapCancel() {
    _activatedFromPointer = false;
    if (mounted) setState(() => _pressed = false);
  }

  void _onTap() {
    if (_activatedFromPointer) {
      _activatedFromPointer = false;
      return;
    }
    _activate();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sharp = widget.note.contains('#') || widget.note.contains('♯');
    final baseBackground = sharp ? colorScheme.onSurface : colorScheme.surface;
    final baseForeground = sharp ? colorScheme.surface : colorScheme.onSurface;
    final background = widget.selected
        ? colorScheme.primaryContainer
        : baseBackground;
    final foreground = widget.selected
        ? colorScheme.onPrimaryContainer
        : baseForeground;
    final display = _displayNote(widget.note);
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Semantics(
        button: true,
        label: widget.note,
        excludeSemantics: true,
        child: AnimatedScale(
          key: ValueKey<String>('play-piano-key:${widget.note}'),
          scale: _pressed ? .97 : 1,
          duration: reduced ? Duration.zero : MosaicVisualTokens.fastFeedback,
          curve: Curves.easeOutCubic,
          child: Material(
            color: background,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: colorScheme.outlineVariant),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(8),
              ),
            ),
            child: InkWell(
              onTap: widget.onPressed == null ? null : _onTap,
              onTapDown: _onTapDown,
              onTapUp: _onTapUp,
              onTapCancel: _onTapCancel,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(8),
              ),
              child: SizedBox(
                width: 48,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      display,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: foreground),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class PlayNormalizedRect {
  const PlayNormalizedRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  bool contains(Offset point) =>
      point.dx >= x &&
      point.dx <= x + width &&
      point.dy >= y &&
      point.dy <= y + height;
}

final class PlayDragTarget {
  const PlayDragTarget({required this.id, required this.rect, this.label});

  final String id;
  final PlayNormalizedRect rect;
  final String? label;
}

enum PlayDragHandleStyle { rounded, matchstick }

final class PlayDragInputSpec {
  const PlayDragInputSpec({
    required this.origin,
    required this.size,
    required this.targets,
    this.handleLabel = 'Move item',
    this.handleStyle = PlayDragHandleStyle.rounded,
    this.showTargetHints = false,
  });

  final Offset origin;
  final Size size;
  final List<PlayDragTarget> targets;
  final String handleLabel;
  final PlayDragHandleStyle handleStyle;
  final bool showTargetHints;

  static PlayDragInputSpec? fromDefinition(PlayInputDefinition input) {
    if (input.type != PlayInputType.drag) return null;

    final origin = _readPoint(input.properties['dragOrigin']);
    final size = _readSize(input.properties['dragSize']);
    final targets = _readTargets(input.properties['targets']);
    if (origin == null || size == null || targets == null || targets.isEmpty) {
      return null;
    }
    if (origin.dx + size.width > 1 || origin.dy + size.height > 1) {
      return null;
    }

    final rawLabel = input.properties['handleLabel'];
    final handleLabel = rawLabel is String && rawLabel.trim().isNotEmpty
        ? rawLabel.trim()
        : 'Move item';
    final handleStyle = switch (input.properties['handleStyle']) {
      null || 'rounded' => PlayDragHandleStyle.rounded,
      'matchstick' => PlayDragHandleStyle.matchstick,
      _ => null,
    };
    if (handleStyle == null) return null;
    final showTargetHints = input.properties['showTargetHints'] == true;

    return PlayDragInputSpec(
      origin: origin,
      size: size,
      targets: List<PlayDragTarget>.unmodifiable(targets),
      handleLabel: handleLabel,
      handleStyle: handleStyle,
      showTargetHints: showTargetHints,
    );
  }
}

final class PlayDragInput extends StatefulWidget {
  const PlayDragInput({
    required this.spec,
    required this.onTarget,
    this.onManipulationChanged,
    super.key,
  });

  final PlayDragInputSpec spec;
  final ValueChanged<String> onTarget;
  final ValueChanged<bool>? onManipulationChanged;

  @override
  State<PlayDragInput> createState() => _PlayDragInputState();
}

final class _PlayDragInputState extends State<PlayDragInput>
    with SingleTickerProviderStateMixin {
  late final AnimationController _returnMotion;
  Offset? _returnFrom;
  late Offset _position = widget.spec.origin;
  int? _activePointer;
  bool _dragging = false;
  String? _hoveredTargetId;
  int _selectedTargetIndex = 0;
  bool _selectingTarget = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _returnMotion = AnimationController(
      vsync: this,
      duration: MosaicVisualTokens.fastFeedback,
    )..addListener(_tickReturn);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_returnMotion.isAnimating &&
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
      _returnMotion.stop();
      _position = widget.spec.origin;
    }
  }

  @override
  void didUpdateWidget(covariant PlayDragInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragSpecsEquivalent(oldWidget.spec, widget.spec)) {
      _returnMotion.stop();
      _endInterruptedManipulation(oldWidget.onManipulationChanged);
      _position = widget.spec.origin;
      _activePointer = null;
      _hoveredTargetId = null;
      _selectedTargetIndex = 0;
      _selectingTarget = false;
    }
  }

  @override
  void dispose() {
    _returnMotion.dispose();
    _activePointer = null;
    _endInterruptedManipulation(widget.onManipulationChanged);
    super.dispose();
  }

  void _endInterruptedManipulation(ValueChanged<bool>? callback) {
    if (!_dragging) return;
    _dragging = false;
    if (callback != null) {
      scheduleMicrotask(() => callback(false));
    }
  }

  void _setDragging(bool value, {bool notify = true}) {
    if (_dragging == value) return;
    setState(() => _dragging = value);
    if (notify) widget.onManipulationChanged?.call(value);
  }

  void _pointerDown(PointerDownEvent event) {
    if (_activePointer != null) return;
    _returnMotion.stop();
    setState(() => _activePointer = event.pointer);
    _setDragging(true);
  }

  void _pointerEnded(PointerEvent event) {
    if (_activePointer != event.pointer) return;
    setState(() => _activePointer = null);
    _setDragging(false);
  }

  void _move(DragUpdateDetails details, Size bounds) {
    if (bounds.width <= 0 || bounds.height <= 0) return;
    final maxX = 1 - widget.spec.size.width;
    final maxY = 1 - widget.spec.size.height;
    final next = Offset(
      (_position.dx + details.delta.dx / bounds.width)
          .clamp(0.0, maxX)
          .toDouble(),
      (_position.dy + details.delta.dy / bounds.height)
          .clamp(0.0, maxY)
          .toDouble(),
    );
    setState(() {
      _position = next;
      _hoveredTargetId = _targetAt(next)?.id;
    });
  }

  void _finish() {
    final target = _targetAt(_position);

    _setDragging(false);
    if (target != null) {
      widget.onTarget(target.id);
      return;
    }
    _returnToOrigin();
  }

  void _returnToOrigin() {
    _returnMotion.stop();
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      setState(() {
        _position = widget.spec.origin;
        _hoveredTargetId = null;
      });
      return;
    }
    setState(() => _hoveredTargetId = null);
    _returnFrom = _position;
    unawaited(_returnMotion.forward(from: 0));
  }

  PlayDragTarget? _targetAt(Offset position) {
    final center = Offset(
      position.dx + widget.spec.size.width / 2,
      position.dy + widget.spec.size.height / 2,
    );
    for (final candidate in widget.spec.targets) {
      if (candidate.rect.contains(center)) return candidate;
    }
    return null;
  }

  void _tickReturn() {
    final from = _returnFrom;
    if (from == null) return;
    setState(
      () => _position = Offset.lerp(
        from,
        widget.spec.origin,
        Curves.easeOutCubic.transform(_returnMotion.value),
      )!,
    );
  }

  void _cancel() {
    _activePointer = null;
    _setDragging(false);
    setState(() {
      _selectingTarget = false;
      _hoveredTargetId = null;
    });
    _returnToOrigin();
  }

  void _beginAlternateSelection() {
    if (_selectingTarget) return;
    _returnMotion.stop();
    setState(() => _selectingTarget = true);
  }

  void _cancelAlternateSelection() {
    if (!_selectingTarget) return;
    setState(() => _selectingTarget = false);
  }

  void _submitAlternateTarget(int index) {
    _returnMotion.stop();
    final target = widget.spec.targets[index];
    final targetPosition = Offset(
      target.rect.x + (target.rect.width - widget.spec.size.width) / 2,
      target.rect.y + (target.rect.height - widget.spec.size.height) / 2,
    );
    setState(() {
      _selectedTargetIndex = index;
      _selectingTarget = false;
      _hoveredTargetId = null;
      _position = Offset(
        targetPosition.dx.clamp(0.0, 1 - widget.spec.size.width).toDouble(),
        targetPosition.dy.clamp(0.0, 1 - widget.spec.size.height).toDouble(),
      );
    });
    widget.onTarget(target.id);
  }

  void _selectTarget(int delta) {
    final next = (_selectedTargetIndex + delta)
        .clamp(0, widget.spec.targets.length - 1)
        .toInt();
    if (next == _selectedTargetIndex) return;
    setState(() => _selectedTargetIndex = next);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      _selectTarget(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      _selectTarget(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      if (_selectingTarget) {
        _submitAlternateTarget(_selectedTargetIndex);
      } else {
        _beginAlternateSelection();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _cancelAlternateSelection();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final bounds = Size(constraints.maxWidth, constraints.maxHeight);
      if (!bounds.width.isFinite ||
          !bounds.height.isFinite ||
          bounds.width <= 0 ||
          bounds.height <= 0) {
        return const SizedBox.shrink();
      }

      final colorScheme = Theme.of(context).colorScheme;
      final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (widget.spec.showTargetHints)
            for (final target in widget.spec.targets)
              Positioned(
                left: target.rect.x * bounds.width,
                top: target.rect.y * bounds.height,
                width: target.rect.width * bounds.width,
                height: target.rect.height * bounds.height,
                child: IgnorePointer(
                  key: ValueKey<String>('play-drag-target:${target.id}'),
                  child: ExcludeSemantics(
                    child: AnimatedContainer(
                      key: ValueKey<String>(
                        'play-drag-target-glow:${target.id}',
                      ),
                      duration: reduced
                          ? Duration.zero
                          : MosaicVisualTokens.fastFeedback,
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _hoveredTargetId == target.id
                              ? colorScheme.primary
                              : colorScheme.outlineVariant,
                          width: _hoveredTargetId == target.id ? 2 : 1,
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: _hoveredTargetId == target.id && !reduced
                            ? <BoxShadow>[
                                BoxShadow(
                                  color: colorScheme.primary.withValues(
                                    alpha: .22,
                                  ),
                                  blurRadius: 12,
                                ),
                              ]
                            : const <BoxShadow>[],
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
          if (_focused || _selectingTarget)
            _selectedTargetIndicator(bounds, colorScheme),
          _dragHandle(bounds, colorScheme),
          if (_selectingTarget)
            for (var index = 0; index < widget.spec.targets.length; index += 1)
              _alternateTargetButton(index, bounds, colorScheme),
        ],
      );
    },
  );

  Widget _alternateTargetButton(
    int index,
    Size bounds,
    ColorScheme colorScheme,
  ) {
    final target = widget.spec.targets[index];
    final selected = index == _selectedTargetIndex;
    final visual = _targetVisualRect(target, bounds);
    final hit = _touchRect(visual, bounds);
    return Positioned(
      key: ValueKey<String>('play-drag-alternate-target:${target.id}'),
      left: hit.left,
      top: hit.top,
      width: hit.width,
      height: hit.height,
      child: Semantics(
        button: true,
        label: _dragTargetLabel(target),
        value: 'target ${index + 1} of ${widget.spec.targets.length}',
        onTap: () => _submitAlternateTarget(index),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _submitAlternateTarget(
            _nearestTarget(details.localPosition + hit.topLeft, bounds),
          ),
          child: Stack(
            children: [
              Positioned.fromRect(
                rect: visual.shift(-hit.topLeft),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: selected
                          ? colorScheme.primary
                          : colorScheme.outlineVariant,
                      width: selected ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Expanded touch regions can overlap. Visible geometry takes precedence;
  // otherwise select the nearest eligible destination, independent of z-order.
  int _nearestTarget(Offset point, Size bounds) {
    var nearest = _selectedTargetIndex;
    var distance = double.infinity;
    for (var index = 0; index < widget.spec.targets.length; index++) {
      final visual = _targetVisualRect(widget.spec.targets[index], bounds);
      if (visual.contains(point)) return index;
      if (!_touchRect(visual, bounds).contains(point)) continue;
      final candidateDistance = (point - visual.center).distanceSquared;
      if (candidateDistance < distance) {
        nearest = index;
        distance = candidateDistance;
      }
    }
    return nearest;
  }

  Rect _targetVisualRect(PlayDragTarget target, Size bounds) => Rect.fromLTWH(
    target.rect.x * bounds.width,
    target.rect.y * bounds.height,
    target.rect.width * bounds.width,
    target.rect.height * bounds.height,
  );

  Rect _touchRect(Rect visual, Size bounds) {
    final width = math.min(bounds.width, math.max(48.0, visual.width));
    final height = math.min(bounds.height, math.max(48.0, visual.height));
    return Rect.fromLTWH(
      (visual.center.dx - width / 2).clamp(0.0, bounds.width - width),
      (visual.center.dy - height / 2).clamp(0.0, bounds.height - height),
      width,
      height,
    );
  }

  Widget _selectedTargetIndicator(Size bounds, ColorScheme colorScheme) {
    final target = widget.spec.targets[_selectedTargetIndex];
    return Positioned(
      key: const ValueKey<String>('play-drag-selected-target-slot'),
      left: target.rect.x * bounds.width,
      top: target.rect.y * bounds.height,
      width: target.rect.width * bounds.width,
      height: target.rect.height * bounds.height,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: DecoratedBox(
            key: const ValueKey<String>('play-drag-selected-target'),
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dragHandle(Size bounds, ColorScheme colorScheme) {
    final visualRect = Rect.fromLTWH(
      _position.dx * bounds.width,
      _position.dy * bounds.height,
      widget.spec.size.width * bounds.width,
      widget.spec.size.height * bounds.height,
    );
    final hitWidth = math.min(bounds.width, math.max(48.0, visualRect.width));
    final hitHeight = math.min(
      bounds.height,
      math.max(48.0, visualRect.height),
    );
    final hitLeft = (visualRect.center.dx - hitWidth / 2)
        .clamp(0.0, bounds.width - hitWidth)
        .toDouble();
    final hitTop = (visualRect.center.dy - hitHeight / 2)
        .clamp(0.0, bounds.height - hitHeight)
        .toDouble();
    final hitRect = Rect.fromLTWH(hitLeft, hitTop, hitWidth, hitHeight);
    final localVisualRect = visualRect.shift(-hitRect.topLeft);
    final horizontalMatchstick =
        widget.spec.handleStyle == PlayDragHandleStyle.matchstick &&
        visualRect.width > visualRect.height;
    final targetCount = widget.spec.targets.length;
    final increasedTargetIndex = math.min(
      _selectedTargetIndex + 1,
      targetCount - 1,
    );
    final decreasedTargetIndex = math.max(_selectedTargetIndex - 1, 0);

    return Positioned.fromRect(
      key: const ValueKey<String>('play-drag-handle-slot'),
      rect: hitRect,
      child: Focus(
        onKeyEvent: _handleKeyEvent,
        onFocusChange: (focused) {
          if (_focused == focused) return;
          setState(() => _focused = focused);
        },
        child: Semantics(
          button: true,
          focusable: true,
          label: widget.spec.handleLabel,
          value: targetCount > 1
              ? _dragTargetSemanticValue(
                  widget.spec.targets[_selectedTargetIndex],
                  _selectedTargetIndex,
                  targetCount,
                )
              : null,
          increasedValue: targetCount > 1
              ? _dragTargetSemanticValue(
                  widget.spec.targets[increasedTargetIndex],
                  increasedTargetIndex,
                  targetCount,
                )
              : null,
          decreasedValue: targetCount > 1
              ? _dragTargetSemanticValue(
                  widget.spec.targets[decreasedTargetIndex],
                  decreasedTargetIndex,
                  targetCount,
                )
              : null,
          onTap: _beginAlternateSelection,
          onIncrease: targetCount > 1 ? () => _selectTarget(1) : null,
          onDecrease: targetCount > 1 ? () => _selectTarget(-1) : null,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _pointerDown,
            onPointerUp: _pointerEnded,
            onPointerCancel: _pointerEnded,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _beginAlternateSelection,
              onPanUpdate: (details) => _move(details, bounds),
              onPanEnd: (_) => _finish(),
              onPanCancel: _cancel,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fromRect(
                    rect: localVisualRect,
                    child: AnimatedScale(
                      key: const ValueKey<String>('play-drag-object-motion'),
                      scale:
                          _dragging &&
                              !(MediaQuery.maybeOf(
                                    context,
                                  )?.disableAnimations ??
                                  false)
                          ? 1.06
                          : 1,
                      duration: MosaicVisualTokens.fastFeedback,
                      curve: Curves.easeOutBack,
                      child: DecoratedBox(
                        key: const ValueKey<String>('play-drag-object'),
                        decoration: BoxDecoration(
                          color:
                              widget.spec.handleStyle ==
                                  PlayDragHandleStyle.matchstick
                              ? const Color(0xFFC9783E)
                              : colorScheme.primaryContainer,
                          border: Border.all(
                            color:
                                widget.spec.handleStyle ==
                                    PlayDragHandleStyle.matchstick
                                ? const Color(0xFF7A3E20)
                                : colorScheme.onPrimaryContainer,
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(
                            visualRect.shortestSide / 2,
                          ),
                          boxShadow:
                              _dragging &&
                                  !(MediaQuery.maybeOf(
                                        context,
                                      )?.disableAnimations ??
                                      false)
                              ? <BoxShadow>[
                                  BoxShadow(
                                    color: colorScheme.onSurface.withValues(
                                      alpha: .18,
                                    ),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ]
                              : const <BoxShadow>[],
                        ),
                        child:
                            widget.spec.handleStyle ==
                                PlayDragHandleStyle.matchstick
                            ? Align(
                                alignment: horizontalMatchstick
                                    ? Alignment.centerRight
                                    : Alignment.topCenter,
                                child: FractionallySizedBox(
                                  widthFactor: horizontalMatchstick ? .2 : .78,
                                  heightFactor: horizontalMatchstick ? .78 : .2,
                                  child: DecoratedBox(
                                    key: const ValueKey<String>(
                                      'play-drag-matchstick-head',
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
                            : null,
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
}

bool _dragSpecsEquivalent(PlayDragInputSpec left, PlayDragInputSpec right) {
  if (left.origin != right.origin ||
      left.size != right.size ||
      left.handleLabel != right.handleLabel ||
      left.handleStyle != right.handleStyle ||
      left.showTargetHints != right.showTargetHints ||
      left.targets.length != right.targets.length) {
    return false;
  }
  for (var index = 0; index < left.targets.length; index += 1) {
    final leftTarget = left.targets[index];
    final rightTarget = right.targets[index];
    if (leftTarget.id != rightTarget.id ||
        leftTarget.label != rightTarget.label ||
        !_normalizedRectsEquivalent(leftTarget.rect, rightTarget.rect)) {
      return false;
    }
  }
  return true;
}

bool _normalizedRectsEquivalent(
  PlayNormalizedRect left,
  PlayNormalizedRect right,
) =>
    left.x == right.x &&
    left.y == right.y &&
    left.width == right.width &&
    left.height == right.height;

String _dragTargetSemanticValue(PlayDragTarget target, int index, int count) =>
    '${_dragTargetLabel(target)}, target ${index + 1} of $count';

String _dragTargetLabel(PlayDragTarget target) {
  final authored = target.label?.trim();
  if (authored != null && authored.isNotEmpty) return authored;

  final centerX = target.rect.x + target.rect.width / 2;
  final centerY = target.rect.y + target.rect.height / 2;
  final isLeft = centerX < 1 / 3;
  final isRight = centerX > 2 / 3;

  if (centerY < 1 / 3) {
    if (isLeft) return 'Upper left area';
    if (isRight) return 'Upper right area';
    return 'Upper area';
  }
  if (centerY > 2 / 3) {
    if (isLeft) return 'Lower left area';
    if (isRight) return 'Lower right area';
    return 'Lower area';
  }
  if (isLeft) return 'Left area';
  if (isRight) return 'Right area';
  return 'Center area';
}

final class PlayInputUnavailable extends StatelessWidget {
  const PlayInputUnavailable({required this.type, super.key});

  final String type;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Semantics(
        label: 'Unsupported input: $type',
        child: Icon(
          Icons.touch_app_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

List<String>? _readUniqueStrings(Object? raw) {
  if (raw is! List) return null;
  final values = <String>[];
  final seen = <String>{};
  for (final item in raw) {
    if (item is! String) return null;
    final normalized = item.trim();
    if (normalized.isEmpty || !seen.add(normalized)) return null;
    values.add(normalized);
  }
  return values;
}

Offset? _readPoint(Object? raw) {
  if (raw is! Map) return null;
  final x = _unit(raw['x']);
  final y = _unit(raw['y']);
  return x == null || y == null ? null : Offset(x, y);
}

Size? _readSize(Object? raw) {
  if (raw is! Map) return null;
  final width = _positiveUnit(raw['width']);
  final height = _positiveUnit(raw['height']);
  return width == null || height == null ? null : Size(width, height);
}

List<PlayDragTarget>? _readTargets(Object? raw) {
  if (raw is! List) return null;
  final targets = <PlayDragTarget>[];
  final ids = <String>{};
  for (final item in raw) {
    if (item is! Map) return null;
    final idRaw = item['id'];
    if (idRaw is! String) return null;
    final id = idRaw.trim();
    if (id.isEmpty || !ids.add(id)) return null;
    final labelRaw = item['label'];
    final label = labelRaw is String && labelRaw.trim().isNotEmpty
        ? labelRaw.trim()
        : null;
    final x = _unit(item['x']);
    final y = _unit(item['y']);
    final width = _positiveUnit(item['width']);
    final height = _positiveUnit(item['height']);
    if (x == null || y == null || width == null || height == null) return null;
    if (x + width > 1 || y + height > 1) return null;
    targets.add(
      PlayDragTarget(
        id: id,
        label: label,
        rect: PlayNormalizedRect(x: x, y: y, width: width, height: height),
      ),
    );
  }
  return targets;
}

double? _unit(Object? raw) {
  if (raw is! num) return null;
  final value = raw.toDouble();
  if (!value.isFinite || value < 0 || value > 1) return null;
  return value;
}

double? _positiveUnit(Object? raw) {
  final value = _unit(raw);
  return value == null || value <= 0 ? null : value;
}

String _displayNote(String note) {
  final withoutOctave = note.replaceAll(RegExp(r'\d+$'), '');
  return withoutOctave.replaceAll('#', '♯');
}
