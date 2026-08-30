from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, text: str) -> None:
    Path(path).write_text(text)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one match, found {count}')
    return text.replace(old, new, 1)


def insert_before_once(text: str, marker: str, addition: str, label: str) -> str:
    if addition in text:
        return text
    count = text.count(marker)
    if count != 1:
        raise SystemExit(f'{label}: expected one insertion marker, found {count}')
    return text.replace(marker, addition + marker, 1)


def remove_between(text: str, start: str, end: str, label: str) -> str:
    if start not in text:
        return text
    start_index = text.index(start)
    end_index = text.index(end, start_index)
    return text[:start_index] + text[end_index:]


# Keep derived ranking state under one owner: the projector. Explicit actions
# remain canonical in actor_play_signals and are joined by the projector reader.
repository_path = 'apps/api/src/consumer_repository.ts'
repository = read(repository_path)
repository = repository.replace('  feedCandidateIdentity,\n', '', 1)
for constant in (
    'const RECENT_REVISION_TTL_MS = 7 * 24 * 60 * 60 * 1000;\n',
    'const DISMISSAL_TTL_MS = 30 * 24 * 60 * 60 * 1000;\n',
    'const AFFINITY_HALF_LIFE_MS = 30 * 24 * 60 * 60 * 1000;\n',
    'const AFFINITY_MAX_AGE_MS = 90 * 24 * 60 * 60 * 1000;\n',
):
    repository = repository.replace(constant, '', 1)
repository = remove_between(
    repository,
    'export interface DerivedConsumerRankingProfile {',
    'export interface PlayActionState {',
    'consumer_repository derived interface',
)
repository = repository.replace(
    '  getDerivedRankingProfile?(actorId: string): Promise<DerivedConsumerRankingProfile | null>;\n',
    '',
    1,
)
repository = remove_between(
    repository,
    '  async getDerivedRankingProfile(',
    '  async getActionState(',
    'consumer_repository derived method',
)
repository = remove_between(
    repository,
    'function decodeAffinityForRanking(',
    'function normalizeTopicIds(',
    'consumer_repository duplicate decode helpers',
)
write(repository_path, repository)

projector_path = 'apps/api/src/consumer_signal_projector.ts'
projector = read(projector_path)
projector = replace_once(
    projector,
    '    this.clock = options.clock ?? Date.new;\n',
    '    this.clock = options.clock ?? (() => new Date());\n',
    'projector default clock',
)
projector = replace_once(
    projector,
    '      const format = optionalText(action.format)?.toLowerCase();\n'
    '      if (format !== null) incrementCount(formatDismissalCounts, format);\n',
    '      const format = optionalText(action.format);\n'
    '      if (format !== null) incrementCount(formatDismissalCounts, format.toLowerCase());\n',
    'projector explicit-action format narrowing',
)
if "and event.event_name in ('play_visible', 'play_resolved', 'play_dismissed')" not in projector:
    projector = replace_once(
        projector,
        '      where event.actor_id = $1\n        and (\n',
        "      where event.actor_id = $1\n"
        "        and event.event_name in ('play_visible', 'play_resolved', 'play_dismissed')\n"
        '        and (\n',
        'projector event-name filter',
    )
write(projector_path, projector)

# Migration 008 is the first rollback stage; migration 007 action tables must
# remain until the second down migration.
postgres_test_path = 'apps/api/test/postgres.test.ts'
postgres_test = read(postgres_test_path)
if 'const profileDownPool = new Pool' not in postgres_test:
    anchor = "  await runMigration('down');\n  const actionsDownPool = new Pool({connectionString: databaseUrl});\n"
    stage = """  await runMigration('down');
  const profileDownPool = new Pool({connectionString: databaseUrl});
  try {
    const afterProfileDown = await profileDownPool.query<{
      consumer_signal_profiles: string | null;
      actor_topic_mutes: string | null;
    }>(
      `select to_regclass('public.consumer_signal_profiles')::text as consumer_signal_profiles,
              to_regclass('public.actor_topic_mutes')::text as actor_topic_mutes`,
    );
    assert.equal(afterProfileDown.rows[0]?.consumer_signal_profiles, null);
    assert.equal(afterProfileDown.rows[0]?.actor_topic_mutes, 'actor_topic_mutes');
  } finally {
    await profileDownPool.end();
  }

  await runMigration('down');
  const actionsDownPool = new Pool({connectionString: databaseUrl});
"""
    postgres_test = replace_once(postgres_test, anchor, stage, 'migration 008 rollback stage')
