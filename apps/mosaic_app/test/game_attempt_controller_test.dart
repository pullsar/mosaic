import 'dart:convert';

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

PlayDocument _scenePlay() => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'scene_move',
  'revisionId': 'rev_1',
  'format': 'solve',
  'classification': 'challenge',
  'topics': <String>[],
  'learningTopics': <String>[],
  'estimatedDurationSec': 10,
  'assets': <String>[],
  'sources': <Object>[],
  'entryState': 'move',
  'states': {
    'move': {
      'presentation': {
        'layers': [
          {
            'type': 'scene',
            'role': 'media',
            'scene': {
              'version': 1,
              'objects': [
                {
                  'id': 'piece',
                  'semanticLabel': 'Piece',
                  'shape': 'rounded_rect',
                  'x': .2,
                  'y': .2,
                  'width': .05,
                  'height': .2,
                  'movable': true,
                },
              ],
              'targets': [
                {
                  'id': 'slot',
                  'semanticLabel': 'Slot',
                  'x': .7,
                  'y': .2,
                  'width': .05,
                  'height': .2,
                },
              ],
            },
          },
        ],
      },
      'input': {'type': 'piece_move'},
      'validation': {
        'type': 'legal_piece_move',
        'value': [
          {'pieceId': 'piece', 'targetId': 'slot', 'correct': true},
        ],
      },
      'transition': {'correct': 'move', 'incorrect': 'move'},
    },
  },
});

PlayDocument _timedCuePlay() => PlayDocument.fromJson({
  'schemaVersion': 1,
  'id': 'timed_cue',
  'revisionId': 'rev_1',
  'format': 'guess',
  'classification': 'challenge',
  'topics': <String>[],
  'learningTopics': <String>[],
  'estimatedDurationSec': 10,
  'assets': <String>[],
  'sources': <Object>[],
  'entryState': 'cue',
  'states': {
    'cue': {
      'presentation': {
        'layers': [
          {'type': 'text', 'role': 'prompt', 'value': 'Look closer.'},
        ],
      },
      'input': {
        'type': 'timed_cue',
        'cueId': 'observe_1',
        'cueOrdinal': 1,
        'durationMs': 300,
      },
      'validation': {'type': 'none'},
      'transition': {'default': 'cue'},
    },
  },
});

void main() {
  test('a recovered run replays with a fresh ID', () {
    final first = GameAttemptController(play: _play());
    final restored = GameAttemptController.restoreRecoverySnapshot(
      play: _play(),
      encodedSnapshot: first.encodeRecoverySnapshot(capabilityVersion: 1)!,
      capabilityVersion: 1,
    )!;
    final oldId = restored.attemptId;
    restored.replay();
    expect(restored.attemptId, isNot(oldId));
  });

  test('duplicate input callback cannot apply twice within a run', () {
    final controller = GameAttemptController(play: _play());
    final callback = controller.captureActionHandler();
    callback(const ChoiceAction('b'));
    callback(const ChoiceAction('b'));
    expect(controller.session.attempts, 1);
  });

  test('recovery limit does not trap the live puzzle', () {
    final controller = GameAttemptController(play: _play());
    for (var index = 0; index < 129; index++) {
      controller.apply(const ChoiceAction('b'));
    }
    expect(controller.encodeRecoverySnapshot(capabilityVersion: 1), isNull);
    expect(controller.actions.length, lessThanOrEqualTo(128));
    controller.apply(const ChoiceAction('a'));
    expect(controller.completed, isTrue);
  });

  test('recovery rejects an answer never authored as a choice', () {
    final controller = GameAttemptController(play: _play());
    final snapshot =
        jsonDecode(controller.encodeRecoverySnapshot(capabilityVersion: 1)!)
            as Map<String, dynamic>;
    snapshot['actions'] = [
      {'type': 'choice', 'optionId': 'invented'},
    ];
    expect(
      GameAttemptController.restoreRecoverySnapshot(
        play: _play(),
        encodedSnapshot: jsonEncode(snapshot),
        capabilityVersion: 1,
      ),
      isNull,
    );
  });

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

  test('recovery snapshot rebuilds an authored scene placement', () {
    final controller = GameAttemptController(play: _scenePlay());
    controller.apply(const PieceMoveAction(pieceId: 'piece', targetId: 'slot'));
    final restored = GameAttemptController.restoreRecoverySnapshot(
      play: _scenePlay(),
      encodedSnapshot: controller.encodeRecoverySnapshot(capabilityVersion: 1)!,
      capabilityVersion: 1,
    );

    expect(restored, isNotNull);
    expect(restored!.session.piecePlacements, {'piece': 'slot'});
    expect(restored.completed, isFalse);
  });

  test('recovery snapshot preserves an authored timed cue action', () {
    final controller = GameAttemptController(play: _timedCuePlay());
    controller.apply(const TimedCueAction(cueId: 'observe_1', ordinal: 1));
    final restored = GameAttemptController.restoreRecoverySnapshot(
      play: _timedCuePlay(),
      encodedSnapshot: controller.encodeRecoverySnapshot(capabilityVersion: 1)!,
      capabilityVersion: 1,
    );

    expect(restored, isNotNull);
    expect(restored!.actions, [isA<TimedCueAction>()]);
    expect(restored.session.attempts, 1);
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
