import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:play_schema/play_schema.dart';

final class PlayPianoInputSpec {
  const PlayPianoInputSpec({
    required this.keys,
    required this.sequenceLength,
  });

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
    super.key,
  });

  final List<String> keys;
  final int sequenceLength;
  final ValueChanged<List<String>> onSequence;

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
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: 'Piano keyboard',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
          SizedBox(
            height: 104,
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
  }
}

final class _PianoKey extends StatelessWidget {
  const _PianoKey({
    required this.note,
    required this.selected,
    required this.onPressed,
  });

  final String note;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sharp = note.contains('#') || note.contains('♯');
    final baseBackground = sharp
        ? colorScheme.onSurface
        : colorScheme.surface;
    final baseForeground = sharp
        ? colorScheme.surface
        : colorScheme.onSurface;
    final background = selected
        ? colorScheme.primaryContainer
        : baseBackground;
    final foreground = selected
        ? colorScheme.onPrimaryContainer
        : baseForeground;
    final display = _displayNote(note);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Semantics(
        button: true,
        label: note,
        child: Material(
          color: background,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: colorScheme.outlineVariant),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(8),
            ),
          ),
          child: InkWell(
            onTap: onPressed,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(8),
            ),
            child: SizedBox(
              width: 46,
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
  const PlayDragTarget({required this.id, required this.rect});

  final String id;
  final PlayNormalizedRect rect;
}

final class PlayDragInputSpec {
  const PlayDragInputSpec({
    required this.origin,
    required this.size,
    required this.targets,
    this.handleLabel = 'Move item',
    this.showTargetHints = false,
  });

  final Offset origin;
  final Size size;
  final List<PlayDragTarget> targets;
  final String handleLabel;
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
    final showTargetHints = input.properties['showTargetHints'] == true;

    return PlayDragInputSpec(
      origin: origin,
      size: size,
      targets: List<PlayDragTarget>.unmodifiable(targets),
      handleLabel: handleLabel,
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

final class _PlayDragInputState extends State<PlayDragInput> {
  late Offset _position = widget.spec.origin;
  int? _activePointer;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant PlayDragInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.spec, widget.spec)) {
      _position = widget.spec.origin;
      _activePointer = null;
      _setDragging(false, notify: false);
    }
  }

  void _setDragging(bool value, {bool notify = true}) {
    if (_dragging == value) return;
    _dragging = value;
    if (notify) widget.onManipulationChanged?.call(value);
  }

  void _pointerDown(PointerDownEvent event) {
    if (_activePointer != null) return;
    _activePointer = event.pointer;
    _setDragging(true);
  }

  void _pointerEnded(PointerEvent event) {
    if (_activePointer != event.pointer) return;
    _activePointer = null;
    _setDragging(false);
  }

  void _move(DragUpdateDetails details, Size bounds) {
    if (bounds.width <= 0 || bounds.height <= 0) return;
    final maxX = 1 - widget.spec.size.width;
    final maxY = 1 - widget.spec.size.height;
    setState(() {
      _position = Offset(
        (_position.dx + details.delta.dx / bounds.width)
            .clamp(0.0, maxX)
            .toDouble(),
        (_position.dy + details.delta.dy / bounds.height)
            .clamp(0.0, maxY)
            .toDouble(),
      );
    });
  }

  void _finish() {
    final center = Offset(
      _position.dx + widget.spec.size.width / 2,
      _position.dy + widget.spec.size.height / 2,
    );
    PlayDragTarget? target;
    for (final candidate in widget.spec.targets) {
      if (candidate.rect.contains(center)) {
        target = candidate;
        break;
      }
    }

    _setDragging(false);
    if (target != null) {
      widget.onTarget(target.id);
      return;
    }
    setState(() => _position = widget.spec.origin);
  }

  void _cancel() {
    _activePointer = null;
    _setDragging(false);
    setState(() => _position = widget.spec.origin);
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
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
          Positioned(
            left: _position.dx * bounds.width,
            top: _position.dy * bounds.height,
            width: widget.spec.size.width * bounds.width,
            height: widget.spec.size.height * bounds.height,
            child: Semantics(
              button: true,
              label: widget.spec.handleLabel,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _pointerDown,
                onPointerUp: _pointerEnded,
                onPointerCancel: _pointerEnded,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) => _move(details, bounds),
                  onPanEnd: (_) => _finish(),
                  onPanCancel: _cancel,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Icon(
                      Icons.drag_indicator,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
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
    final x = _unit(item['x']);
    final y = _unit(item['y']);
    final width = _positiveUnit(item['width']);
    final height = _positiveUnit(item['height']);
    if (x == null || y == null || width == null || height == null) return null;
    if (x + width > 1 || y + height > 1) return null;
    targets.add(
      PlayDragTarget(
        id: id,
        rect: PlayNormalizedRect(
          x: x,
          y: y,
          width: width,
          height: height,
        ),
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