write(postgres_test_path, postgres_test)

projection_test_path = 'apps/api/test/consumer_signal_projector_postgres.test.ts'
projection_test = read(projection_test_path)
projection_test = replace_once(
    projection_test,
    '      assert.equal(await projector.projectActor(actorId), 2);\n'
    '      assert.equal(await projector.projectActor(actorId), 2);\n'
    '      assert.equal(await projector.projectActor(actorId), 0);\n',
    '      assert.equal(await projector.projectActor(actorId), 2);\n'
    '      assert.equal(await projector.projectActor(actorId), 0);\n',
    'projector filtered initial batches',
)
projection_test = replace_once(
    projection_test,
    '      assert.equal(concurrent.reduce((sum, value) => sum + value, 0), 1);\n',
    '      assert.equal(concurrent.reduce((sum, value) => sum + value, 0), 0);\n',
    'projector explicit-action concurrency',
)
projection_test = replace_once(
    projection_test,
    "      assert.equal(await events.insertEvent(duplicateIntent), 'inserted');\n"
    '      assert.equal(await projector.projectActor(actorId), 1);\n',
    "      assert.equal(await events.insertEvent(duplicateIntent), 'inserted');\n"
    '      assert.equal(await projector.projectActor(actorId), 0);\n',
    'projector duplicate one-shot event',
)
if 'afterMoreLikeExpiry' not in projection_test:
    anchor = """      assert.equal(bounded?.formatDismissalCounts.choose, 2);

      const beforeRebuild = await rawProjection(pool, actorId);
      const rebuiltEvents = await projector.rebuildActor(actorId);
      assert.ok(rebuiltEvents >= 5);
"""
    replacement = """      assert.equal(bounded?.formatDismissalCounts.choose, 2);

      const clockAnchor = Date.now();
      const afterMoreLikeExpiry = await new PostgresConsumerSignalProjector(pool, {
        clock: () => new Date(clockAnchor + 15 * 24 * 60 * 60 * 1000),
      }).readActorProfile(actorId);
      assert.deepEqual(afterMoreLikeExpiry?.moreLikeTopicIds, []);
      assert.equal(afterMoreLikeExpiry?.topicDismissalCounts[artTopic], 2);

      const afterDismissalExpiry = await new PostgresConsumerSignalProjector(pool, {
        clock: () => new Date(clockAnchor + 31 * 24 * 60 * 60 * 1000),
      }).readActorProfile(actorId);
      assert.deepEqual(afterDismissalExpiry?.topicDismissalCounts, {});
      assert.deepEqual(afterDismissalExpiry?.formatDismissalCounts, {});
      assert.ok((afterDismissalExpiry?.interactionAffinity.guess ?? 0) > 0);

      const afterAffinityExpiry = await new PostgresConsumerSignalProjector(pool, {
        clock: () => new Date(clockAnchor + 91 * 24 * 60 * 60 * 1000),
      }).readActorProfile(actorId);
      assert.deepEqual(afterAffinityExpiry?.interactionAffinity, {});
      assert.deepEqual(afterAffinityExpiry?.recentPlayRevisionKeys, []);

      const beforeRebuild = await rawProjection(pool, actorId);
      const rebuiltEvents = await projector.rebuildActor(actorId);
      assert.equal(rebuiltEvents, 2);
"""
    projection_test = replace_once(projection_test, anchor, replacement, 'projector decay/rebuild coverage')
write(projection_test_path, projection_test)

