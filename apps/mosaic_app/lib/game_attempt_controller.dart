import 'dart:convert';

import 'package:crypto/crypto.dart';
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
  static const int maxRecoveryBytes = 64 * 1024;

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

  String? encodeRecoverySnapshot({required int capabilityVersion}) {
    if (completed || capabilityVersion < 1) return null;
    final encoded = jsonEncode(<String, Object?>{
      'version': 1,
      'playId': _session.play.id,
      'revisionId': _session.play.revisionId,
      'playHash': _playHash(_session.play),
      'capabilityVersion': capabilityVersion,
      'attemptId': _attemptId,
      'mode': _mode.wireName,
      'presentationStateId': _session.stateId,
      'actions': _actions.map(_encodeAction).toList(growable: false),
    });
    return utf8.encode(encoded).length <= maxRecoveryBytes ? encoded : null;
  }

  static GameAttemptController? restoreRecoverySnapshot({
    required PlayDocument play,
    required String encodedSnapshot,
    required int capabilityVersion,
  }) {
    if (capabilityVersion < 1 ||
        utf8.encode(encodedSnapshot).length > maxRecoveryBytes) {
      return null;
    }
    try {
      final decoded = jsonDecode(encodedSnapshot);
      if (decoded is! Map) return null;
      final snapshot = decoded.cast<String, Object?>();
      if (snapshot['version'] != 1 ||
          snapshot['playId'] != play.id ||
          snapshot['revisionId'] != play.revisionId ||
          snapshot['playHash'] != _playHash(play) ||
          snapshot['capabilityVersion'] != capabilityVersion) {
        return null;
      }
      final attemptId = snapshot['attemptId'];
      final mode = _modeFromWire(snapshot['mode']);
      final expectedStateId = snapshot['presentationStateId'];
      final rawActions = snapshot['actions'];
      if (attemptId is! String ||
          attemptId.trim().isEmpty ||
          attemptId.length > 200 ||
          mode == null ||
          expectedStateId is! String ||
          rawActions is! List ||
          rawActions.length > maxActions) {
        return null;
      }
      final controller = GameAttemptController(
        play: play,
        mode: mode,
        idFactory: () => attemptId,
      );
      for (final rawAction in rawActions) {
        final action = _decodeAction(rawAction);
        if (action == null || controller.completed) return null;
        controller.apply(action);
      }
      if (controller.completed ||
          controller.session.stateId != expectedStateId) {
        return null;
      }
      return controller;
    } on Object {
      return null;
    }
  }

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

  static String _playHash(PlayDocument play) =>
      sha256.convert(utf8.encode(jsonEncode(play.toJson()))).toString();

  static Map<String, Object?> _encodeAction(PlayAction action) =>
      switch (action) {
        TapAction() => const <String, Object?>{'type': 'tap'},
        ChoiceAction(:final optionId) => <String, Object?>{
          'type': 'choice',
          'optionId': optionId,
        },
        SequenceAction(:final values) => <String, Object?>{
          'type': 'sequence',
          'values': values,
        },
        DragAction(:final targetId) => <String, Object?>{
          'type': 'drag',
          'targetId': targetId,
        },
      };

  static PlayAction? _decodeAction(Object? raw) {
    if (raw is! Map) return null;
    final action = raw.cast<String, Object?>();
    return switch (action['type']) {
      'tap' => action.length == 1 ? const TapAction() : null,
      'choice' => _boundedActionText(action['optionId'], 'choice'),
      'drag' => _boundedActionText(action['targetId'], 'drag'),
      'sequence' => _sequenceAction(action['values']),
      _ => null,
    };
  }

  static PlayAction? _boundedActionText(Object? raw, String kind) {
    if (raw is! String || raw.trim().isEmpty || raw.length > 200) return null;
    return kind == 'choice' ? ChoiceAction(raw) : DragAction(raw);
  }

  static PlayAction? _sequenceAction(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.length > 16) return null;
    final values = <String>[];
    for (final value in raw) {
      if (value is! String || value.trim().isEmpty || value.length > 200) {
        return null;
      }
      values.add(value);
    }
    return SequenceAction(values);
  }

  static GameAttemptMode? _modeFromWire(Object? raw) => switch (raw) {
    'first' => GameAttemptMode.first,
    'practice' => GameAttemptMode.practice,
    'challenge' => GameAttemptMode.challenge,
    _ => null,
  };
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
