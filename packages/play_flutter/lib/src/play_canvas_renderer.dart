import 'dart:async';

import 'package:flutter/material.dart';

String _requireCanvasText(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}

double _unit(double value, String name) {
  if (!value.isFinite || value < 0 || value > 1) {
    throw RangeError.range(value, 0, 1, name);
  }
  return value;
}

double _positiveUnit(double value, String name) {
  if (!value.isFinite || value <= 0 || value > 1) {
    throw RangeError.range(value, 0, 1, name);
  }
  return value;
}

sealed class PlayCanvasElement {
  const PlayCanvasElement();
}

final class PlayCanvasLine extends PlayCanvasElement {
  PlayCanvasLine({
    required this.start,
    required this.end,
    this.width = 0.012,
    this.cap = StrokeCap.round,
    this.tone = PlayCanvasTone.foreground,
  }) : start = Offset(
         _unit(start.dx, 'start.dx'),
         _unit(start.dy, 'start.dy'),
       ),
       end = Offset(_unit(end.dx, 'end.dx'), _unit(end.dy, 'end.dy')),
       width = _positiveUnit(width, 'width');

  final Offset start;
  final Offset end;
  final double width;
  final StrokeCap cap;
  final PlayCanvasTone tone;
}

final class PlayCanvasRect extends PlayCanvasElement {
  PlayCanvasRect({
    required this.rect,
    this.strokeWidth = 0.008,
    this.radius = 0.02,
    this.fill = false,
    this.tone = PlayCanvasTone.foreground,
  }) : rect = Rect.fromLTWH(
         _unit(rect.left, 'rect.left'),
         _unit(rect.top, 'rect.top'),
         _positiveUnit(rect.width, 'rect.width'),
         _positiveUnit(rect.height, 'rect.height'),
       ),
       strokeWidth = _positiveUnit(strokeWidth, 'strokeWidth'),
       radius = _unit(radius, 'radius') {
    if (this.rect.right > 1 || this.rect.bottom > 1) {
      throw ArgumentError.value(rect, 'rect', 'must remain inside the canvas');
    }
  }

  final Rect rect;
  final double strokeWidth;
  final double radius;
  final bool fill;
  final PlayCanvasTone tone;
}

final class PlayCanvasCircle extends PlayCanvasElement {
  PlayCanvasCircle({
    required this.center,
    required this.radius,
    this.strokeWidth = 0.008,
    this.fill = false,
    this.tone = PlayCanvasTone.foreground,
  }) : center = Offset(
         _unit(center.dx, 'center.dx'),
         _unit(center.dy, 'center.dy'),
       ),
       radius = _positiveUnit(radius, 'radius'),
       strokeWidth = _positiveUnit(strokeWidth, 'strokeWidth') {
    if (this.center.dx - this.radius < 0 ||
        this.center.dx + this.radius > 1 ||
        this.center.dy - this.radius < 0 ||
        this.center.dy + this.radius > 1) {
      throw ArgumentError.value(
        center,
        'center',
        'circle must remain inside the canvas',
      );
    }
  }

  final Offset center;
  final double radius;
  final double strokeWidth;
  final bool fill;
  final PlayCanvasTone tone;
}

final class PlayCanvasLabel extends PlayCanvasElement {
  PlayCanvasLabel({
    required this.position,
    required String text,
    this.scale = 0.08,
    this.tone = PlayCanvasTone.foreground,
    this.anchor = Alignment.center,
  }) : position = Offset(
         _unit(position.dx, 'position.dx'),
         _unit(position.dy, 'position.dy'),
       ),
       text = _requireCanvasText(text, 'text'),
       scale = _positiveUnit(scale, 'scale');

  final Offset position;
  final String text;
  final double scale;
  final PlayCanvasTone tone;
  final Alignment anchor;
}

enum PlayCanvasTone { foreground, muted, accent, surface }

final class PlayCanvasAsset {
  PlayCanvasAsset({
    required String id,
    required List<PlayCanvasElement> elements,
    String? semanticLabel,
  }) : id = _requireCanvasText(id, 'id'),
       elements = List<PlayCanvasElement>.unmodifiable(elements),
       semanticLabel = semanticLabel == null
           ? null
           : _requireCanvasText(semanticLabel, 'semanticLabel') {
    if (this.elements.isEmpty) {
      throw ArgumentError.value(elements, 'elements', 'must not be empty');
    }
  }

  final String id;
  final List<PlayCanvasElement> elements;
  final String? semanticLabel;
}

abstract interface class PlayCanvasAssetResolver {
  Future<PlayCanvasAsset?> resolve(String assetId);
}

typedef PlayCanvasLookup = FutureOr<PlayCanvasAsset?> Function(String assetId);

final class CallbackPlayCanvasAssetResolver implements PlayCanvasAssetResolver {
  const CallbackPlayCanvasAssetResolver(this.lookup);

  final PlayCanvasLookup lookup;

  @override
  Future<PlayCanvasAsset?> resolve(String assetId) =>
      Future<PlayCanvasAsset?>.sync(() => lookup(assetId));
}

final class MapPlayCanvasAssetResolver implements PlayCanvasAssetResolver {
  MapPlayCanvasAssetResolver(Map<String, PlayCanvasAsset> assets)
    : _assets = Map<String, PlayCanvasAsset>.unmodifiable(assets);