# Feed-level proof that a fresh decision consumes derived signals and that
# projector failure falls back to explicit preferences instead of failing feed.
feed_test_path = 'apps/api/test/consumer_feed.test.ts'
feed_test = read(feed_test_path)
feed_test = feed_test.replace(
    "import type {FeedCandidate, RankedFeedCandidate} from '../src/consumer_ranking.js';\n",
    "import {feedCandidateIdentity, type FeedCandidate, type RankedFeedCandidate} from '../src/consumer_ranking.js';\n",
    1,
)
if "derived ranking profile changes a fresh decision" not in feed_test:
    marker = "test('feed window introduces one wildcard only when top window lacks exploration', () => {"
    tests = """test('derived ranking profile changes a fresh decision without changing explicit preferences', async () => {
  const repository = new MemoryConsumerRepository();
  repository.candidates = [
    candidate('seen', 'r1', {curatedOrder: 1}),
    candidate('fresh', 'r2', {curatedOrder: 2}),
  ];
  const projector = {
    projectActor: async (_actorId: string) => 0,
    readActorProfile: async (_actorId: string) => ({
      interactionAffinity: {},
      recentPlayRevisionKeys: [feedCandidateIdentity('seen', 'r1')],
      topicDismissalCounts: {},
      formatDismissalCounts: {},
      moreLikeTopicIds: [],
    }),
    rebuildActor: async (_actorId: string) => 0,
  };
  const service = new ConsumerFeedService(repository, {
    windowSize: 2,
    candidateLimit: 2,
    requestIdFactory: () => 'derived_request',
    signalProjector: projector,
  });

  const page = await service.getFeed({actorId: 'actor_derived', capabilities, limit: 2});
  assert.deepEqual(page.items.map((item) => item.playId), ['fresh', 'seen']);
});

test('projection failure falls back to explicit profile without blocking feed', async () => {
  const repository = new MemoryConsumerRepository();
  repository.preferences = {interestTopicIds: ['travel'], learningTopicIds: []};
  repository.candidates = [
    candidate('travel', 'r1', {topicIds: ['travel'], curatedOrder: 2}),
    candidate('other', 'r2', {topicIds: ['music'], curatedOrder: 1}),
  ];
  const errors: unknown[] = [];
  const projector = {
    projectActor: async (_actorId: string) => {
      throw new Error('projection unavailable');
    },
    readActorProfile: async (_actorId: string) => {
      throw new Error('must not be reached');
    },
    rebuildActor: async (_actorId: string) => 0,
  };
  const service = new ConsumerFeedService(repository, {
    windowSize: 2,
    candidateLimit: 2,
    requestIdFactory: () => 'profile_fallback_request',
    signalProjector: projector,
    onProfileError: (error) => errors.push(error),
  });

  const page = await service.getFeed({actorId: 'actor_profile_fallback', capabilities, limit: 2});
  assert.equal(page.items[0]?.playId, 'travel');
  assert.equal(errors.length, 1);
});

"""
    feed_test = insert_before_once(feed_test, marker, tests, 'feed derived/fallback tests')
write(feed_test_path, feed_test)

ranking_test_path = 'apps/api/test/consumer_ranking.test.ts'
ranking_test = read(ranking_test_path)
if 'recent fatigue is scoped to the exact Play plus revision identity' not in ranking_test:
    marker = "test('no explicit preference produces a deterministic curated fallback order', () => {"
    test = """test('recent fatigue is scoped to the exact Play plus revision identity', () => {
  const sharedRevision = 'shared_revision';
  const seen = candidate('seen', {qualityPrior: 0.7, curatedOrder: 1});
  const other = candidate('other', {qualityPrior: 0.7, curatedOrder: 2});
  seen.revisionId = sharedRevision;
  other.revisionId = sharedRevision;

  const ranked = rankFeedCandidates([seen, other], {
    interestTopicIds: [],
    learningTopicIds: [],
    recentPlayRevisionKeys: [JSON.stringify([seen.playId, sharedRevision])],
  });

  assert.equal(ranked[0]?.playId, other.playId);
  assert.equal(
    ranked.find((item) => item.playId === other.playId)?.featureContributions.recentSeenPenalty,
    0,
  );
});

"""
    ranking_test = insert_before_once(ranking_test, marker, test, 'compound recent identity test')
write(ranking_test_path, ranking_test)

