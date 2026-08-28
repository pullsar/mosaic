library;

import 'package:play_schema/play_schema.dart';

sealed class PlayAction {
  const PlayAction();
}

final class TapAction extends PlayAction {
  const TapAction();
}

final class ChoiceAction extends PlayAction {
  const ChoiceAction(this.optionId);
  final String optionId;
}

final class SequenceAction extends PlayAction {
  const SequenceAction(this.values);
  final List<String> values;
}

final class DragAction extends PlayAction {
  const DragAction(this.targetId);
  final String targetId;
}

final class PlaySession {
  const PlaySession({
    required this.play,
    required this.stateId,
    required this.ended,
    required this.attempts,
  });

  final PlayDocument play;
  final String stateId;
  final bool ended;
  final int attempts;

  PlayStateDefinition get state {
    final value = play.states[stateId];
    if (value == null) throw StateError('Missing session state $stateId');
    return value;
  }
}

final class PlayResolution {
  const PlayResolution({
    required this.session,
    required this.outcome,
    this.wasCorrect,
  });

  final PlaySession session;
  final String outcome;
  final bool? wasCorrect;
}

final class PlayEngine {
  const PlayEngine();

  PlaySession start(PlayDocument play) => PlaySession(
    play: play,
    stateId: play.entryState,
    ended: false,
    attempts: 0,
  );

  PlayResolution apply(PlaySession session, PlayAction action) {
    if (session.ended) throw StateError('Cannot act on an ended Play.');
    _assertCompatible(session.state.input.type, action);

    final evaluation = _evaluate(session.state.validation, action);
    final transition =
        session.state.transitions[evaluation.outcome] ??
        session.state.transitions['default'];
    if (transition == null) {
      throw StateError(
        'No transition for outcome ${evaluation.outcome} in ${session.stateId}.',
      );
    }

    final ended = transition == r'$end';
    final nextStateId = ended ? session.stateId : transition;
    if (!ended && !session.play.states.containsKey(nextStateId)) {
      throw StateError('Transition points to missing state $nextStateId.');
    }

    return PlayResolution(
      session: PlaySession(
        play: session.play,
        stateId: nextStateId,
        ended: ended,
        attempts: session.attempts + 1,
      ),
      outcome: evaluation.outcome,
      wasCorrect: evaluation.wasCorrect,
    );
  }

  _Evaluation _evaluate(
    PlayValidationDefinition validation,
    PlayAction action,
  ) {
    final value = _actionValue(action);
    return switch (validation.type) {
      PlayValidatorType.none => _Evaluation(
        outcome: action is ChoiceAction ? action.optionId : 'default',
      ),
      PlayValidatorType.equals =>
        value == _equalsPayload(validation.value)
            ? const _Evaluation(outcome: 'correct', wasCorrect: true)
            : const _Evaluation(outcome: 'incorrect', wasCorrect: false),
      PlayValidatorType.orderedSequence =>
        _listEquals(
              value is List<String> ? value : const <String>[],
              _orderedSequencePayload(validation.value),
            )
            ? const _Evaluation(outcome: 'correct', wasCorrect: true)
            : const _Evaluation(outcome: 'incorrect', wasCorrect: false),
      PlayValidatorType.targetRegion =>
        value == _targetRegionPayload(validation.value)
            ? const _Evaluation(outcome: 'correct', wasCorrect: true)
            : const _Evaluation(outcome: 'incorrect', wasCorrect: false),
      _ => throw UnsupportedError(
        'Validator ${validation.type.name} is not executable in M1.',
      ),
    };
  }

  Object? _actionValue(PlayAction action) => switch (action) {
    TapAction() => null,
    ChoiceAction(:final optionId) => optionId,
    SequenceAction(:final values) => values,
    DragAction(:final targetId) => targetId,
  };

  void _assertCompatible(PlayInputType input, PlayAction action) {
    final compatible = switch (input) {
      PlayInputType.tap => action is TapAction,
      PlayInputType.singleChoice => action is ChoiceAction,
      PlayInputType.multipleChoice || PlayInputType.pianoKey =>
        action is SequenceAction || action is ChoiceAction,
      PlayInputType.drag => action is DragAction,
      _ => false,
    };
    if (!compatible) {
      throw StateError(
        'Action ${action.runtimeType} is incompatible with ${input.name}.',
      );
    }
  }
}

final class _Evaluation {
  const _Evaluation({required this.outcome, this.wasCorrect});
  final String outcome;
  final bool? wasCorrect;
}

Object _equalsPayload(Object? raw) {
  if (raw == null) {
    throw StateError('equals validation payload is malformed.');
  }
  return raw;
}

List<String> _orderedSequencePayload(Object? raw) {
  if (raw is! List ||
      raw.isEmpty ||
      raw.length > 16 ||
      raw.any((value) => value is! String || value.trim().isEmpty)) {
    throw StateError('ordered_sequence validation payload is malformed.');
  }
  return raw.cast<String>();
}

String _targetRegionPayload(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) {
    throw StateError('target_region validation payload is malformed.');
  }
  return raw;
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
