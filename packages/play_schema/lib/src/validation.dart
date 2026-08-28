import 'capability.dart';
import 'interaction_defaults.dart';
import 'model.dart';

enum PlayValidationSeverity { error, warning }

final class PlayValidationIssue {
  const PlayValidationIssue({
    required this.code,
    required this.path,
    required this.message,
    this.severity = PlayValidationSeverity.error,
  });

  final String code;
  final String path;
  final String message;
  final PlayValidationSeverity severity;
}

abstract final class MosaicCopyPolicy {
  static const int promptWords = 14;
  static const int scenarioWords = 24;
  static const int revealDetailWords = 30;
  static const int metadataWords = 12;
}

final class PlaySchemaValidator {
  const PlaySchemaValidator();

  List<PlayValidationIssue> validate(PlayDocument play) {
    final issues = <PlayValidationIssue>[];

    if (!PlaySchemaSupport.supports(play.schemaVersion)) {
      issues.add(
        PlayValidationIssue(
          code: 'schema_version',
          path: 'schemaVersion',
          message: 'schemaVersion ${play.schemaVersion} is not supported.',
        ),
      );
    }
    if (play.id.isEmpty || play.revisionId.isEmpty) {
      issues.add(
        const PlayValidationIssue(
          code: 'identity_required',
          path: 'id',
          message: 'Play and revision identifiers are required.',
        ),
      );
    }
    if (play.estimatedDurationSec <= 0 || play.estimatedDurationSec > 180) {
      issues.add(
        const PlayValidationIssue(
          code: 'duration_range',
          path: 'estimatedDurationSec',
          message: 'Launch Plays must estimate between 1 and 180 seconds.',
        ),
      );
    }
    if (play.states.isEmpty) {
      issues.add(
        const PlayValidationIssue(
          code: 'states_required',
          path: 'states',
          message: 'At least one state is required.',
        ),
      );
      return issues;
    }
    if (!play.states.containsKey(play.entryState)) {
      issues.add(
        const PlayValidationIssue(
          code: 'entry_state_missing',
          path: 'entryState',
          message: 'entryState must reference an existing state.',
        ),
      );
      return issues;
    }
    if (play.classification == PlayClassification.fact &&
        play.sources.isEmpty) {
      issues.add(
        const PlayValidationIssue(
          code: 'fact_source_required',
          path: 'sources',
          message: 'Factual Plays require at least one source.',
        ),
      );
    }

    var hasTerminalPath = false;
    for (final entry in play.states.entries) {
      final stateId = entry.key;
      final state = entry.value;
      final optionIds = <String>{};
      for (final option in state.input.options) {
        if (!optionIds.add(option.id)) {
          issues.add(
            PlayValidationIssue(
              code: 'duplicate_option',
              path: 'states.$stateId.input.options',
              message: 'Option ids must be unique within a state.',
            ),
          );
        }
      }

      if ((state.input.type == PlayInputType.singleChoice ||
              state.input.type == PlayInputType.multipleChoice) &&
          state.input.options.length < 2) {
        issues.add(
          PlayValidationIssue(
            code: 'choice_options',
            path: 'states.$stateId.input.options',
            message: 'Choice inputs require at least two options.',
          ),
        );
      }

      _validateValidator(stateId, state.validation, issues);
      _validateInput(stateId, state, issues);

      for (final layer in state.presentation) {
        if (layer.assetId != null && !play.assets.contains(layer.assetId)) {
          issues.add(
            PlayValidationIssue(
              code: 'asset_missing',
              path: 'states.$stateId.presentation',
              message: 'Layer references undeclared asset ${layer.assetId}.',
            ),
          );
        }
        _validateCopy(stateId, layer, issues);
      }

      for (final target in state.transitions.values) {
        if (target == r'$end') {
          hasTerminalPath = true;
        } else if (!play.states.containsKey(target)) {
          issues.add(
            PlayValidationIssue(
              code: 'transition_target_missing',
              path: 'states.$stateId.transition',
              message: 'Transition target $target does not exist.',
            ),
          );
        }
      }
    }

    final reachable = <String>{};
    final pending = <String>[play.entryState];
    while (pending.isNotEmpty) {
      final stateId = pending.removeLast();
      if (!reachable.add(stateId)) continue;
      final state = play.states[stateId];
      if (state == null) continue;
      for (final target in state.transitions.values) {
        if (target != r'$end' && play.states.containsKey(target)) {
          pending.add(target);
        }
      }
    }

    for (final stateId in play.states.keys) {
      if (!reachable.contains(stateId)) {
        issues.add(
          PlayValidationIssue(
            code: 'unreachable_state',
            path: 'states.$stateId',
            message: 'Published Plays cannot contain unreachable states.',
          ),
        );
      }
    }

    if (!hasTerminalPath) {
      issues.add(
        const PlayValidationIssue(
          code: 'terminal_path_required',
          path: 'states',
          message: r'At least one explicit $end transition is required.',
        ),
      );
    }

    return issues;
  }