# Only direct page gestures may become implicit swipe signals.
consumer_feed_path = 'apps/mosaic_app/lib/consumer_feed.dart'
consumer_feed = read(consumer_feed_path)
controller_start = consumer_feed.index('final class ConsumerFeedController {')
controller_end = consumer_feed.index('typedef ConsumerFeedItemBuilder', controller_start)
controller = """enum ConsumerFeedAdvanceReason {
  notInterested('not_interested'),
  topicMuted('topic_muted'),
  reported('reported');

  const ConsumerFeedAdvanceReason(this.wireName);
  final String wireName;
}

final class ConsumerFeedController {
  Future<bool> Function(ConsumerFeedAdvanceReason reason)? _advance;
  bool get attached => _advance != null;

  Future<bool> advance(ConsumerFeedAdvanceReason reason) async {
    final callback = _advance;
    return callback == null ? false : callback(reason);
  }

  void _attach(
    Future<bool> Function(ConsumerFeedAdvanceReason reason) callback,
  ) => _advance = callback;

  void _detach(
    Future<bool> Function(ConsumerFeedAdvanceReason reason) callback,
  ) {
    if (identical(_advance, callback)) _advance = null;
  }
}

"""
consumer_feed = consumer_feed[:controller_start] + controller + consumer_feed[controller_end:]
if '_pendingAdvanceIdentity' not in consumer_feed:
    consumer_feed = replace_once(
        consumer_feed,
        '  bool _directManipulationActive = false;\n',
        '  bool _directManipulationActive = false;\n'
        '  String? _pendingAdvanceIdentity;\n'
        '  ConsumerFeedAdvanceReason? _pendingAdvanceReason;\n',
        'feed advance state',
    )
advance_start = consumer_feed.index('  Future<bool> _requestAdvance(')
advance_end = consumer_feed.index('  void _onPageChanged(', advance_start)
advance = """  Future<bool> _requestAdvance(ConsumerFeedAdvanceReason reason) async {
    if (!mounted || _entries.isEmpty || _directManipulationActive) {
      return false;
    }
    final currentIdentity = _entries[_currentIndex].analyticsIdentity;
    Future<bool> advanceLoaded() async {
      if (!mounted ||
          _entries.isEmpty ||
          _currentIndex >= _entries.length ||
          _entries[_currentIndex].analyticsIdentity != currentIdentity ||
          _currentIndex + 1 >= _entries.length) {
        return false;
      }
      _pendingAdvanceIdentity = currentIdentity;
      _pendingAdvanceReason = reason;
      try {
        await _pageController.nextPage(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      } finally {
        if (_pendingAdvanceIdentity == currentIdentity) {
          _pendingAdvanceIdentity = null;
          _pendingAdvanceReason = null;
        }
      }
      return true;
    }

    if (await advanceLoaded()) return true;
    final cursor = _nextCursor;
    if (cursor == null || _fetching) return false;
    await _fetchPage(cursor, epoch: _loadEpoch);
    return advanceLoaded();
  }

"""
consumer_feed = consumer_feed[:advance_start] + advance + consumer_feed[advance_end:]
page_start = consumer_feed.index('  void _onPageChanged(int index) {')
page_end = consumer_feed.index('  void _trimRetainedWindow()', page_start)
page_changed = """  void _onPageChanged(int index) {
    if (index < 0 || index >= _entries.length) return;
    final previous = _entries[_currentIndex];
    final next = _entries[index];
    if (previous.analyticsIdentity == next.analyticsIdentity) return;

    final programmaticReason =
        _pendingAdvanceIdentity == previous.analyticsIdentity
        ? _pendingAdvanceReason
        : null;
    _pendingAdvanceIdentity = null;
    _pendingAdvanceReason = null;

    setState(() {
      _currentIndex = index;
      _directManipulationActive = false;
      _trimRetainedWindow();
    });

    _emitDismissed(
      previous,
      reason: programmaticReason?.wireName ?? 'swipe',
    );
    _emitVisible(next, _currentIndex);
    _queuePersistence();
    _scheduleWarmWindow();
    _maybeFetchAhead();
  }

"""
consumer_feed = consumer_feed[:page_start] + page_changed + consumer_feed[page_end:]
dismiss_start = consumer_feed.index('  void _emitDismissed(')
dismiss_end = consumer_feed.index('  Future<void> _retry()', dismiss_start)
dismiss = """  void _emitDismissed(_FeedEntry entry, {required String reason}) {
    widget.onEvent?.call(
      MosaicEventName.playDismissed,
      feedRequestId: entry.requestId,
      playRevisionId: entry.item.revisionId,
      payload: <String, Object?>{
        'playId': entry.item.playId,
        'reason': reason,
      },
    );
  }

"""
consumer_feed = consumer_feed[:dismiss_start] + dismiss + consumer_feed[dismiss_end:]
write(consumer_feed_path, consumer_feed)

