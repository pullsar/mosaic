# Mosaic — Recommendation & Analytics Specification

## 1. Purpose

Mosaic's recommendation system should answer:

> **What is this person most likely to enjoy doing right now?**

It must not collapse into a watch-time maximizer.

The recommender learns three separate dimensions:

1. **Interest** — what the user already likes.
2. **Learning intent** — what the user explicitly wants to know more about.
3. **Interaction affinity** — how the user likes to engage.

These signals must remain separately inspectable even when combined for ranking.

## 2. Core entities

### Topic

Hierarchical or related concept used for interests and content tagging.

Examples:

```text
Travel
 ├─ Portugal
 │   └─ Lisbon
 ├─ Morocco
 │   └─ Marrakech
 ├─ Food
 └─ Architecture
```

A relational model is sufficient initially. Do not add a graph database until traversal/query requirements justify it.

### Interest signal

Represents user affinity for a topic as entertainment or general interest.

### Learning signal

Represents explicit or inferred desire to learn a topic.

### Interaction signal

Represents affinity for a format/primitive.

Examples:

- Choose;
- audio guess;
- visual guess;
- map;
- puzzle;
- short clip;
- piano input.

## 3. Cold start

Onboarding supplies two explicit signal sets:

### What are you into?

Seeds `interest` affinity.

### What do you want to learn more about?

Seeds `learning` affinity.

These must not be merged into one generic preference vector.

A user may be highly interested in football but explicitly want to learn piano.

## 4. Behavioral updates

Behavior modifies confidence over time.

### Positive examples

- starts Play;
- completes;
- asks for another state/round;
- replays;
- saves;
- shares;
- returns;
- explores topic;
- remixes;
- explicitly likes.

### Negative examples

- immediate dismissal;
- repeated dismissal of same topic;
- abandonment after engagement;
- mute topic;
- mute creator;
- hide;
- report.

A single swipe is weak evidence. Repeated consistent behavior is stronger.

## 5. Interaction affinity

Record both product format and primitive/media preferences.

Example vector:

```text
choose             +0.91
audio_guess        +0.83
map_point          +0.76
short_clip_guess   +0.71
visual_puzzle      +0.63
long_text          -0.44
```

This allows two users with identical topical interests to receive materially different feeds.

## 6. Candidate generation

Every feed window should draw from separate candidate buckets:

### Known

Strong topic/learning fit.

### Adjacent

Related topics or formats.

### Wildcard

Low-confidence or unrelated exploration.

### Social/contextual

Later: direct challenges, saved creators, local/context-aware Plays.

The ranking stage should know candidate provenance so exploration can be measured.

## 7. Initial ranking model

Start interpretable.

Conceptual score:

```text
score =
    interest_affinity
  + learning_affinity
  + interaction_affinity
  + quality_prior
  + novelty
  + creator_quality
  + contextual_fit
  + exploration_bonus
  - topic_repetition
  - format_fatigue
  - recent_seen_penalty
  - negative_feedback
  - safety/moderation_penalty
```

Weights are experiment/config values, not constants in client code.

## 8. What must not be the objective

Do not directly optimize for:

- longest session;
- maximum autoplay time;
- maximum number of impressions;
- creator follower count;
- emotional arousal;
- repeated exposure to one proven topic.

Session duration can be monitored as a health signal, not treated as success by default.

## 9. Quality prior

New content needs a prior before sufficient user data exists.

Inputs may include:

- editorial/seed quality;
- creator trust;
- template quality;
- provenance completeness;
- media quality;
- duplicate similarity;
- moderation state;
- early small-cohort performance.

The prior should decay as real interaction data accumulates.

## 10. Exploration rules

Serendipity is a product requirement.

The system must reserve exposure for:

- adjacent topics;
- new formats;
- wildcards;
- promising new creators;
- under-supplied learning interests.

Do not hardcode a permanent 60/25/15 split. Treat bucket allocation as an experimentable policy with minimum exploration guarantees.

## 11. Fatigue controls

Ranking must penalize repetition across:

- topic;
- creator;
- template;
- format;
- media pattern;
- semantic similarity.

Examples:

- three location guesses in a row should be rare even for a travel-heavy user;
- a user who loves piano should still see multiple interaction styles;
- one creator should not dominate because of a temporary strong prior.

## 12. Learning intent handling

Learning interest should influence both topic and difficulty.

For a user learning piano:

```text
note recognition
  ↓
short melodic sequence
  ↓
rhythm/chord distinction
  ↓
more complex playback
```

Do not force a curriculum. Difficulty progression informs feed selection while maintaining swipe freedom.

## 13. Competence estimate

For objective challenge formats, keep a lightweight per-topic/per-skill estimate based on:

- accuracy;
- attempts;
- response latency where meaningful;
- repeated success;
- difficulty of item.

Use competence to avoid feeds that are trivially easy or consistently frustrating.

Do not present this as an academic grade unless the product later introduces an explicit learning mode.

## 14. Situated-choice signals

Choice Plays produce rich preference data.

Example:

> Four-day getaway. Cheap pizza/burritos, warm nights, lots of walking.

Lisbon vs Marrakech.

The event should record:

- scenario attributes;
- options;
- selected option;
- topic tags;
- constraint tags;
- follow-up engagement.

Do not infer a permanent preference from one choice.

## 15. Event envelope

Every event uses a versioned common envelope.

```json
{
  "event": "play_action",
  "version": 1,
  "occurredAt": "...",
  "userId": "...",
  "anonymousSessionId": "...",
  "feedRequestId": "...",
  "playRevisionId": "...",
  "templateRevisionId": "...",
  "creatorId": "...",
  "format": "guess",
  "stateId": "guess",
  "payload": {}
}
```

Use server-generated identifiers where possible to connect recommendation decisions with outcomes.

## 16. Core consumer events

Required:

- `onboarding_interest_selected`
- `onboarding_learning_selected`
- `feed_requested`
- `play_impression`
- `play_visible`
- `play_started`
- `play_action`
- `play_resolved`
- `play_completed`
- `play_dismissed`
- `play_replayed`
- `play_saved`
- `play_unsaved`
- `play_shared`
- `topic_muted`
- `creator_muted`
- `play_reported`
- `play_remix_opened`

## 17. Creator events

Required:

- `create_started`
- `remix_started`
- `template_selected`
- `draft_saved`
- `validation_failed`
- `preview_started`
- `publish_requested`
- `play_published`
- `creation_abandoned`
- `template_published`

Creation funnel must be measurable end to end.

## 18. Recommendation decision log

Each feed response should persist enough information to reproduce/explain selection:

- candidate set IDs or sampled trace;
- source bucket;
- ranking model/config version;
- principal feature contributions;
- final rank;
- exclusion reasons for filtered candidates where sampled/debuggable.

This is essential for product experiments and ranking regressions.

## 19. Primary product metrics

### Consumer

Primary:

**Played impressions / eligible impressions**

Supporting:

- D1/D7 return;
- meaningful actions/session;
- save rate;
- share rate;
- replay rate;
- topic discovery;
- learning-topic engagement;
- format diversity;
- voluntary return.

### Creator

Primary:

**Qualified Plays consumed from community supply**

Supporting:

- create → publish;
- median creation time;
- second creation;
- remix rate;
- template reuse;
- creator D7/D30;
- downstream template consumption.

## 20. Feed health metrics

Monitor independently of growth:

- rapid-swipe clusters;
- repeated topic rejection;
- repeated format rejection;
- hide/report rate;
- content duplication;
- creator concentration;
- template concentration;
- session duration distribution;
- failed media starts;
- interaction errors;
- recommendation latency.

## 21. Qualified consumption

A community Play counts as qualified when it satisfies minimum quality/engagement conditions such as:

- legitimate visible impression;
- meaningful action or sufficient format-appropriate completion;
- no moderation invalidation;
- no fraud/spam classification.

Exact thresholds must be format-aware.

A 7-second visual Guess should not be measured like a 2-minute puzzle.

## 22. Experiment framework

Every experiment records:

- hypothesis;
- eligibility;
- assignment unit;
- control/treatment;
- primary metric;
- guardrails;
- minimum data requirement;
- analysis window;
- result.

Required early experiments:

1. Feed vs menu.
2. Generic vs situated choice.
3. Interest-only vs interest + learning.
4. Topic-only vs topic + interaction affinity.
5. Blank create vs Remix.
6. Human-curated vs AI-heavy supply.

## 23. Guardrails against feedback loops

- cap repeated topic/template exposure;
- preserve exploration minimums;
- weight explicit mute/report strongly;
- do not let high engagement override safety/moderation;
- avoid self-reinforcing creator monopoly;
- periodically retest topics/formats that were weak only under sparse evidence;
- separate short-term click/play propensity from longer-term satisfaction signals.

## 24. Privacy/data minimization

Collect only what improves product operation, safety, or measurement.

Do not infer sensitive user attributes merely because content topics correlate with them.

Keep recommendation features explainable at a product level:

> Because you chose Travel + Food and often play visual comparisons.

Users should be able to mute topics and reset recommendation signals.

## 25. Demand Board derivation

Post-v1, aggregate demand can be estimated from:

- explicit learning interest with low relevant inventory;
- search/save intent;
- high engagement on sparse topic supply;
- repeated wildcard success;
- requests/challenges;
- interaction-format gaps.

Demand Board must use aggregated data and minimum cohort thresholds.

## 26. Ranking evolution

Progression should be evidence-driven:

### Stage 1

Rules/weighted features.

### Stage 2

Learned candidate scorer using explicit features and strong offline evaluation.

### Stage 3

Multi-objective ranking with calibrated exploration, satisfaction, quality, and supply diversity.

Do not introduce model complexity that cannot be debugged against the product thesis.

## 27. Success test

Recommendation is working when Mosaic increasingly predicts both:

> **what this user cares about**

and

> **what this user feels like doing with it**

without removing serendipity or turning raw time-spent into the product's governing objective.