  void _validateValidator(
    String stateId,
    PlayValidationDefinition validation,
    List<PlayValidationIssue> issues,
  ) {
    final path = 'states.$stateId.validation.value';
    if (validation.type == PlayValidatorType.equals &&
        validation.value == null) {
      issues.add(
        PlayValidationIssue(
          code: 'validator_value',
          path: path,
          message: 'equals validation requires a value.',
        ),
      );
      return;
    }

    if (validation.type == PlayValidatorType.orderedSequence) {
      final value = validation.value;
      final valid =
          value is List &&
          value.isNotEmpty &&
          value.length <= 16 &&
          value.every((item) => item is String && item.trim().isNotEmpty);
      if (!valid) {
        issues.add(
          PlayValidationIssue(
            code: 'validator_value',
            path: path,
            message: 'ordered_sequence requires 1–16 non-empty string values.',
          ),
        );
      }
      return;
    }

    if (validation.type == PlayValidatorType.targetRegion &&
        _nonEmptyString(validation.value) == null) {
      issues.add(
        PlayValidationIssue(
          code: 'validator_value',
          path: path,
          message: 'target_region requires a non-empty target id.',
        ),
      );
    }
  }

  void _validateInput(
    String stateId,
    PlayStateDefinition state,
    List<PlayValidationIssue> issues,
  ) {
    switch (state.input.type) {
      case PlayInputType.pianoKey:
        _validatePianoInput(stateId, state, issues);
      case PlayInputType.drag:
        _validateDragInput(stateId, state, issues);
      default:
        break;
    }
  }

  void _validatePianoInput(
    String stateId,
    PlayStateDefinition state,
    List<PlayValidationIssue> issues,
  ) {
    final path = 'states.$stateId.input';
    if (state.validation.type != PlayValidatorType.orderedSequence) {
      issues.add(
        PlayValidationIssue(
          code: 'piano_validator',
          path: '$path.type',
          message: 'piano_key requires ordered_sequence validation.',
        ),
      );
      return;
    }

    final expectedRaw = state.validation.value;
    if (expectedRaw is! List ||
        expectedRaw.isEmpty ||
        expectedRaw.length > 16 ||
        expectedRaw.any((item) => item is! String || item.trim().isEmpty)) {
      return;
    }
    final expected = expectedRaw.cast<String>();

    final keysRaw = state.input.properties['keys'];
    final parsedKeys = keysRaw == null
        ? MosaicPianoInputDefaults.keys.toSet()
        : _uniqueStrings(keysRaw);
    Set<String>? keys;
    if (parsedKeys == null || parsedKeys.isEmpty) {
      issues.add(
        PlayValidationIssue(
          code: 'piano_keys',
          path: '$path.keys',
          message: 'piano_key keys must be unique non-empty strings.',
        ),
      );
    } else {
      keys = parsedKeys;
    }

    final lengthRaw = state.input.properties['sequenceLength'];
    if (lengthRaw != null &&
        (lengthRaw is! int || lengthRaw < 1 || lengthRaw > 16)) {
      issues.add(
        PlayValidationIssue(
          code: 'piano_sequence_length',
          path: '$path.sequenceLength',
          message: 'piano_key sequenceLength must be an integer from 1 to 16.',
        ),
      );
    } else if (lengthRaw is int && lengthRaw != expected.length) {
      issues.add(
        PlayValidationIssue(
          code: 'piano_sequence_length',
          path: '$path.sequenceLength',
          message: 'piano_key sequenceLength must match the ordered sequence.',
        ),
      );
    }

    final availableKeys = keys;
    if (availableKeys != null &&
        expected.any((note) => !availableKeys.contains(note))) {
      issues.add(
        PlayValidationIssue(
          code: 'piano_expected_key_missing',
          path: '$path.keys',
          message: 'Every expected piano note must exist in the rendered keys.',
        ),
      );
    }
  }