controls_path = 'apps/mosaic_app/lib/consumer_action_controls.dart'
controls = read(controls_path)
if "import 'consumer_feed.dart';" not in controls:
    controls = controls.replace(
        "import 'consumer_api_client.dart';\n",
        "import 'consumer_api_client.dart';\nimport 'consumer_feed.dart';\n",
        1,
    )
controls = controls.replace(
    '  final Future<bool> Function() onAdvance;\n',
    '  final Future<bool> Function(ConsumerFeedAdvanceReason reason) onAdvance;\n',
    1,
)
controls = controls.replace(
    '      if (applied) await widget.onAdvance();\n',
    '      if (applied) {\n'
    '        await widget.onAdvance(ConsumerFeedAdvanceReason.notInterested);\n'
    '      }\n',
    1,
)
controls = controls.replace(
    '    if (applied && muted) await widget.onAdvance();\n',
    '    if (applied && muted) {\n'
    '      await widget.onAdvance(ConsumerFeedAdvanceReason.topicMuted);\n'
    '    }\n',
    1,
)
controls = controls.replace(
    '    if (reported) await widget.onAdvance();\n',
    '    if (reported) {\n'
    '      await widget.onAdvance(ConsumerFeedAdvanceReason.reported);\n'
    '    }\n',
    1,
)
write(controls_path, controls)

main_path = 'apps/mosaic_app/lib/main.dart'
main = read(main_path)
if "import 'play_resolution_telemetry.dart';" not in main:
    main = main.replace(
        "import 'onboarding_localizations.dart';\n",
        "import 'onboarding_localizations.dart';\nimport 'play_resolution_telemetry.dart';\n",
        1,
    )
if 'onResolved: (resolution) => recordPlayResolutionTelemetry(' not in main:
    main = replace_once(
        main,
        '      play: item.play,\n'
        '      mediaBuilder: media.call,\n'
        '      onDirectManipulationChanged: onDirectManipulationChanged,\n',
        '      play: item.play,\n'
        '      mediaBuilder: media.call,\n'
        '      onResolved: (resolution) => recordPlayResolutionTelemetry(\n'
        '        telemetry,\n'
        '        playId: item.playId,\n'
        '        outcome: resolution.outcome,\n'
        '        attempts: resolution.session.attempts,\n'
        '        completed: resolution.session.ended,\n'
        '        correct: resolution.wasCorrect,\n'
        '      ),\n'
        '      onDirectManipulationChanged: onDirectManipulationChanged,\n',
        'main Play resolution telemetry bridge',
    )
write(main_path, main)

controls_test_path = 'apps/mosaic_app/test/consumer_action_controls_test.dart'
controls_test = read(controls_test_path)
if "import 'package:mosaic_app/consumer_feed.dart';" not in controls_test:
    controls_test = controls_test.replace(
        "import 'package:mosaic_app/consumer_local_state.dart';\n",
        "import 'package:mosaic_app/consumer_local_state.dart';\n"
        "import 'package:mosaic_app/consumer_feed.dart';\n",
        1,
    )
if 'final advanceReasons = <ConsumerFeedAdvanceReason>[];' not in controls_test:
    controls_test = replace_once(
        controls_test,
        '  var eventId = 0;\n'
        '  var advances = 0;\n\n'
        '  Future<bool> advance() async {\n'
        '    advances += 1;\n'
        '    return true;\n'
        '  }\n',
        '  var eventId = 0;\n'
        '  var advances = 0;\n'
        '  final advanceReasons = <ConsumerFeedAdvanceReason>[];\n\n'
        '  Future<bool> advance(ConsumerFeedAdvanceReason reason) async {\n'
        '    advances += 1;\n'
        '    advanceReasons.add(reason);\n'
        '    return true;\n'
        '  }\n',
        'action harness advance reason',
    )