  final Map<String, PlayCanvasAsset> _assets;

  @override
  Future<PlayCanvasAsset?> resolve(String assetId) async => _assets[assetId];
}

final class ResolvedPlayCanvas extends StatefulWidget {
  const ResolvedPlayCanvas({
    required this.assetId,
    required this.resolver,
    super.key,
  });

  final String assetId;
  final PlayCanvasAssetResolver resolver;

  @override
  State<ResolvedPlayCanvas> createState() => _ResolvedPlayCanvasState();
}

final class _ResolvedPlayCanvasState extends State<ResolvedPlayCanvas> {
  late Future<PlayCanvasAsset?> _resolution;

  @override
  void initState() {
    super.initState();
    _resolution = _resolve();
  }

  @override
  void didUpdateWidget(covariant ResolvedPlayCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId != widget.assetId ||
        oldWidget.resolver != widget.resolver) {
      _resolution = _resolve();
    }
  }

  Future<PlayCanvasAsset?> _resolve() async {
    final id = widget.assetId.trim();
    if (id.isEmpty) return null;
    final asset = await widget.resolver.resolve(id);
    if (asset != null && asset.id != id) {
      throw StateError('Resolver returned ${asset.id} while resolving $id.');
    }
    return asset;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlayCanvasAsset?>(
    future: _resolution,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const _CanvasState(label: 'Loading interactive graphic');
      }
      final asset = snapshot.data;
      if (snapshot.hasError || asset == null) {
        return const PlayCanvasUnavailable();
      }
      return PlayCanvas(asset: asset);
    },
  );
}

final class PlayCanvas extends StatelessWidget {
  const PlayCanvas({required this.asset, super.key});

  final PlayCanvasAsset asset;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = CustomPaint(
      painter: _PlayCanvasPainter(asset: asset, colorScheme: colorScheme),
      size: Size.infinite,
      isComplex: false,
      willChange: false,
    );
    final label = asset.semanticLabel;
    return RepaintBoundary(
      child: label == null
          ? ExcludeSemantics(child: content)
          : Semantics(image: true, label: label, child: content),
    );
  }
}

final class _PlayCanvasPainter extends CustomPainter {
  const _PlayCanvasPainter({required this.asset, required this.colorScheme});

  final PlayCanvasAsset asset;
  final ColorScheme colorScheme;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final shortest = size.shortestSide;
    for (final element in asset.elements) {
      switch (element) {
        case PlayCanvasLine():
          final paint = Paint()
            ..color = _color(element.tone)
            ..strokeWidth = element.width * shortest
            ..strokeCap = element.cap
            ..style = PaintingStyle.stroke;
          canvas.drawLine(
            _point(element.start, size),
            _point(element.end, size),
            paint,
          );
        case PlayCanvasRect():
          final rect = Rect.fromLTWH(
            element.rect.left * size.width,
            element.rect.top * size.height,
            element.rect.width * size.width,
            element.rect.height * size.height,
          );
          final paint = Paint()
            ..color = _color(element.tone)
            ..strokeWidth = element.strokeWidth * shortest
            ..style = element.fill ? PaintingStyle.fill : PaintingStyle.stroke;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              rect,
              Radius.circular(element.radius * shortest),
            ),
            paint,
          );
        case PlayCanvasCircle():
          final paint = Paint()
            ..color = _color(element.tone)
            ..strokeWidth = element.strokeWidth * shortest
            ..style = element.fill ? PaintingStyle.fill : PaintingStyle.stroke;
          canvas.drawCircle(
            _point(element.center, size),
            element.radius * shortest,
            paint,
          );
        case PlayCanvasLabel():
          final painter = TextPainter(
            text: TextSpan(
              text: element.text,
              style: TextStyle(
                color: _color(element.tone),
                fontSize: element.scale * shortest,
                fontWeight: FontWeight.w600,
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout(maxWidth: size.width);
          final point = _point(element.position, size);
          final offset = Offset(
            point.dx - painter.width * (element.anchor.x + 1) / 2,
            point.dy - painter.height * (element.anchor.y + 1) / 2,
          );
          painter.paint(canvas, offset);
      }
    }
  }

  Offset _point(Offset normalized, Size size) =>
      Offset(normalized.dx * size.width, normalized.dy * size.height);

  Color _color(PlayCanvasTone tone) => switch (tone) {
    PlayCanvasTone.foreground => colorScheme.onSurface,
    PlayCanvasTone.muted => colorScheme.onSurfaceVariant,
    PlayCanvasTone.accent => colorScheme.primary,
    PlayCanvasTone.surface => colorScheme.surfaceContainerHighest,
  };

  @override
  bool shouldRepaint(covariant _PlayCanvasPainter oldDelegate) =>
      !identical(asset, oldDelegate.asset) || colorScheme != oldDelegate.colorScheme;
}

final class PlayCanvasUnavailable extends StatelessWidget {
  const PlayCanvasUnavailable({super.key});

  @override
  Widget build(BuildContext context) => const _CanvasState(
    label: 'Interactive graphic unavailable',
    icon: Icons.grid_off_outlined,
  );
}

final class _CanvasState extends StatelessWidget {
  const _CanvasState({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Semantics(
      image: true,
      label: label,
      child: Center(
        child: ExcludeSemantics(
          child: icon == null
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon),
        ),
      ),
    ),
  );
}
