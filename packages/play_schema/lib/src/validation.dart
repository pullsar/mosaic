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

    if (play.schemaVersion != 1) {
      issues.add(
        const PlayValidationIssue(
          code: 'schema_version',
          path: 'schemaVersion',
          message: 'Only schemaVersion 1 is supported.',
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

      if (state.validation.type == PlayValidatorType.equals &&
          state.validation.value == null) {
        issues.add(
          PlayValidationIssue(
            code: 'validator_value',
            path: 'states.$stateId.validation.value',
            message: 'equals validation requires a value.',
          ),
        );
      }

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