if 'ConsumerFeedAdvanceReason.notInterested' not in controls_test:
    controls_test = replace_once(
        controls_test,
        '    expect(harness.advances, 1);\n'
        '  });\n\n'
        "  testWidgets('muting the current topic is durable and advances',",
        '    expect(harness.advances, 1);\n'
        '    expect(harness.advanceReasons, <ConsumerFeedAdvanceReason>[\n'
        '      ConsumerFeedAdvanceReason.notInterested,\n'
        '    ]);\n'
        '  });\n\n'
        "  testWidgets('muting the current topic is durable and advances',",
        'Not interested reason assertion',
    )
if 'ConsumerFeedAdvanceReason.topicMuted' not in controls_test:
    controls_test = replace_once(
        controls_test,
        "    expect(harness.controller.isTopicMuted('testing'), isTrue);\n"
        '    expect(harness.advances, 1);\n',
        "    expect(harness.controller.isTopicMuted('testing'), isTrue);\n"
        '    expect(harness.advances, 1);\n'
        '    expect(harness.advanceReasons, <ConsumerFeedAdvanceReason>[\n'
        '      ConsumerFeedAdvanceReason.topicMuted,\n'
        '    ]);\n',
        'mute reason assertion',
    )
if "Report advances with an explicit non-swipe reason" not in controls_test:
    marker = "  testWidgets('muted topics remain reachable and reversible', (tester) async {"
    report_test = """  testWidgets('Report advances with an explicit non-swipe reason', (tester) async {
    final harness = _Harness();
    addTearDown(harness.close);

    await tester.pumpWidget(_app(harness));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('play-action-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spam'));
    await tester.pumpAndSettle();

    expect(harness.advances, 1);
    expect(harness.advanceReasons, <ConsumerFeedAdvanceReason>[
      ConsumerFeedAdvanceReason.reported,
    ]);
  });

"""
    controls_test = insert_before_once(controls_test, marker, report_test, 'report reason test')
write(controls_test_path, controls_test)

feed_widget_test_path = 'apps/mosaic_app/test/consumer_feed_test.dart'
feed_widget_test = read(feed_widget_test_path)
if 'ConsumerFeedController? controller,' not in feed_widget_test:
    feed_widget_test = replace_once(
        feed_widget_test,
        '  ConsumerFeedWarmWindowCallback? onWarmWindow,\n'
        '  int pageSize = 6,\n'
        '}) => MaterialApp(\n'
        '  home: ConsumerFeed(\n'
        '    runtime: runtime,\n'
        '    pageSize: pageSize,\n',
        '  ConsumerFeedWarmWindowCallback? onWarmWindow,\n'
        '  ConsumerFeedController? controller,\n'
        '  int pageSize = 6,\n'
        '}) => MaterialApp(\n'
        '  home: ConsumerFeed(\n'
        '    runtime: runtime,\n'
        '    controller: controller,\n'
        '    pageSize: pageSize,\n',
        'feed test controller injection',
    )
if 'programmatic advance cannot masquerade as a swipe dismissal' not in feed_widget_test:
    marker = "  testWidgets('rapid swipes coalesce persistence behind one active write', ("
    reason_test = """  testWidgets('programmatic advance cannot masquerade as a swipe dismissal', (
    tester,
  ) async {
    final state = _MemoryConsumerState();
    final controller = ConsumerFeedController();
    final dismissals = <Map<String, Object?>>[];
    final runtime = _runtime(
      state,
      (cursor, call) => http.Response(
        jsonEncode(
          _page('request_reason', [_item('reason_0'), _item('reason_1')], null),
        ),
        200,
      ),
    );
    addTearDown(runtime.close);

    await tester.pumpWidget(
      _app(
        runtime,
        controller: controller,
        onEvent:
            (
              event, {
              required feedRequestId,
              required playRevisionId,
              required payload,
            }) {
              if (event == MosaicEventName.playDismissed) {
                dismissals.add(Map<String, Object?>.of(payload));
              }
            },
      ),
    );
    await tester.pumpAndSettle();

    expect(
      await controller.advance(ConsumerFeedAdvanceReason.notInterested),
      isTrue,
    );
    await tester.pumpAndSettle();

    expect(dismissals, hasLength(1));
    expect(dismissals.single['reason'], 'not_interested');
  });

"""
    feed_widget_test = insert_before_once(feed_widget_test, marker, reason_test, 'feed programmatic reason test')
write(feed_widget_test_path, feed_widget_test)
