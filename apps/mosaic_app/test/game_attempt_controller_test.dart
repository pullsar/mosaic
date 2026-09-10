import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_app/game_attempt_controller.dart';
import 'package:play_engine/play_engine.dart';
import 'package:play_schema/play_schema.dart';

PlayDocument _play() => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'one_move',
  'revisionId': 'rev_3',
  'format': 'guess',
  'classification': 'challenge',
  'topics': <String>[],
  'learningTopics': <String>[],
  'estimatedDurationSec': 10,
  'assets': <String>[],
  'sources': <Object>[],
  'entryState': 'question',
  'states': {
    'question': {
      'presentation': {
        'layers': [
          {'type': 'text', 'role': 'prompt', 'value': 'Pick one.'},
        ],
      },
      'input': {
        'type': 'single_choice',
        'options': [
          {'id': 'a', 'label': 'A'},
          {'id': 'b', 'label': 'B'},
        ],
      },
      'validation': {'type': 'equals', 'value': 'a'},
      'transition': {'correct': r'$end', 'incorrect': 'question'},
    },
  },
});

void main() {
  test('replay starts fresh without changing immutable Play identity', () {
    final ids = ['attempt-a', 'attempt-b'].iterator;
    final controller = GameAttemptController(
      play: _play(),
      idFactory: () {
        ids.moveNext();
        return ids.current;
      },
    );

    final originalPlay = controller.session.play;
    controller.apply(const ChoiceAction('a'));
    expect(controller.session.ended, isTrue);
    expect(controller.actions, hasLength(1));

    controller.replay();

    expect(controller.attemptId, 'attempt-b');
    expect(controller.mode, GameAttemptMode.practice);
    expect(controller.session.stateId, originalPlay.entryState);
    expect(controller.session.attempts, 0);
    expect(controller.session.ended, isFalse);
    expect(controller.actions, isEmpty);
    expect(identical(controller.session.play, originalPlay), isTrue);
    expect(controller.session.play.id, 'one_move');
    expect(controller.session.play.revisionId, 'rev_3');
  });

  test('callback captured for attempt A cannot mutate attempt B', () {
    final ids = ['attempt-a', 'attempt-b'].iterator;
    final controller = GameAttemptController(
      play: _play(),
      idFactory: () {
        ids.moveNext();
        return ids.current;
      },
    );
    final staleAction = controller.captureActionHandler();

    controller.replay();
    staleAction(const ChoiceAction('a'));

    expect(controller.attemptId, 'attempt-b');
    expect(controller.session.stateId, 'question');
    expect(controller.session.attempts, 0);
    expect(controller.actions, isEmpty);

    controller.captureActionHandler()(const ChoiceAction('a'));
    expect(controller.session.ended, isTrue);
  });

  test('recovery snapshot rebuilds a matching revision from actions', () {
    final controller = GameAttemptController(
      play: _play(),
      idFactory: () => 'attempt-a',
    );
    controller.apply(const ChoiceAction('b'));

    final snapshot = controller.encodeRecoverySnapshot(capabilityVersion: 1);
    final restored = GameAttemptController.restoreRecoverySnapshot(
      play: _play(),
      encodedSnapshot: snapshot!,
      capabilityVersion: 1,
    );

    expect(restored, isNotNull);
    expect(restored!.attemptId, 'attempt-a');
    expect(restored.mode, GameAttemptMode.first);
    expect(restored.session.stateId, 'question');
    expect(restored.session.attempts, 1);
    expect(restored.actions, hasLength(1));
  });

  test('recovery rejects corrupt, mismatched, and oversized snapshots', () {
    final controller = GameAttemptController(
      play: _play(),
      idFactory: () => 'attempt-a',
    );
    final snapshot = controller.encodeRecoverySnapshot(capabilityVersion: 1)!;

    expect(
      GameAttemptController.restoreRecoverySnapshot(
        play: _play(),
        encodedSnapshot: '{',
        capabilityVersion: 1,
      ),
      isNull,
    );
    expect(
      GameAttemptController.restoreRecoverySnapshot(
        play: _play(),
        encodedSnapshot: snapshot,
        capabilityVersion: 2,
      ),
      isNull,
    );
    expect(
      GameAttemptController.restoreRecoverySnapshot(
        play: _play(),
        encodedSnapshot: '${snapshot}x' * 70000,
        capabilityVersion: 1,
      ),
      isNull,
    );
  });
}
