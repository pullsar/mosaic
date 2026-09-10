import 'package:event_delivery/event_delivery.dart';
import 'package:flutter/widgets.dart';
import 'package:play_engine/play_engine.dart';
import 'package:play_schema/play_schema.dart';

enum GameAttemptMode { first, practice, challenge }

extension GameAttemptModeWire on GameAttemptMode {
  String get wireName => name;
}

final class AttemptLease {
  int _generation = 0;

  int get generation => _generation;

  int invalidate() => ++_generation;

  bool accepts(int captured) => captured == _generation;
}

typedef AttemptIdFactory = String Function();

final class GameAttemptController extends ChangeNotifier {
  GameAttemptController({
    required PlayDocument play,
    GameAttemptMode mode = GameAttemptMode.first,
    AttemptIdFactory idFactory = secureUuidV4,
    PlayEngine engine = const PlayEngine(),
  }) : _engine = engine,
       _idFactory = idFactory,
       _mode = mode,
       _attemptId = _nextId(idFactory),
       _session = engine.start(play);

  static const int maxActions = 128;

  final PlayEngine _engine;
  final AttemptIdFactory _idFactory;
  final AttemptLease _lease = AttemptLease();
  final List<PlayAction> _actions = <PlayAction>[];
  late String _attemptId;
  late GameAttemptMode _mode;
  late PlaySession _session;
  PlayResolution? _lastResolution;

  String get attemptId => _attemptId;
  GameAttemptMode get mode => _mode;
  PlaySession get session => _session;
  PlayResolution? get lastResolution => _lastResolution;
  bool get completed => _session.ended;
  List<PlayAction> get actions => List<PlayAction>.unmodifiable(_actions);

  ValueChanged<PlayAction> captureActionHandler({
    ValueChanged<PlayResolution>? onResolved,
  }) {
    final capturedId = _attemptId;
    final capturedGeneration = _lease.generation;
    return (action) {
      if (capturedId != _attemptId || !_lease.accepts(capturedGeneration)) {
        return;
      }
      final resolution = apply(action);
      onResolved?.call(resolution);
    };
  }

  PlayResolution apply(PlayAction action) {
    if (_actions.length >= maxActions) {
      throw StateError('Attempt action limit reached.');
    }
    final resolution = _engine.apply(_session, action);
    _actions.add(action);
    _session = resolution.session;
    _lastResolution = resolution;
    notifyListeners();
    return resolution;
  }

  void replay({GameAttemptMode mode = GameAttemptMode.practice}) {
    _lease.invalidate();
    _attemptId = _nextId(_idFactory);
    _mode = mode;
    _session = _engine.start(_session.play);
    _actions.clear();
    _lastResolution = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _lease.invalidate();
    super.dispose();
  }

  static String _nextId(AttemptIdFactory factory) {
    final value = factory().trim();
    if (value.isEmpty || value.length > 200) {
      throw StateError('Attempt ID must be 1 to 200 characters.');
    }
    return value;
  }
}

typedef GameAttemptBuilder =
    Widget Function(BuildContext context, GameAttemptController controller);

final class GameAttemptHost extends StatefulWidget {
  const GameAttemptHost({
    required this.play,
    required this.builder,
    this.mode = GameAttemptMode.first,
    this.idFactory = secureUuidV4,
    super.key,
  });

  final PlayDocument play;
  final GameAttemptMode mode;
  final AttemptIdFactory idFactory;
  final GameAttemptBuilder builder;

  @override
  State<GameAttemptHost> createState() => _GameAttemptHostState();
}

final class _GameAttemptHostState extends State<GameAttemptHost> {
  late GameAttemptController _controller;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  @override
  void didUpdateWidget(covariant GameAttemptHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.play.id != widget.play.id ||
        oldWidget.play.revisionId != widget.play.revisionId) {
      _controller.dispose();
      _createController();
    }
  }

  void _createController() {
    _controller = GameAttemptController(
      play: widget.play,
      mode: widget.mode,
      idFactory: widget.idFactory,
    )..addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}