  void _validateDragInput(
    String stateId,
    PlayStateDefinition state,
    List<PlayValidationIssue> issues,
  ) {
    final path = 'states.$stateId.input';
    if (state.validation.type != PlayValidatorType.targetRegion) {
      issues.add(
        PlayValidationIssue(
          code: 'drag_validator',
          path: '$path.type',
          message: 'drag requires target_region validation.',
        ),
      );
      return;
    }

    final origin = _point(state.input.properties['dragOrigin']);
    final size = _size(state.input.properties['dragSize']);
    if (origin == null ||
        size == null ||
        origin.$1 + size.$1 > 1 ||
        origin.$2 + size.$2 > 1) {
      issues.add(
        PlayValidationIssue(
          code: 'drag_geometry',
          path: path,
          message:
              'drag requires an in-bounds normalized dragOrigin and dragSize.',
        ),
      );
    }

    final targetsRaw = state.input.properties['targets'];
    final parsedTargets = _targets(targetsRaw);
    if (parsedTargets == null || parsedTargets.isEmpty) {
      issues.add(
        PlayValidationIssue(
          code: 'drag_targets',
          path: '$path.targets',
          message:
              'drag targets must be unique, normalized, in-bounds rectangles.',
        ),
      );
      return;
    }

    for (var left = 0; left < parsedTargets.length; left += 1) {
      for (var right = left + 1; right < parsedTargets.length; right += 1) {
        if (_overlaps(parsedTargets[left].$2, parsedTargets[right].$2)) {
          issues.add(
            PlayValidationIssue(
              code: 'drag_target_overlap',
              path: '$path.targets',
              message: 'drag targets must not overlap.',
            ),
          );
          left = parsedTargets.length;
          break;
        }
      }
    }

    final expectedTarget = _nonEmptyString(state.validation.value);
    if (expectedTarget != null &&
        !parsedTargets.any((target) => target.$1 == expectedTarget)) {
      issues.add(
        PlayValidationIssue(
          code: 'drag_expected_target_missing',
          path: '$path.targets',
          message: 'The target_region id must reference an authored target.',
        ),
      );
    }
  }

  void _validateCopy(
    String stateId,
    PresentationLayer layer,
    List<PlayValidationIssue> issues,
  ) {
    final value = layer.value;
    final role = layer.role;
    if (value == null || role == null) return;
    final words = value.trim().isEmpty
        ? 0
        : value.trim().split(RegExp(r'\s+')).length;
    final limit = switch (role) {
      'prompt' => MosaicCopyPolicy.promptWords,
      'scenario' => MosaicCopyPolicy.scenarioWords,
      'reveal_detail' => MosaicCopyPolicy.revealDetailWords,
      'metadata' => MosaicCopyPolicy.metadataWords,
      _ => null,
    };
    if (limit != null && words > limit) {
      issues.add(
        PlayValidationIssue(
          code: 'copy_budget',
          path: 'states.$stateId.presentation.$role',
          message: '$role exceeds the $limit-word consumer copy budget.',
        ),
      );
    }
  }
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

Set<String>? _uniqueStrings(Object? raw) {
  if (raw is! List) return null;
  final result = <String>{};
  for (final item in raw) {
    final value = _nonEmptyString(item);
    if (value == null || !result.add(value)) return null;
  }
  return result;
}

(double, double)? _point(Object? raw) {
  if (raw is! Map) return null;
  final x = _unit(raw['x']);
  final y = _unit(raw['y']);
  return x == null || y == null ? null : (x, y);
}

(double, double)? _size(Object? raw) {
  if (raw is! Map) return null;
  final width = _positiveUnit(raw['width']);
  final height = _positiveUnit(raw['height']);
  return width == null || height == null ? null : (width, height);
}

List<(String, (double, double, double, double))>? _targets(Object? raw) {
  if (raw is! List) return null;
  final ids = <String>{};
  final targets = <(String, (double, double, double, double))>[];
  for (final item in raw) {
    if (item is! Map) return null;
    final id = _nonEmptyString(item['id']);
    final x = _unit(item['x']);
    final y = _unit(item['y']);
    final width = _positiveUnit(item['width']);
    final height = _positiveUnit(item['height']);
    if (id == null ||
        !ids.add(id) ||
        x == null ||
        y == null ||
        width == null ||
        height == null ||
        x + width > 1 ||
        y + height > 1) {
      return null;
    }
    targets.add((id, (x, y, width, height)));
  }
  return targets;
}

bool _overlaps(
  (double, double, double, double) left,
  (double, double, double, double) right,
) {
  final (leftX, leftY, leftWidth, leftHeight) = left;
  final (rightX, rightY, rightWidth, rightHeight) = right;
  return leftX < rightX + rightWidth &&
      leftX + leftWidth > rightX &&
      leftY < rightY + rightHeight &&
      leftY + leftHeight > rightY;
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
